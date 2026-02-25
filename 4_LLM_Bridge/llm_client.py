#!/usr/bin/env python
"""LLM client for node-lock generation (mock, OpenAI API, and local OpenAI-compatible endpoints)."""

from __future__ import annotations

import json
import os
import re
from typing import Any, Dict, Optional

import requests


REQUIRED_TARGET_KEYS = ("node_id", "street", "locks")
STREET_VALUES = {"flop", "turn", "river"}
ACTION_PATTERN = re.compile(r"^(fold|check|call|bet|raise|bet:\d+|raise:\d+)$", re.IGNORECASE)
ROOTISH_NODE_HINTS = {"root", "start", "initial", "node0", "node_0", "n0"}
MAX_NODE_LOCK_TARGETS = 8
TARGET_LIST_KEYS = ("node_locks", "targets", "locks_by_node", "lock_targets")
TARGET_NODE_ID_KEYS = ("node_id", "node", "nodeId", "id", "path")
TARGET_STREET_KEYS = ("street", "stage")
TARGET_LOCKS_KEYS = ("locks", "actions", "strategy", "action_frequencies")
try:
    ROOT_CHECK_FLOOR = float(os.environ.get("ROOT_CHECK_FLOOR", "0.20"))
except ValueError:
    ROOT_CHECK_FLOOR = 0.20
try:
    RIVER_MAX_TARGETS = int(os.environ.get("RIVER_MAX_TARGETS", "1"))
except ValueError:
    RIVER_MAX_TARGETS = 1

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
    first_target = {
        "node_id": "root",
        "street": street,
        "confidence": 0.5,
        "locks": [
            {
                "action": action,
                "frequency": 1.0,
                "notes": "Mock LLM intuition for integration testing.",
            }
        ],
    }
    return {
        "node_id": first_target["node_id"],
        "street": first_target["street"],
        "locks": first_target["locks"],
        "node_locks": [first_target],
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


def _allowed_lock_streets(expected_street: str) -> set[str]:
    if expected_street == "flop":
        return {"flop", "turn", "river"}
    if expected_street == "turn":
        return {"turn", "river"}
    return {"river"}


def _build_messages(
    spot_json: Dict[str, Any],
    allowed_root_actions: Optional[list[str]],
    opponent_profile: Optional[Dict[str, Any]],
    node_lock_catalog: Optional[list[Dict[str, Any]]],
    enable_multi_node: bool,
) -> list[Dict[str, str]]:
    expected_street = _detect_street(spot_json)
    allowed_streets = sorted(_allowed_lock_streets(expected_street))
    allowed_actions_list = ", ".join(allowed_root_actions or [])
    opp_profile_json = json.dumps(opponent_profile or {}, ensure_ascii=True)
    catalog_preview = []
    for item in node_lock_catalog or []:
        if not isinstance(item, dict):
            continue
        node_id = str(item.get("node_id", "")).strip()
        street = str(item.get("street", "")).strip().lower()
        actions = item.get("actions", [])
        if not node_id or street not in STREET_VALUES or not isinstance(actions, list):
            continue
        catalog_preview.append({"node_id": node_id, "street": street, "actions": actions})
        if len(catalog_preview) >= 24:
            break

    if enable_multi_node:
        schema_hint = (
            "{\"node_locks\":[{\"node_id\":\"<node id>\",\"street\":\"flop|turn|river\","
            "\"confidence\":0.0..1.0,\"locks\":[{\"action\":\"check|fold|call|bet|raise|bet:<amount>|raise:<amount>\","
            "\"frequency\":0.0..1.0}]}]}"
        )
        multi_hint = (
            "Use node_id values from the candidate node catalog only. "
            "Keep frequencies normalized per target. Prefer 1-3 targets. "
            "If uncertain, return one valid root target only."
        )
    else:
        schema_hint = (
            "{\"node_id\":\"root\",\"street\":\""
            + expected_street
            + "\",\"locks\":[{\"action\":\"check|fold|call|bet|raise|bet:<amount>|raise:<amount>\",\"frequency\":0.0..1.0}],"
            "\"confidence\":0.0..1.0}"
        )
        multi_hint = "Target node_id root only."

    system_prompt = (
        "You are a poker node-lock assistant. Return ONLY a JSON object and no prose. "
        f"Required schema: {schema_hint}. "
        f"Allowed lock streets for this request: {', '.join(allowed_streets)}. "
        + ("Use ONLY these legal root actions: " + allowed_actions_list + ". " if allowed_actions_list else "")
        + multi_hint
    )
    user_prompt = (
        "Given this solve spot payload, propose exploitative node-lock frequencies.\n"
        "Return JSON only with no markdown fences and no commentary.\n"
        + f"Opponent profile JSON: {opp_profile_json}\n"
        + ("Allowed root actions: " + allowed_actions_list + "\n" if allowed_actions_list else "")
        + (
            f"Candidate node catalog: {json.dumps(catalog_preview, ensure_ascii=True)}\n"
            if enable_multi_node and catalog_preview
            else ""
        )
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


def _call_local_with_retry(
    *,
    base_url: str,
    api_key: str,
    model: str,
    messages: list[Dict[str, str]],
    temperature: float,
    max_tokens: int,
    timeout_sec: float,
    require_multi_node: bool,
) -> Dict[str, Any]:
    try:
        return _call_openai_compatible_chat(
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
        if require_multi_node:
            retry_instruction = (
                "Return ONLY one JSON object now. Use key node_locks with 1-3 targets. "
                "Each target requires node_id, street, locks[]. No prose."
            )
        else:
            retry_instruction = (
                "Return ONLY one JSON object now. "
                "Required keys: node_id, street, locks."
            )
        retry_messages.append({"role": "user", "content": retry_instruction})
        try:
            return _call_openai_compatible_chat(
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


def _normalize_node_id(raw_node_id: Any) -> str:
    node_id = str(raw_node_id or "").strip()
    if not node_id:
        return "root"
    lowered = node_id.lower()
    compact = re.sub(r"[^a-z0-9_]+", "", lowered)
    if compact == "root":
        return "root"
    if compact in ROOTISH_NODE_HINTS:
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


def _inject_root_check_floor_if_needed(
    locks: list[Dict[str, Any]],
    *,
    node_id: str,
    expected_street: str,
    allowed_root_actions: Optional[list[str]],
    issues: list[str],
) -> list[Dict[str, Any]]:
    if node_id != "root":
        return locks
    if expected_street not in {"turn", "river"}:
        return locks
    if not allowed_root_actions:
        return locks
    allowed = {str(a).strip().lower() for a in allowed_root_actions if str(a).strip()}
    if "check" not in allowed:
        return locks
    check_floor = ROOT_CHECK_FLOOR
    if check_floor <= 0.0:
        return locks
    if check_floor >= 1.0:
        check_floor = 0.99

    actions = {str(item.get("action", "")).strip().lower() for item in locks}
    if "check" in actions or "call" in actions or "fold" in actions:
        return locks
    if not actions:
        return locks
    if not all(action.startswith("bet") or action.startswith("raise") for action in actions):
        return locks

    adjusted: list[Dict[str, Any]] = []
    scale = 1.0 - check_floor
    for item in locks:
        adjusted.append({"action": item["action"], "frequency": float(item["frequency"]) * scale})
    adjusted.append({"action": "check", "frequency": check_floor})
    issues.append("root_check_floor_injected")
    return _aggregate_and_normalize_locks(adjusted)


def _cap_river_targets_if_needed(
    targets: list[Dict[str, Any]],
    *,
    expected_street: str,
    issues: list[str],
) -> list[Dict[str, Any]]:
    if expected_street != "river":
        return targets
    cap = RIVER_MAX_TARGETS
    if cap <= 0:
        return targets
    if len(targets) <= cap:
        return targets
    # Keep earliest targets (root is usually first after normalization).
    issues.append(f"river_target_cap_applied:{cap}")
    return targets[:cap]


def _normalize_confidence(value: Any) -> float:
    try:
        confidence = float(value)
    except (TypeError, ValueError):
        return 0.5
    if confidence < 0.0:
        return 0.0
    if confidence > 1.0:
        return 1.0
    return confidence


def _coerce_frequency(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        freq = float(value)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.endswith("%"):
            text = text[:-1].strip()
            try:
                freq = float(text) / 100.0
            except ValueError:
                return None
        else:
            try:
                freq = float(text)
            except ValueError:
                return None
    else:
        return None
    if freq < 0.0:
        return 0.0
    if freq > 1.0:
        if freq <= 100.0:
            return freq / 100.0
        return 1.0
    return freq


def _first_present(payload: Dict[str, Any], keys: tuple[str, ...], default: Any = None) -> Any:
    for key in keys:
        if key in payload:
            return payload.get(key)
    return default


def _coerce_locks(value: Any, target_payload: Dict[str, Any]) -> list[Dict[str, Any]]:
    out: list[Dict[str, Any]] = []
    if isinstance(value, list):
        for item in value:
            if isinstance(item, dict):
                action = item.get("action")
                if action is None:
                    action = _first_present(item, ("move", "act", "name"))
                freq = item.get("frequency")
                if freq is None:
                    freq = _first_present(item, ("probability", "weight", "freq", "pct", "percent"))
                if action is None or freq is None:
                    continue
                parsed = _coerce_frequency(freq)
                if parsed is None:
                    continue
                lock = {"action": action, "frequency": parsed}
                if "notes" in item:
                    lock["notes"] = str(item["notes"])
                out.append(lock)
            elif isinstance(item, str):
                action = item.strip()
                if action:
                    out.append({"action": action, "frequency": 1.0})
    elif isinstance(value, dict):
        for action, freq in value.items():
            parsed = _coerce_frequency(freq)
            if parsed is None:
                continue
            out.append({"action": str(action), "frequency": parsed})

    # Fallback: single action/frequency can be provided at target top-level.
    if not out:
        action = _first_present(target_payload, ("action", "move", "act"))
        freq = _first_present(target_payload, ("frequency", "probability", "weight", "freq", "pct", "percent"))
        parsed = _coerce_frequency(freq)
        if action is not None and parsed is not None:
            out.append({"action": str(action), "frequency": parsed})
    return out


def _extract_raw_targets(node_lock: Dict[str, Any]) -> list[Dict[str, Any]]:
    # Primary list-like containers.
    for key in TARGET_LIST_KEYS:
        value = node_lock.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
        if isinstance(value, dict):
            # Allow {"node_id": {"bet:10":0.6, ...}, ...}
            out: list[Dict[str, Any]] = []
            for node_id, locks in value.items():
                out.append({"node_id": str(node_id), "locks": locks})
            if out:
                return out
    # Legacy/single object.
    return [node_lock]


def _normalize_target(
    target_payload: Dict[str, Any],
    *,
    expected_street: str,
    provider: str,
    allowed_root_actions: Optional[list[str]],
    issues: list[str],
) -> Dict[str, Any]:
    node_id_raw = _first_present(target_payload, TARGET_NODE_ID_KEYS, "root")
    street_raw = _first_present(target_payload, TARGET_STREET_KEYS, "")
    locks_raw = _first_present(target_payload, TARGET_LOCKS_KEYS)
    if locks_raw is None:
        locks_raw = target_payload.get("locks")

    node_id = _normalize_node_id(node_id_raw)
    if not node_id:
        node_id = "root"
    street = str(street_raw or "").strip().lower()
    allowed_streets = _allowed_lock_streets(expected_street)
    if street not in STREET_VALUES:
        if provider == "local":
            street = expected_street
            issues.append("street_repaired_to_expected_or_missing")
        else:
            raise ValueError("Node-lock street must be one of: flop, turn, river.")
    elif street not in allowed_streets:
        if provider == "local":
            street = expected_street
            issues.append("street_repaired_to_allowed")
        else:
            raise ValueError(f"Node-lock street '{street}' not allowed from spot street '{expected_street}'.")

    coerced_locks = _coerce_locks(locks_raw, target_payload)
    allowed_actions = [str(a).strip().lower() for a in (allowed_root_actions or []) if str(a).strip()]
    normalized_locks = []
    for item in coerced_locks:
        if not isinstance(item, dict):
            continue
        if "action" not in item or "frequency" not in item:
            continue

        action = _normalize_action_label(item["action"])
        if not ACTION_PATTERN.match(action):
            continue
        freq = _coerce_frequency(item["frequency"])
        if freq is None:
            continue

        # Only root can be constrained from baseline action legality right now.
        action_candidates = [action]
        if node_id == "root" and allowed_actions:
            action_candidates = _action_candidates_for_allowed(action, allowed_actions)
            if not action_candidates:
                continue

        split_freq = freq / float(len(action_candidates))
        for candidate in action_candidates:
            normalized = {"action": candidate, "frequency": split_freq}
            if "notes" in item:
                normalized["notes"] = str(item["notes"])
            normalized_locks.append(normalized)

    normalized_locks = _aggregate_and_normalize_locks(normalized_locks)
    if not normalized_locks:
        raise ValueError("Node-lock target did not contain any valid lock entries.")
    normalized_locks = _inject_root_check_floor_if_needed(
        normalized_locks,
        node_id=node_id,
        expected_street=expected_street,
        allowed_root_actions=allowed_actions,
        issues=issues,
    )
    if not normalized_locks:
        raise ValueError("Node-lock target did not contain any valid lock entries after root check floor repair.")

    return {
        "node_id": node_id,
        "street": street,
        "confidence": _normalize_confidence(target_payload.get("confidence")),
        "locks": normalized_locks,
    }


def _normalize_node_lock(
    payload: Dict[str, Any],
    *,
    spot_json: Dict[str, Any],
    provider: str,
    allowed_root_actions: Optional[list[str]],
    enable_multi_node: bool,
) -> Dict[str, Any]:
    node_lock = payload.get("node_lock") if isinstance(payload.get("node_lock"), dict) else payload
    if not isinstance(node_lock, dict):
        raise ValueError("Node-lock payload must be a JSON object.")
    expected_street = _detect_street(spot_json)
    issues: list[str] = []

    raw_targets = _extract_raw_targets(node_lock)
    # If a list exists but all entries are malformed, keep top-level as a salvage candidate.
    if node_lock is not payload and isinstance(payload, dict):
        raw_targets.extend(_extract_raw_targets(payload))
    deduped_raw: list[Dict[str, Any]] = []
    seen_ids: set[int] = set()
    for item in raw_targets:
        if id(item) in seen_ids:
            continue
        seen_ids.add(id(item))
        deduped_raw.append(item)
    raw_targets = deduped_raw

    normalized_targets = []
    for raw in raw_targets[:MAX_NODE_LOCK_TARGETS]:
        try:
            normalized_targets.append(
                _normalize_target(
                    raw,
                    expected_street=expected_street,
                    provider=provider,
                    allowed_root_actions=allowed_root_actions,
                    issues=issues,
                )
            )
        except ValueError:
            continue

    if not normalized_targets:
        raise ValueError("Node-lock payload did not contain any valid targets.")

    if not enable_multi_node:
        root_targets = [target for target in normalized_targets if target.get("node_id") == "root"]
        if not root_targets:
            raise ValueError("Single-node mode requires a root lock target.")
        normalized_targets = [root_targets[0]]
        issues.append("single_node_mode_enforced")
    else:
        normalized_targets = _cap_river_targets_if_needed(
            normalized_targets,
            expected_street=expected_street,
            issues=issues,
        )

    first_target = normalized_targets[0]
    return {
        "node_id": first_target["node_id"],
        "street": first_target["street"],
        "locks": first_target["locks"],
        "node_locks": normalized_targets,
        "meta": {
            "validation": {
                "issues": issues,
                "target_count": len(normalized_targets),
            }
        },
    }


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

    opponent_profile = resolved.get("opponent_profile")
    if not isinstance(opponent_profile, dict):
        opponent_profile = {}
    node_lock_catalog = resolved.get("node_lock_catalog")
    if not isinstance(node_lock_catalog, list):
        node_lock_catalog = []
    enable_multi_node = bool(resolved.get("enable_multi_node_locks", False))

    messages = _build_messages(
        spot_json,
        allowed_root_actions=allowed_root_actions,
        opponent_profile=opponent_profile,
        node_lock_catalog=node_lock_catalog,
        enable_multi_node=enable_multi_node,
    )
    temperature = float(resolved.get("temperature", 0.0))
    max_tokens = int(resolved.get("max_tokens", 400))
    timeout_sec = float(resolved.get("timeout_sec", 60.0))
    local_base_url = str(resolved.get("base_url") or os.environ.get("LOCAL_LLM_BASE_URL") or "http://127.0.0.1:11434/v1")
    local_api_key = str(resolved.get("api_key") or os.environ.get("LOCAL_LLM_API_KEY") or "local")

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
            payload = _call_local_with_retry(
                base_url=local_base_url,
                api_key=local_api_key,
                model=model,
                messages=messages,
                temperature=temperature,
                max_tokens=max_tokens,
                timeout_sec=timeout_sec,
                require_multi_node=enable_multi_node,
            )
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
            enable_multi_node=enable_multi_node,
        )
    except Exception as exc:  # pylint: disable=broad-except
        if provider == "local":
            if enable_multi_node:
                # Multi-node fallback path: salvage with strict single-node request before mock fallback.
                try:
                    single_messages = _build_messages(
                        spot_json,
                        allowed_root_actions=allowed_root_actions,
                        opponent_profile=opponent_profile,
                        node_lock_catalog=node_lock_catalog,
                        enable_multi_node=False,
                    )
                    retry_payload = _call_local_with_retry(
                        base_url=local_base_url,
                        api_key=local_api_key,
                        model=model,
                        messages=single_messages,
                        temperature=temperature,
                        max_tokens=max_tokens,
                        timeout_sec=timeout_sec,
                        require_multi_node=False,
                    )
                    node_lock = _normalize_node_lock(
                        retry_payload,
                        spot_json=spot_json,
                        provider=provider,
                        allowed_root_actions=allowed_root_actions,
                        enable_multi_node=False,
                    )
                    node_lock.setdefault("meta", {})
                    validation = node_lock["meta"].setdefault("validation", {})
                    issues = validation.get("issues", [])
                    if not isinstance(issues, list):
                        issues = []
                    issues.append("multi_node_retry_single_node")
                    validation["issues"] = issues
                    node_lock["meta"].update({"provider": provider, "model": model, "preset": resolved.get("preset", "")})
                    return node_lock
                except Exception as retry_exc:  # pylint: disable=broad-except
                    exc = ValueError(f"{exc}; single_node_retry_failed={retry_exc}")
            node_lock = _mock_node_lock(spot_json, allowed_root_actions=allowed_root_actions)
            node_lock.setdefault("meta", {})
            node_lock["meta"]["fallback_reason"] = str(exc)
            node_lock["meta"]["fallback_applied"] = True
        else:
            raise

    node_lock.setdefault("meta", {})
    node_lock["meta"].update({"provider": provider, "model": model, "preset": resolved.get("preset", "")})
    return node_lock
