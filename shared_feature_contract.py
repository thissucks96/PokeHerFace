#!/usr/bin/env python3
"""Shared neural feature contract for offline dataset + live inference parity.

This module is intentionally lightweight and dependency-free (no torch), so it
can be reused in bridge hot paths and offline scripts with identical behavior.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Dict, List, Tuple


FEATURE_SCHEMA_VERSION = "feature_contract_v1"
FEATURE_DEFAULT_INPUT_DIM = 128


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _hash_bucket(text: str, bucket_count: int) -> int:
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % max(1, bucket_count)


def _street_to_float(street: str) -> float:
    value = str(street or "").strip().lower()
    if value == "preflop":
        return 0.0
    if value == "flop":
        return 1.0
    if value == "turn":
        return 2.0
    if value == "river":
        return 3.0
    return -1.0


def detect_street(board: Any) -> str:
    if not isinstance(board, list):
        return "unknown"
    size = len(board)
    if size >= 5:
        return "river"
    if size == 4:
        return "turn"
    if size == 3:
        return "flop"
    if size == 0:
        return "preflop"
    return f"partial_{size}"


NUMERIC_CHANNELS = [
    "starting_stack",
    "starting_pot",
    "minimum_bet",
    "all_in_threshold",
    "iterations",
    "min_exploitability",
    "thread_count",
    "raise_cap",
    "facing_bet",
    "hero_street_commit",
    "villain_street_commit",
    "current_pot",
    "hero_chips",
    "villain_chips",
    "hero_is_small_blind",
    "remove_donk_bets",
    "compress_strategy",
    "street",
]

CATEGORICAL_TOKENS = [
    "hero_range",
    "villain_range",
    "board",
    "active_node_path",
    "runtime_profile",
    "street",
    "hero_cards",
    "bet_sizing",
]

FEATURE_CONTRACT_SPEC = {
    "schema_version": FEATURE_SCHEMA_VERSION,
    "numeric_channels": NUMERIC_CHANNELS,
    "categorical_tokens": CATEGORICAL_TOKENS,
    "hash_tail_start_rule": "min(len(numeric), input_dim//4)",
}

FEATURE_CONTRACT_HASH = hashlib.sha256(
    json.dumps(FEATURE_CONTRACT_SPEC, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()

_CARD_TOKEN_RE = re.compile(r"^(10|[2-9TJQKA])[CDHS]$", re.IGNORECASE)


def _normalize_source(source: Dict[str, Any]) -> Dict[str, Any]:
    out = {
        "runtime_profile": str(source.get("runtime_profile") or "").strip().lower(),
        "street": str(source.get("street") or "").strip().lower(),
    }
    return out


def _is_valid_card_token(token: str) -> bool:
    return bool(_CARD_TOKEN_RE.match(str(token or "").strip().upper()))


def _normalize_features(features: Dict[str, Any], source: Dict[str, Any]) -> Dict[str, Any]:
    board = features.get("board") if isinstance(features.get("board"), list) else []
    board_tokens = [str(card or "").strip() for card in board if str(card or "").strip()]
    hero_cards = features.get("hero_cards") if isinstance(features.get("hero_cards"), list) else []
    hero_tokens = [str(card or "").strip() for card in hero_cards if str(card or "").strip()]

    street = str(source.get("street") or "").strip().lower()
    if not street:
        street = detect_street(board_tokens)
        source["street"] = street

    return {
        "hero_range": str(features.get("hero_range") or "").strip(),
        "villain_range": str(features.get("villain_range") or "").strip(),
        "board": board_tokens,
        "active_node_path": str(features.get("active_node_path") or "").strip(),
        "in_position_player": _safe_int(features.get("in_position_player"), 2),
        "starting_stack": _safe_float(features.get("starting_stack"), 0.0),
        "starting_pot": _safe_float(features.get("starting_pot"), 0.0),
        "minimum_bet": _safe_float(features.get("minimum_bet"), 0.0),
        "all_in_threshold": _safe_float(features.get("all_in_threshold"), 0.67),
        "iterations": _safe_float(features.get("iterations"), 0.0),
        "min_exploitability": _safe_float(features.get("min_exploitability"), -1.0),
        "thread_count": _safe_float(features.get("thread_count"), 0.0),
        "remove_donk_bets": bool(features.get("remove_donk_bets", True)),
        "raise_cap": _safe_float(features.get("raise_cap"), 0.0),
        "compress_strategy": bool(features.get("compress_strategy", True)),
        "bet_sizing": features.get("bet_sizing") if isinstance(features.get("bet_sizing"), dict) else {},
        "facing_bet": _safe_float(features.get("facing_bet"), 0.0),
        "hero_street_commit": _safe_float(features.get("hero_street_commit"), 0.0),
        "villain_street_commit": _safe_float(features.get("villain_street_commit"), 0.0),
        "current_pot": _safe_float(features.get("current_pot", features.get("starting_pot")), 0.0),
        "hero_chips": _safe_float(features.get("hero_chips"), 0.0),
        "villain_chips": _safe_float(features.get("villain_chips"), 0.0),
        "hero_is_small_blind": bool(features.get("hero_is_small_blind", True)),
        "hero_cards": hero_tokens,
        "street": street,
    }


def validate_feature_inputs(source: Dict[str, Any], features: Dict[str, Any]) -> Dict[str, Any]:
    """Validate normalized contract inputs and return explicit extraction status."""
    source_n = _normalize_source(source)
    features_n = _normalize_features(features, source_n)
    errors: List[str] = []

    board = features_n.get("board") if isinstance(features_n.get("board"), list) else []
    board_len = len(board)
    if board_len not in {0, 3, 4, 5}:
        errors.append(f"board_card_count_invalid:{board_len}")
    for card in board:
        if not _is_valid_card_token(str(card)):
            errors.append(f"board_card_invalid:{card}")

    hero_cards = features_n.get("hero_cards") if isinstance(features_n.get("hero_cards"), list) else []
    if len(hero_cards) not in {0, 2}:
        errors.append(f"hero_card_count_invalid:{len(hero_cards)}")
    for card in hero_cards:
        if not _is_valid_card_token(str(card)):
            errors.append(f"hero_card_invalid:{card}")

    expected_street = detect_street(board)
    declared_street = str(source_n.get("street") or "").strip().lower()
    if declared_street and expected_street != "unknown" and declared_street != expected_street:
        errors.append(f"street_board_mismatch:{declared_street}->{expected_street}")

    non_negative_fields = [
        "starting_stack",
        "starting_pot",
        "minimum_bet",
        "current_pot",
        "hero_chips",
        "villain_chips",
        "facing_bet",
        "hero_street_commit",
        "villain_street_commit",
    ]
    for name in non_negative_fields:
        value = _safe_float(features_n.get(name), 0.0)
        if value < 0.0:
            errors.append(f"negative_value:{name}={value}")

    if _safe_float(features_n.get("minimum_bet"), 0.0) <= 0.0:
        errors.append("minimum_bet_nonpositive")
    if _safe_float(features_n.get("all_in_threshold"), 0.0) <= 0.0:
        errors.append("all_in_threshold_nonpositive")

    return {
        "is_valid_extraction": len(errors) == 0,
        "error_count": len(errors),
        "errors": errors,
        "source": source_n,
        "features": features_n,
    }


def _numeric_values(source: Dict[str, Any], features: Dict[str, Any]) -> List[float]:
    return [
        _safe_float(features.get("starting_stack"), 0.0),
        _safe_float(features.get("starting_pot"), 0.0),
        _safe_float(features.get("minimum_bet"), 0.0),
        _safe_float(features.get("all_in_threshold"), 0.67),
        _safe_float(features.get("iterations"), 0.0),
        _safe_float(features.get("min_exploitability"), -1.0),
        _safe_float(features.get("thread_count"), 0.0),
        _safe_float(features.get("raise_cap"), 0.0),
        _safe_float(features.get("facing_bet"), 0.0),
        _safe_float(features.get("hero_street_commit"), 0.0),
        _safe_float(features.get("villain_street_commit"), 0.0),
        _safe_float(features.get("current_pot"), 0.0),
        _safe_float(features.get("hero_chips"), 0.0),
        _safe_float(features.get("villain_chips"), 0.0),
        1.0 if bool(features.get("hero_is_small_blind", True)) else 0.0,
        1.0 if bool(features.get("remove_donk_bets", True)) else 0.0,
        1.0 if bool(features.get("compress_strategy", True)) else 0.0,
        _street_to_float(source.get("street", "")),
    ]


def _categorical_tokens(source: Dict[str, Any], features: Dict[str, Any]) -> List[str]:
    return [
        f"hr:{features.get('hero_range', '')}",
        f"vr:{features.get('villain_range', '')}",
        f"bd:{','.join(features.get('board', []) if isinstance(features.get('board'), list) else [])}",
        f"an:{features.get('active_node_path', '')}",
        f"rp:{source.get('runtime_profile', '')}",
        f"street:{source.get('street', '')}",
        f"hero_cards:{','.join(features.get('hero_cards', []) if isinstance(features.get('hero_cards'), list) else [])}",
        f"bs:{json.dumps(features.get('bet_sizing', {}), sort_keys=True)}",
    ]


def canonical_feature_payload(source: Dict[str, Any], features: Dict[str, Any]) -> Dict[str, Any]:
    source_n = _normalize_source(source)
    features_n = _normalize_features(features, source_n)
    return {
        "schema_version": FEATURE_SCHEMA_VERSION,
        "source": source_n,
        "features": features_n,
        "numeric": _numeric_values(source_n, features_n),
        "categorical": _categorical_tokens(source_n, features_n),
    }


def feature_key_hash(source: Dict[str, Any], features: Dict[str, Any]) -> str:
    payload = canonical_feature_payload(source, features)
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def feature_vector(source: Dict[str, Any], features: Dict[str, Any], input_dim: int) -> List[float]:
    dim = max(16, int(input_dim))
    payload = canonical_feature_payload(source, features)
    numeric = payload["numeric"]
    categorical = payload["categorical"]
    vec = [0.0] * dim
    for idx, value in enumerate(numeric):
        if idx >= dim:
            break
        vec[idx] = float(value)
    tail_start = min(len(numeric), max(0, dim // 4))
    tail_buckets = max(1, dim - tail_start)
    for token in categorical:
        idx = tail_start + _hash_bucket(str(token), tail_buckets)
        vec[idx] += 1.0
    return vec


def feature_vector_hash(source: Dict[str, Any], features: Dict[str, Any], input_dim: int) -> str:
    vec = feature_vector(source=source, features=features, input_dim=input_dim)
    blob = json.dumps([round(float(v), 8) for v in vec], separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def feature_contract_metadata(source: Dict[str, Any], features: Dict[str, Any], input_dim: int) -> Dict[str, Any]:
    validation = validate_feature_inputs(source, features)
    source_n = validation["source"]
    features_n = validation["features"]
    return {
        "schema_version": FEATURE_SCHEMA_VERSION,
        "contract_hash": FEATURE_CONTRACT_HASH,
        "input_dim": int(max(16, int(input_dim))),
        "feature_key_hash": feature_key_hash(source=source_n, features=features_n),
        "vector_hash": feature_vector_hash(source=source_n, features=features_n, input_dim=input_dim),
        "is_valid_extraction": bool(validation["is_valid_extraction"]),
        "validation_error_count": int(validation["error_count"]),
        "validation_errors": list(validation["errors"]),
    }


def source_features_from_spot(spot: Dict[str, Any], runtime_profile: str = "", stage: str = "") -> Tuple[Dict[str, Any], Dict[str, Any]]:
    meta = spot.get("meta") if isinstance(spot.get("meta"), dict) else {}
    board = spot.get("board") if isinstance(spot.get("board"), list) else []
    street = detect_street(board)
    source = {
        "runtime_profile": str(runtime_profile or "").strip().lower(),
        "stage": str(stage or "").strip().lower(),
        "street": street,
    }
    features = {
        "hero_range": str(spot.get("hero_range") or ""),
        "villain_range": str(spot.get("villain_range") or ""),
        "board": board,
        "active_node_path": str(spot.get("active_node_path") or ""),
        "in_position_player": _safe_int(spot.get("in_position_player"), 2),
        "starting_stack": _safe_float(spot.get("starting_stack"), 0.0),
        "starting_pot": _safe_float(spot.get("starting_pot"), 0.0),
        "minimum_bet": _safe_float(spot.get("minimum_bet"), 0.0),
        "all_in_threshold": _safe_float(spot.get("all_in_threshold"), 0.67),
        "iterations": _safe_float(spot.get("iterations"), 0.0),
        "min_exploitability": _safe_float(spot.get("min_exploitability"), -1.0),
        "thread_count": _safe_float(spot.get("thread_count"), 0.0),
        "remove_donk_bets": bool(spot.get("remove_donk_bets", True)),
        "raise_cap": _safe_float(spot.get("raise_cap"), 0.0),
        "compress_strategy": bool(spot.get("compress_strategy", True)),
        "bet_sizing": spot.get("bet_sizing") if isinstance(spot.get("bet_sizing"), dict) else {},
        "facing_bet": _safe_float(spot.get("facing_bet", meta.get("facing_bet")), 0.0),
        "hero_street_commit": _safe_float(spot.get("hero_street_commit", meta.get("hero_street_commit")), 0.0),
        "villain_street_commit": _safe_float(spot.get("villain_street_commit", meta.get("villain_street_commit")), 0.0),
        "current_pot": _safe_float(spot.get("current_pot", meta.get("current_pot", spot.get("starting_pot"))), 0.0),
        "hero_chips": _safe_float(spot.get("hero_chips", meta.get("current_hero_chips")), 0.0),
        "villain_chips": _safe_float(spot.get("villain_chips", meta.get("current_villain_chips")), 0.0),
        "hero_is_small_blind": bool(spot.get("hero_is_small_blind", meta.get("hero_is_small_blind", True))),
        "hero_cards": meta.get("hero_cards") if isinstance(meta.get("hero_cards"), list) else [],
    }
    return _normalize_source(source), _normalize_features(features, source)
