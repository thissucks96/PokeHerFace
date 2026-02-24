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

PRESET_CONFIGS: Dict[str, Dict[str, Any]] = {
    "mock": {"provider": "mock", "model": "mock-root-check"},
    "openai_fast": {"provider": "openai", "model": "gpt-5-mini"},
    "openai_mini": {"provider": "openai", "model": "gpt-5-mini"},
    "openai_52": {"provider": "openai", "model": "gpt-5.2"},
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
}


def _detect_street(spot_json: Dict[str, Any]) -> str:
    board = spot_json.get("board", [])
    if isinstance(board, list):
        if len(board) == 4:
            return "turn"
        if len(board) >= 5:
            return "river"
    return "flop"


def _mock_node_lock(spot_json: Dict[str, Any]) -> Dict[str, Any]:
    street = _detect_street(spot_json)
    return {
        "node_id": "root",
        "street": street,
        "locks": [
            {
                "action": "check",
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


def _build_messages(spot_json: Dict[str, Any]) -> list[Dict[str, str]]:
    system_prompt = (
        "You are a poker node-lock assistant. Return ONLY valid JSON with keys: "
        "node_id, street, locks. "
        "Use root lock recommendations only unless explicitly given a different node id. "
        "Each lock item must have action and frequency in [0,1]."
    )
    user_prompt = (
        "Given this solve spot payload, propose exploitative root node-lock frequencies.\n"
        "Return JSON only.\n"
        f"{json.dumps(spot_json, ensure_ascii=True)}"
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
        # Some providers return rich content blocks.
        text_parts = []
        for part in content:
            if isinstance(part, dict):
                txt = part.get("text")
                if isinstance(txt, str):
                    text_parts.append(txt)
        content = "\n".join(text_parts)

    if not isinstance(content, str) or not content.strip():
        raise ValueError("LLM response missing message.content JSON.")
    content = content.strip()
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        pass

    # Handle fenced output or extra commentary by extracting first JSON object.
    start = content.find("{")
    end = content.rfind("}")
    if start >= 0 and end > start:
        return json.loads(content[start : end + 1])
    raise ValueError("LLM response content did not contain parseable JSON.")


def _normalize_node_lock(payload: Dict[str, Any], *, spot_json: Dict[str, Any]) -> Dict[str, Any]:
    node_lock = payload.get("node_lock") if isinstance(payload.get("node_lock"), dict) else payload
    if not isinstance(node_lock, dict):
        raise ValueError("Node-lock payload must be a JSON object.")

    missing = [k for k in REQUIRED_NODE_LOCK_KEYS if k not in node_lock]
    if missing:
        raise ValueError(f"Node-lock missing keys: {missing}")
    if not isinstance(node_lock["locks"], list):
        raise ValueError("Node-lock key 'locks' must be a list.")
    node_id = str(node_lock.get("node_id", "")).strip()
    if node_id != "root":
        raise ValueError("Node-lock contract currently requires node_id='root'.")
    street = str(node_lock.get("street", "")).strip().lower()
    if street not in STREET_VALUES:
        raise ValueError("Node-lock street must be one of: flop, turn, river.")
    expected_street = _detect_street(spot_json)
    if street != expected_street:
        raise ValueError(f"Node-lock street '{street}' does not match board-derived street '{expected_street}'.")

    normalized_locks = []
    for item in node_lock["locks"]:
        if not isinstance(item, dict):
            continue
        if "action" not in item or "frequency" not in item:
            continue
        action = str(item["action"])
        try:
            freq = float(item["frequency"])
        except (TypeError, ValueError):
            continue
        if not ACTION_PATTERN.match(action):
            continue
        if freq < 0.0:
            freq = 0.0
        elif freq > 1.0:
            freq = 1.0
        normalized = {"action": action, "frequency": freq}
        if "notes" in item:
            normalized["notes"] = str(item["notes"])
        normalized_locks.append(normalized)

    if not normalized_locks:
        raise ValueError("Node-lock did not contain any valid lock entries.")

    freq_sum = sum(lock["frequency"] for lock in normalized_locks)
    if freq_sum <= 0.0:
        raise ValueError("Node-lock frequencies must sum to > 0.")

    node_lock["locks"] = normalized_locks
    node_lock["node_id"] = "root"
    node_lock["street"] = expected_street
    return node_lock


def get_llm_intuition(spot_json: Dict[str, Any], config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    resolved = _resolve_config(config)
    provider = str(resolved.get("provider", "mock")).lower()

    if provider == "mock":
        node_lock = _mock_node_lock(spot_json)
        node_lock.setdefault("meta", {})
        node_lock["meta"].update({"provider": "mock", "model": resolved.get("model", "mock-root-check")})
        return node_lock

    model = str(resolved.get("model", "")).strip()
    if not model:
        raise ValueError("LLM model is required for non-mock providers.")

    messages = _build_messages(spot_json)
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
            payload = _call_openai_compatible_chat(
                base_url=base_url,
                api_key=api_key,
                model=model,
                messages=messages,
                temperature=temperature,
                max_tokens=max_tokens,
                timeout_sec=timeout_sec,
            )
        else:
            raise ValueError(f"Unsupported LLM provider: {provider}")
    except Exception as exc:  # pylint: disable=broad-except
        if provider == "local":
            node_lock = _mock_node_lock(spot_json)
            node_lock.setdefault("meta", {})
            node_lock["meta"]["fallback_reason"] = str(exc)
            node_lock["meta"]["fallback_applied"] = True
            node_lock["meta"].update({"provider": provider, "model": model, "preset": resolved.get("preset", "")})
            return node_lock
        raise

    try:
        node_lock = _normalize_node_lock(payload, spot_json=spot_json)
    except Exception as exc:  # pylint: disable=broad-except
        # Local models sometimes return partially-structured prose. Keep pipeline alive with a safe fallback.
        if provider == "local":
            node_lock = _mock_node_lock(spot_json)
            node_lock.setdefault("meta", {})
            node_lock["meta"]["fallback_reason"] = str(exc)
            node_lock["meta"]["fallback_applied"] = True
        else:
            raise

    node_lock.setdefault("meta", {})
    node_lock["meta"].update({"provider": provider, "model": model, "preset": resolved.get("preset", "")})
    return node_lock
