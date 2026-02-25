#!/usr/bin/env python
"""Aggregate opponent features across PHH hands."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from .features import (
    PlayerFeatureCounter,
    extract_hand_feature_counters,
    smoothed_rate,
)
from .parser import ParsedHand, parse_phh_file


@dataclass
class AggregationConfig:
    alpha: float = 2.0
    beta: float = 2.0
    big_bet_threshold: float = 0.75
    allowed_variants: Tuple[str, ...] = ("NT",)


def _counter_to_profile(
    counter: PlayerFeatureCounter,
    *,
    alpha: float,
    beta: float,
    big_bet_threshold: float,
) -> Dict[str, Any]:
    fold_to_turn_probe = smoothed_rate(
        counter.turn_probe_folds,
        counter.turn_probe_opportunities,
        alpha=alpha,
        beta=beta,
    )
    fold_to_river_bigbet = smoothed_rate(
        counter.river_bigbet_folds,
        counter.river_bigbet_opportunities,
        alpha=alpha,
        beta=beta,
    )
    return {
        "hands_seen": counter.hands_seen,
        "turn_probe_opportunities": counter.turn_probe_opportunities,
        "turn_probe_folds": counter.turn_probe_folds,
        "fold_to_turn_probe": fold_to_turn_probe,
        "river_bigbet_opportunities": counter.river_bigbet_opportunities,
        "river_bigbet_folds": counter.river_bigbet_folds,
        "fold_to_river_bigbet": fold_to_river_bigbet,
        "alpha": alpha,
        "beta": beta,
        "big_bet_threshold_pot_ratio": big_bet_threshold,
    }


def _token_to_name_map(hand: ParsedHand) -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    for idx, name in enumerate(hand.players, start=1):
        mapping[f"p{idx}"] = name
    return mapping


def aggregate_opponent_features(
    phh_files: Iterable[Path],
    *,
    config: Optional[AggregationConfig] = None,
) -> Dict[str, Any]:
    cfg = config or AggregationConfig()
    allowed = {v.strip().upper() for v in cfg.allowed_variants}

    by_player: Dict[str, PlayerFeatureCounter] = {}
    hands_index: Dict[str, Dict[str, Any]] = {}
    parsed_hands = 0
    skipped_variant = 0
    errors: List[Dict[str, str]] = []

    for path in phh_files:
        try:
            hand = parse_phh_file(path)
        except Exception as exc:  # pylint: disable=broad-except
            errors.append({"path": str(path), "error": str(exc)})
            continue

        if hand.variant.strip().upper() not in allowed:
            skipped_variant += 1
            continue

        parsed_hands += 1
        per_token = extract_hand_feature_counters(hand, big_bet_threshold=cfg.big_bet_threshold)
        token_to_name = _token_to_name_map(hand)
        per_name: Dict[str, PlayerFeatureCounter] = {}
        for token, counter in per_token.items():
            name = token_to_name.get(token, token)
            acc = per_name.setdefault(name, PlayerFeatureCounter())
            acc.hands_seen += counter.hands_seen
            acc.turn_probe_opportunities += counter.turn_probe_opportunities
            acc.turn_probe_folds += counter.turn_probe_folds
            acc.river_bigbet_opportunities += counter.river_bigbet_opportunities
            acc.river_bigbet_folds += counter.river_bigbet_folds

        for name, counter in per_name.items():
            total = by_player.setdefault(name, PlayerFeatureCounter())
            total.hands_seen += counter.hands_seen
            total.turn_probe_opportunities += counter.turn_probe_opportunities
            total.turn_probe_folds += counter.turn_probe_folds
            total.river_bigbet_opportunities += counter.river_bigbet_opportunities
            total.river_bigbet_folds += counter.river_bigbet_folds

        hands_index[str(path.resolve())] = {
            "players": hand.players,
            "variant": hand.variant,
            "source_path": str(path.resolve()),
        }

    pool_counter = PlayerFeatureCounter()
    for c in by_player.values():
        pool_counter.hands_seen += c.hands_seen
        pool_counter.turn_probe_opportunities += c.turn_probe_opportunities
        pool_counter.turn_probe_folds += c.turn_probe_folds
        pool_counter.river_bigbet_opportunities += c.river_bigbet_opportunities
        pool_counter.river_bigbet_folds += c.river_bigbet_folds

    profiles_by_player = {
        name: _counter_to_profile(
            counter,
            alpha=cfg.alpha,
            beta=cfg.beta,
            big_bet_threshold=cfg.big_bet_threshold,
        )
        for name, counter in sorted(by_player.items())
    }
    pool_profile = _counter_to_profile(
        pool_counter,
        alpha=cfg.alpha,
        beta=cfg.beta,
        big_bet_threshold=cfg.big_bet_threshold,
    )

    return {
        "config": {
            "alpha": cfg.alpha,
            "beta": cfg.beta,
            "big_bet_threshold": cfg.big_bet_threshold,
            "allowed_variants": sorted(allowed),
        },
        "summary": {
            "parsed_hands": parsed_hands,
            "skipped_variant": skipped_variant,
            "error_count": len(errors),
            "player_count": len(profiles_by_player),
        },
        "pool_profile": pool_profile,
        "profiles_by_player": profiles_by_player,
        "hands_index": hands_index,
        "errors": errors,
    }


def build_spot_opponent_profile(
    aggregate_payload: Dict[str, Any],
    *,
    source_phh_path: Optional[str],
    mode: str = "pool",
) -> Dict[str, Any]:
    pool_profile = dict(aggregate_payload.get("pool_profile") or {})
    profiles_by_player = aggregate_payload.get("profiles_by_player") or {}
    hands_index = aggregate_payload.get("hands_index") or {}
    mode_norm = (mode or "pool").strip().lower()

    profile: Dict[str, Any] = {
        "profile_source": "phh_features_v1",
        "profile_mode": mode_norm,
        **pool_profile,
    }
    if mode_norm == "off":
        return {"profile_source": "phh_features_v1", "profile_mode": "off"}

    if mode_norm != "pool" or not source_phh_path:
        return profile

    try:
        resolved = str(Path(source_phh_path).resolve())
    except Exception:  # pylint: disable=broad-except
        return profile
    hand_meta = hands_index.get(resolved)
    if not isinstance(hand_meta, dict):
        return profile
    players = hand_meta.get("players")
    if not isinstance(players, list):
        return profile

    players_out = []
    for name in players:
        player_name = str(name)
        player_profile = profiles_by_player.get(player_name)
        if not isinstance(player_profile, dict):
            continue
        players_out.append({"player": player_name, **player_profile})
    if players_out:
        profile["hand_players"] = players_out
    return profile
