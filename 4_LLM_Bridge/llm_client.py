#!/usr/bin/env python
"""LLM client for node-lock generation (mock, OpenAI API, and local OpenAI-compatible endpoints)."""

from __future__ import annotations

import json
import os
import re
from typing import Any, Dict, Optional

import requests


REQUIRED_NODE_LOCK_KEYS = ("node_id", "street", "locks")
STREET_VALUES = {"flop", "turn", "river"}
ACTION_PATTERN = re.compile(r"^(fold|check|call|bet|raise|bet:\d+|raise:\d+)$", re.IGNORECASE)
ROOTISH_NODE_HINTS = ("root", "start", "initial", "node0", "node_0", "n0", "0")

PRESET_CONFIGS: Dict[str, Dict[str, Any]] = {
    "mock": {"provider": "mock", "model": "mock-root-check"},
    "openai_fast": {"provider": "openai", "model": "gpt-4o-mini"},
    "openai_mini": {"provider": "openai", "model": "gpt-4o-mini"},
    "openai_52": {"provider": "openai", "model": "gpt-4o"},
    "local_gpt_oss_20b": {
        "provider": "local",
        "model": os.environ.get("LOCAL_MODEL_GPT_OSS_20B", "gpt-oss:20b"),
    },
    "local_qwen3_coder_30b": {
        "provider": "local",
        "model": os.environ.get("LOCAL_MODEL_QWEN3_CODER_30B", "qwen3-coder:30b"),
    },
    "local_deepseek_coder_33b": {
        "provider": "local",
        "model": os.environ.get("LOCAL_MODEL_DEEPSEEK_CODER_33B", "deepseek-coder:33b"),
    },
    "local_llama3_8b": {
        "provider": "local",
        "model": os.environ.get("LOCAL_MODEL_LLAMA3_8B", "llama3.1:8b"),
    },
}


def _detect_street(spot_json: Dict[str, Any]) -> str:
    board = spot_json.get("board", [])
    if isinstance(board, list):
        if len(board) == 4:
            return "turn"
        if len(board) >= 5:
            return "river"
    return "flop"


def _pick_mock_action(allowed_root_actions: Optional[list[str]]) -> str:
    if not allowed_root_actions:
        return "check"
    for candidate in ("check", "call", "fold"):
        if candidate in allowed_root_actions:
            return candidate
    return allowed_root_actions[0]


def _mock_node_lock(spot_json: Dict[str, Any], allowed_root_actions: Optional[list[str]] = None) -> Dict[str, Any]:
    street = _detect_street(spot_json)
    action = _pick_mock_action(allowed_root_actions)
    return {
        "node_id": "root",
        "street": street,
        "locks": [
            {
                "action": action,
                "frequency": 1.0,
                "notes": "Mock LLM intuition for integration testing.",
            }
        ],
        "meta": {
            "provider": "mock_llm",
            "reason": "MVP bridge smoke test",
        },
    }


def _resolve_config(config: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    requested = dict(config or {})
    preset = requested.get("preset", "mock")
    base = dict(PRESET_CONFIGS.get(preset, PRESET_CONFIGS["mock"]))
    base.update({k: v for k, v in requested.items() if v is not None})
    base.setdefault("temperature", 0.0)
    base.setdefault("max_tokens", 400)
    return base


def _build_messages(spot_json: Dict[str, Any], allowed_root_actions: Optional[list[str]]) -> list[Dict[str, str]]:
    expected_street = _detect_street(spot_json)
    allowed_actions_list = ", ".join(allowed_root_actions or [])
    system_prompt = (
        "You are a poker node-lock assistant. Return ONLY a JSON object and no prose. "
        "Required schema: "
        "{\"node_id\":\"root\",\"street\":\""
        + expected_street
        + "\",\"locks\":[{\"action\":\"check|fold|call|bet|raise|bet:<amount>|raise:<amount>\",\"frequency\":0.0..1.0}]}."
        " Use node_id exactly \"root\" and street exactly \""
        + expected_street
        + "\"."
        + (" Use ONLY these legal root actions: " + allowed_actions_list + "." if allowed_actions_list else "")
    )
    user_prompt = (
        "Given this solve spot payload, propose exploitative root node-lock frequencies.\n"
        "Return JSON only with no markdown fences and no commentary.\n"
        + ("Allowed root actions: " + allowed_actions_list + "\n" if allowed_actions_list else "")
        + f"{json.dumps(spot_json, ensure_ascii=True)}"
    )
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]


def _call_openai_compatible_chat(
    *,
    base_url: str,
    api_key: str,
    model: str,
    messages: list[Dict[str, str]],
    temperature: float,
    max_tokens: int,
    timeout_sec: float = 60.0,
) -> Dict[str, Any]:
    url = base_url.rstrip("/") + "/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "response_format": {"type": "json_object"},
    }

    resp = requests.post(url, headers=headers, json=payload, timeout=timeout_sec)
    if resp.status_code >= 400:
        fallback_payload = dict(payload)
        fallback_payload.pop("response_format", None)
        fallback_resp = requests.post(url, headers=headers, json=fallback_payload, timeout=timeout_sec)
        fallback_resp.raise_for_status()
        data = fallback_resp.json()
    else:
        data = resp.json()

    choices = data.get("choices", [])
    if not choices:
        raise ValueError("LLM response missing choices.")
    message = choices[0].get("message", {})
    content = message.get("content")
    if isinstance(content, list):
        text_parts = []
        for part in content:
            if isinstance(part, dict):
                txt = part.get("text")
                if isinstance(txt, str):
                    text_parts.append(txt)
        content = "\n".join(text_parts)

    if not isinstance(content, str) or not content.strip():
        raise ValueError("LLM response missing message.content JSON.")

    text = str(content).strip()
    if text.startswith("```json"):
        text = text[7:]
    elif text.startswith("```"):
        text = text[3:]
    if text.endswith("```"):
        text = text[:-3]
    text = text.strip()

    start_idx = text.find("{")
    end_idx = text.rfind("}")
    if start_idx != -1 and end_idx != -1 and end_idx >= start_idx:
        text = text[start_idx : end_idx + 1]

    parse_error: Optional[Exception] = None
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        parse_error = exc
    try:
        decoder = json.JSONDecoder()
        first_obj, _ = decoder.raw_decode(text)
        if isinstance(first_obj, dict):
            return first_obj
    except json.JSONDecodeError:
        pass

    start = content.find("{")
    end = content.rfind("}")
    if start >= 0 and end > start:
        candidate = content[start : end + 1]
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            try:
                decoder = json.JSONDecoder()
                first_obj, _ = decoder.raw_decode(candidate)
                if isinstance(first_obj, dict):
                    return first_obj
            except json.JSONDecodeError:
                pass
    snippet = text[:220].replace("\n", " ")
    raise ValueError(f"LLM response content did not contain parseable JSON. parse_error={parse_error}; snippet={snippet!r}")


def _normalize_node_id(raw_node_id: Any) -> str:
    node_id = str(raw_node_id or "").strip()
    if not node_id:
        return "root"
    lowered = node_id.lower()
    compact = re.sub(r"[^a-z0-9_]+", "", lowered)
    if compact == "root":
        return "root"
    for hint in ROOTISH_NODE_HINTS:
        if hint in compact:
            return "root"
    return node_id


def _normalize_action_label(raw_action: Any) -> str:
    action = str(raw_action or "").strip().lower()
    action = action.replace(" ", "")
    action = action.replace("_", ":")
    action = action.replace("-", ":")
    action = action.replace("pct", "")

    if action in {"allin", "all:in", "jam", "shove"}:
        return "bet"
    if action == "chk":
        return "check"
    if ACTION_PATTERN.match(action):
        return action

    if "check" in action:
        return "check"
    if "fold" in action:
        return "fold"
    if "call" in action:
        return "call"
    if "raise" in action:
        m = re.search(r"(\d+)", action)
        return f"raise:{m.group(1)}" if m else "raise"
    if "bet" in action:
        m = re.search(r"(\d+)", action)
        return f"bet:{m.group(1)}" if m else "bet"
    return action


def _action_candidates_for_allowed(action: str, allowed_root_actions: list[str]) -> list[str]:
    if not allowed_root_actions:
        return [action]

    allowed = [str(a).strip().lower() for a in allowed_root_actions if str(a).strip()]
    allowed_set = set(allowed)
    if action in allowed_set:
        return [action]

    base = action.split(":", 1)[0]
    prefix_matches = [a for a in allowed if a.startswith(base + ":")]
    direct_base = [a for a in allowed if a == base]

    if base in {"bet", "raise"}:
        if ":" in action and prefix_matches:
            # Map sized action to nearest legal size.
            try:
                requested = int(action.split(":", 1)[1])
                parsed = []
                for candidate in prefix_matches:
                    try:
                        parsed.append((abs(int(candidate.split(":", 1)[1]) - requested), candidate))
                    except (ValueError, IndexError):
                        continue
                if parsed:
                    parsed.sort(key=lambda x: x[0])
                    return [parsed[0][1]]
            except (ValueError, IndexError):
                pass
        if direct_base:
            return direct_base
        if prefix_matches:
            # Generic bet/raise can be split across legal sizes.
            return prefix_matches
        return []

    if direct_base:
        return direct_base
    return []


def _aggregate_and_normalize_locks(locks: list[Dict[str, Any]]) -> list[Dict[str, Any]]:
    by_action: Dict[str, float] = {}
    for item in locks:
        action = str(item.get("action", "")).strip().lower()
        if not action:
            continue
        freq = float(item.get("frequency", 0.0))
        by_action[action] = by_action.get(action, 0.0) + max(0.0, freq)

    total = sum(by_action.values())
    if total <= 0.0:
        return []

    normalized = []
    for action, freq in sorted(by_action.items()):
        normalized.append({"action": action, "frequency": freq / total})
    return normalized


def _normalize_node_lock(
    payload: Dict[str, Any],
    *,
    spot_json: Dict[str, Any],
    provider: str,
    allowed_root_actions: Optional[list[str]],
) -> Dict[str, Any]:
    node_lock = payload.get("node_lock") if isinstance(payload.get("node_lock"), dict) else payload
    if not isinstance(node_lock, dict):
        raise ValueError("Node-lock payload must be a JSON object.")

    missing = [k for k in REQUIRED_NODE_LOCK_KEYS if k not in node_lock]
    if missing:
        raise ValueError(f"Node-lock missing keys: {missing}")
    if not isinstance(node_lock["locks"], list):
        raise ValueError("Node-lock key 'locks' must be a list.")

    node_id = _normalize_node_id(node_lock.get("node_id", ""))
    if node_id != "root":
        if provider == "local":
            node_id = "root"
        else:
            raise ValueError("Node-lock contract currently requires node_id='root'.")

    street = str(node_lock.get("street", "")).strip().lower()
    expected_street = _detect_street(spot_json)
    if street not in STREET_VALUES or street != expected_street:
        if provider == "local":
            street = expected_street
        elif street not in STREET_VALUES:
            raise ValueError("Node-lock street must be one of: flop, turn, river.")
        else:
            raise ValueError(f"Node-lock street '{street}' does not match board-derived street '{expected_street}'.")

    allowed_actions = [str(a).strip().lower() for a in (allowed_root_actions or []) if str(a).strip()]
    normalized_locks = []
    for item in node_lock["locks"]:
        if not isinstance(item, dict):
            continue
        if "action" not in item or "frequency" not in item:
            continue

        action = _normalize_action_label(item["action"])
        if not ACTION_PATTERN.match(action):
            continue

        try:
            freq = float(item["frequency"])
        except (TypeError, ValueError):
            continue

        if freq < 0.0:
            freq = 0.0
        elif freq > 1.0:
            freq = 1.0

        candidates = _action_candidates_for_allowed(action, allowed_actions) if allowed_actions else [action]
        if not candidates:
            continue
        split_freq = freq / float(len(candidates))
        for candidate in candidates:
            normalized = {"action": candidate, "frequency": split_freq}
            if "notes" in item:
                normalized["notes"] = str(item["notes"])
            normalized_locks.append(normalized)

    normalized_locks = _aggregate_and_normalize_locks(normalized_locks)

    if not normalized_locks:
        raise ValueError("Node-lock did not contain any valid legal lock entries.")

    freq_sum = sum(lock["frequency"] for lock in normalized_locks)
    if freq_sum <= 0.0:
        raise ValueError("Node-lock frequencies must sum to > 0.")

    node_lock["locks"] = normalized_locks
    node_lock["node_id"] = node_id
    node_lock["street"] = street
    return node_lock


def get_llm_intuition(spot_json: Dict[str, Any], config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    resolved = _resolve_config(config)
    provider = str(resolved.get("provider", "mock")).lower()
    allowed_root_actions = resolved.get("allowed_root_actions")
    if isinstance(allowed_root_actions, list):
        allowed_root_actions = [str(a).strip().lower() for a in allowed_root_actions if str(a).strip()]
    else:
        allowed_root_actions = None

    if provider == "mock":
        node_lock = _mock_node_lock(spot_json, allowed_root_actions=allowed_root_actions)
        node_lock.setdefault("meta", {})
        node_lock["meta"].update({"provider": "mock", "model": resolved.get("model", "mock-root-check")})
        return node_lock

    model = str(resolved.get("model", "")).strip()
    if not model:
        raise ValueError("LLM model is required for non-mock providers.")

    messages = _build_messages(spot_json, allowed_root_actions=allowed_root_actions)
    temperature = float(resolved.get("temperature", 0.0))
    max_tokens = int(resolved.get("max_tokens", 400))
    timeout_sec = float(resolved.get("timeout_sec", 60.0))

    try:
        if provider == "openai":
            api_key = resolved.get("api_key") or os.environ.get("OPENAI_API_KEY")
            if not api_key:
                raise ValueError("OPENAI_API_KEY is required for provider=openai.")
            base_url = str(resolved.get("base_url") or "https://api.openai.com/v1")
            payload = _call_openai_compatible_chat(
                base_url=base_url,
                api_key=api_key,
                model=model,
                messages=messages,
                temperature=temperature,
                max_tokens=max_tokens,
                timeout_sec=timeout_sec,
            )
        elif provider == "local":
            base_url = str(resolved.get("base_url") or os.environ.get("LOCAL_LLM_BASE_URL") or "http://127.0.0.1:11434/v1")
            api_key = str(resolved.get("api_key") or os.environ.get("LOCAL_LLM_API_KEY") or "local")
            try:
                payload = _call_openai_compatible_chat(
                    base_url=base_url,
                    api_key=api_key,
                    model=model,
                    messages=messages,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    timeout_sec=timeout_sec,
                )
            except Exception as first_exc:  # pylint: disable=broad-except
                retry_messages = list(messages)
                retry_messages.append(
                    {
                        "role": "user",
                        "content": (
                            "Return ONLY one JSON object now. No prose, no markdown, no analysis. "
                            "Required keys: node_id, street, locks."
                        ),
                    }
                )
                try:
                    payload = _call_openai_compatible_chat(
                        base_url=base_url,
                        api_key=api_key,
                        model=model,
                        messages=retry_messages,
                        temperature=temperature,
                        max_tokens=max_tokens,
                        timeout_sec=timeout_sec,
                    )
                except Exception as retry_exc:  # pylint: disable=broad-except
                    raise ValueError(f"{first_exc}; retry_failed={retry_exc}") from retry_exc
        else:
            raise ValueError(f"Unsupported LLM provider: {provider}")
    except Exception as exc:  # pylint: disable=broad-except
        if provider == "local":
            node_lock = _mock_node_lock(spot_json, allowed_root_actions=allowed_root_actions)
            node_lock.setdefault("meta", {})
            node_lock["meta"]["fallback_reason"] = str(exc)
            node_lock["meta"]["fallback_applied"] = True
            node_lock["meta"].update({"provider": provider, "model": model, "preset": resolved.get("preset", "")})
            return node_lock
        raise

    try:
        node_lock = _normalize_node_lock(
            payload,
            spot_json=spot_json,
            provider=provider,
            allowed_root_actions=allowed_root_actions,
        )
    except Exception as exc:  # pylint: disable=broad-except
        if provider == "local":
            node_lock = _mock_node_lock(spot_json, allowed_root_actions=allowed_root_actions)
            node_lock.setdefault("meta", {})
            node_lock["meta"]["fallback_reason"] = str(exc)
            node_lock["meta"]["fallback_applied"] = True
        else:
            raise

    node_lock.setdefault("meta", {})
    node_lock["meta"].update({"provider": provider, "model": model, "preset": resolved.get("preset", "")})
    return node_lock
