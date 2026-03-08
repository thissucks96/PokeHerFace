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


FEATURE_SCHEMA_VERSION = "feature_contract_v3"
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


def _effective_stack_under_pressure(features: Dict[str, Any]) -> float:
    hero_chips = _safe_float(features.get("hero_chips"), 0.0)
    villain_chips = _safe_float(features.get("villain_chips"), 0.0)
    if hero_chips > 0.0 and villain_chips > 0.0:
        return min(hero_chips, villain_chips)

    starting_stack = _safe_float(features.get("starting_stack"), 0.0)
    hero_commit = _safe_float(features.get("hero_street_commit"), 0.0)
    villain_commit = _safe_float(features.get("villain_street_commit"), 0.0)
    if starting_stack > 0.0:
        hero_remaining = max(0.0, starting_stack - hero_commit)
        villain_remaining = max(0.0, starting_stack - villain_commit)
        return min(hero_remaining, villain_remaining)
    return 0.0


def _pot_odds(features: Dict[str, Any]) -> float:
    facing_bet = max(0.0, _safe_float(features.get("facing_bet"), 0.0))
    current_pot = max(0.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 0.0))
    denom = current_pot + facing_bet
    if facing_bet <= 0.0 or denom <= 0.0:
        return 0.0
    return facing_bet / denom


def _spr_under_pressure(features: Dict[str, Any]) -> float:
    facing_bet = max(0.0, _safe_float(features.get("facing_bet"), 0.0))
    current_pot = max(0.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 0.0))
    denom = current_pot + facing_bet
    if denom <= 0.0:
        return 0.0
    return _effective_stack_under_pressure(features) / denom


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
    "pot_odds",
    "spr_under_pressure",
    "hand_category",
    "board_paired",
    "board_monotone",
    "board_two_tone",
    "board_connected",
    "board_dry",
    "flush_draw_present",
    "oesd_present",
    "gutshot_present",
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
_RANK_VALUE_MAP = {
    "2": 2,
    "3": 3,
    "4": 4,
    "5": 5,
    "6": 6,
    "7": 7,
    "8": 8,
    "9": 9,
    "T": 10,
    "J": 11,
    "Q": 12,
    "K": 13,
    "A": 14,
}


def _normalize_source(source: Dict[str, Any]) -> Dict[str, Any]:
    out = {
        "runtime_profile": str(source.get("runtime_profile") or "").strip().lower(),
        "street": str(source.get("street") or "").strip().lower(),
    }
    return out


def _is_valid_card_token(token: str) -> bool:
    return bool(_CARD_TOKEN_RE.match(str(token or "").strip().upper()))


def _normalize_card_token(token: Any) -> str:
    value = str(token or "").strip()
    if not value:
        return ""
    upper = value.upper()
    if upper.startswith("10") and len(upper) >= 3:
        rank_token = "T"
        suit_token = upper[2]
    elif len(upper) >= 2:
        rank_token = upper[0]
        suit_token = upper[-1]
    else:
        return ""
    normalized = f"{rank_token}{suit_token}"
    return normalized if _is_valid_card_token(normalized) else ""


def _parse_card(token: str) -> tuple[int, str] | None:
    normalized = _normalize_card_token(token)
    if not normalized:
        return None
    rank = _RANK_VALUE_MAP.get(normalized[0])
    suit = normalized[1].lower()
    if rank is None or suit not in {"s", "h", "d", "c"}:
        return None
    return rank, suit


def _extract_board_texture_flags(board_tokens: list[str]) -> dict[str, bool]:
    ranks: list[int] = []
    suits: list[str] = []
    for raw_card in board_tokens[:5]:
        parsed = _parse_card(raw_card)
        if parsed is None:
            continue
        rank, suit = parsed
        ranks.append(rank)
        suits.append(suit)
    paired = len(set(ranks)) < len(ranks) if ranks else False
    suit_counts = {suit: suits.count(suit) for suit in set(suits)}
    max_suit_count = max(suit_counts.values()) if suit_counts else 0
    monotone = max_suit_count >= 3
    two_tone = max_suit_count == 2
    unique_ranks = sorted(set(ranks))
    connected = len(unique_ranks) >= 3 and (max(unique_ranks) - min(unique_ranks) <= (len(unique_ranks) + 1))
    dry = bool(ranks) and not paired and not monotone and not connected
    return {
        "paired": paired,
        "monotone": monotone,
        "two_tone": two_tone,
        "connected": connected,
        "dry": dry,
    }


def _evaluate_five_cards(cards: list[str]) -> tuple[int, list[int]]:
    parsed = []
    for token in cards:
        parsed_card = _parse_card(token)
        if parsed_card is None:
            return (0, [])
        parsed.append(parsed_card)
    parsed = sorted(parsed, key=lambda row: row[0], reverse=True)
    ranks = [row[0] for row in parsed]
    suits = [row[1] for row in parsed]
    is_flush = len(set(suits)) == 1

    unique_ranks = sorted(set(ranks), reverse=True)
    is_straight = False
    straight_high = 0
    if len(unique_ranks) == 5:
        if unique_ranks[0] - unique_ranks[4] == 4:
            is_straight = True
            straight_high = unique_ranks[0]
        elif unique_ranks == [14, 5, 4, 3, 2]:
            is_straight = True
            straight_high = 5

    rank_counts: Dict[int, int] = {}
    for rank in ranks:
        rank_counts[rank] = rank_counts.get(rank, 0) + 1
    groups = sorted([(count, rank) for rank, count in rank_counts.items()], reverse=True)

    if is_straight and is_flush:
        return (8, [straight_high])
    if groups[0][0] == 4:
        quad_rank = groups[0][1]
        kicker = max(rank for rank in ranks if rank != quad_rank)
        return (7, [quad_rank, kicker])
    if groups[0][0] == 3 and groups[1][0] == 2:
        return (6, [groups[0][1], groups[1][1]])
    if is_flush:
        return (5, sorted(ranks, reverse=True))
    if is_straight:
        return (4, [straight_high])
    if groups[0][0] == 3:
        trips = groups[0][1]
        kickers = sorted([rank for rank in ranks if rank != trips], reverse=True)
        return (3, [trips] + kickers)
    if groups[0][0] == 2 and groups[1][0] == 2:
        high_pair = max(groups[0][1], groups[1][1])
        low_pair = min(groups[0][1], groups[1][1])
        kicker = max(rank for rank in ranks if rank not in {high_pair, low_pair})
        return (2, [high_pair, low_pair, kicker])
    if groups[0][0] == 2:
        pair_rank = groups[0][1]
        kickers = sorted([rank for rank in ranks if rank != pair_rank], reverse=True)
        return (1, [pair_rank] + kickers)
    return (0, sorted(ranks, reverse=True))


def _evaluate_best_hand_category(hero_cards: list[str], board_tokens: list[str]) -> int:
    cards = [_normalize_card_token(card) for card in (hero_cards + board_tokens)]
    cards = [card for card in cards if card]
    if len(cards) < 5:
        return 0
    total = len(cards)
    best: tuple[int, list[int]] | None = None
    for i in range(total - 4):
        for j in range(i + 1, total - 3):
            for k in range(j + 1, total - 2):
                for m in range(k + 1, total - 1):
                    for n in range(m + 1, total):
                        score = _evaluate_five_cards([cards[i], cards[j], cards[k], cards[m], cards[n]])
                        if best is None or score > best:
                            best = score
    return int(best[0]) if best is not None else 0


def _draw_flags(hero_cards: list[str], board_tokens: list[str], made_category: int) -> dict[str, bool]:
    cards = [_normalize_card_token(card) for card in (hero_cards + board_tokens)]
    cards = [card for card in cards if card]
    parsed = [_parse_card(card) for card in cards]
    parsed = [item for item in parsed if item is not None]
    ranks = sorted(set(rank for rank, _suit in parsed))
    suits = [suit for _rank, suit in parsed]

    flush_draw = False
    if made_category < 5:
        suit_counts = {suit: suits.count(suit) for suit in set(suits)}
        flush_draw = bool(suit_counts and max(suit_counts.values()) >= 4)

    if 14 in ranks:
        ranks_with_wheel = sorted(set(ranks + [1]))
    else:
        ranks_with_wheel = ranks

    straight_present = made_category >= 4
    oesd = False
    gutshot = False
    if not straight_present:
        for start in range(1, 11):
            sequence = list(range(start, start + 5))
            present = [rank for rank in sequence if rank in ranks_with_wheel]
            if len(present) != 4:
                continue
            missing = [rank for rank in sequence if rank not in ranks_with_wheel]
            if not missing:
                continue
            miss = missing[0]
            if miss == sequence[0] or miss == sequence[-1]:
                oesd = True
            else:
                gutshot = True
    return {
        "flush_draw_present": flush_draw,
        "oesd_present": oesd,
        "gutshot_present": gutshot,
    }


def _normalize_features(features: Dict[str, Any], source: Dict[str, Any]) -> Dict[str, Any]:
    board = features.get("board") if isinstance(features.get("board"), list) else []
    board_tokens = [str(card or "").strip() for card in board if str(card or "").strip()]
    hero_cards = features.get("hero_cards") if isinstance(features.get("hero_cards"), list) else []
    hero_tokens = [str(card or "").strip() for card in hero_cards if str(card or "").strip()]

    street = str(source.get("street") or "").strip().lower()
    if not street:
        street = detect_street(board_tokens)
        source["street"] = street

    out = {
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
    out["pot_odds"] = _pot_odds(out)
    out["spr_under_pressure"] = _spr_under_pressure(out)
    texture = _extract_board_texture_flags(board_tokens)
    made_category = _evaluate_best_hand_category(hero_tokens, board_tokens)
    draws = _draw_flags(hero_tokens, board_tokens, made_category)
    out["hand_category"] = float(made_category)
    out["board_paired"] = 1.0 if texture["paired"] else 0.0
    out["board_monotone"] = 1.0 if texture["monotone"] else 0.0
    out["board_two_tone"] = 1.0 if texture["two_tone"] else 0.0
    out["board_connected"] = 1.0 if texture["connected"] else 0.0
    out["board_dry"] = 1.0 if texture["dry"] else 0.0
    out["flush_draw_present"] = 1.0 if draws["flush_draw_present"] else 0.0
    out["oesd_present"] = 1.0 if draws["oesd_present"] else 0.0
    out["gutshot_present"] = 1.0 if draws["gutshot_present"] else 0.0
    return out


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
        _safe_float(features.get("pot_odds"), 0.0),
        _safe_float(features.get("spr_under_pressure"), 0.0),
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
