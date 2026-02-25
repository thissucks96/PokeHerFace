#!/usr/bin/env python
"""Opponent-feature extraction from parsed PHH hands."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Set

from .parser import ActionEvent, ParsedHand


BETTING_STREETS = ("preflop", "flop", "turn", "river")
PLAYER_TOKEN_RE = re.compile(r"^p(\d+)$", re.IGNORECASE)


@dataclass
class PlayerFeatureCounter:
    hands_seen: int = 0
    turn_probe_opportunities: int = 0
    turn_probe_folds: int = 0
    river_bigbet_opportunities: int = 0
    river_bigbet_folds: int = 0


def _is_player_token(value: Optional[str]) -> bool:
    if not value:
        return False
    return PLAYER_TOKEN_RE.match(value.strip()) is not None


def _player_tokens_in_hand(hand: ParsedHand) -> List[str]:
    tokens: Set[str] = set()
    for event in hand.actions:
        if _is_player_token(event.actor):
            tokens.add(event.actor.strip().lower())
    if not tokens and hand.players:
        for idx in range(1, len(hand.players) + 1):
            tokens.add(f"p{idx}")
    return sorted(tokens, key=lambda x: int(x[1:]) if x[1:].isdigit() else 999)


def _token_to_name_map(hand: ParsedHand) -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    for idx, name in enumerate(hand.players, start=1):
        token = f"p{idx}"
        mapping[token] = name
    for token in _player_tokens_in_hand(hand):
        mapping.setdefault(token, token)
    return mapping


def _street_actions(hand: ParsedHand, street: str) -> List[ActionEvent]:
    return [
        e
        for e in hand.actions
        if e.street == street and e.actor and e.verb in {"cc", "cbr", "f"}
    ]


def _is_flop_checked_through(flop_actions: List[ActionEvent]) -> bool:
    if len(flop_actions) < 2:
        return False
    if any(e.verb == "cbr" for e in flop_actions):
        return False
    return True


def _extract_turn_probe_response(turn_actions: List[ActionEvent]) -> Optional[tuple[str, str]]:
    """Return (defender_token, defender_response_verb) for turn-probe pattern."""
    for i in range(0, max(0, len(turn_actions) - 1)):
        first = turn_actions[i]
        second = turn_actions[i + 1]
        if first.verb != "cc":
            continue
        if first.actor == second.actor:
            continue
        if second.verb != "cbr":
            continue
        defender = first.actor
        for j in range(i + 2, len(turn_actions)):
            response = turn_actions[j]
            if response.actor != defender:
                continue
            if response.verb in {"f", "cc", "cbr"}:
                return defender, response.verb
            break
    return None


def _simulate_river_bigbet_features(
    hand: ParsedHand,
    counters_by_token: Dict[str, PlayerFeatureCounter],
    *,
    big_bet_threshold: float,
) -> None:
    tokens = _player_tokens_in_hand(hand)
    if not tokens:
        return

    active = set(tokens)
    contributions: Dict[str, float] = {token: 0.0 for token in tokens}
    max_contrib = 0.0
    pot = float(sum(hand.blinds_or_straddles) + sum(hand.antes))
    current_street = "preflop"
    pending_bigbet: Dict[str, bool] = {}

    for event in hand.actions:
        street = event.street
        if street not in BETTING_STREETS:
            continue
        if street != current_street:
            current_street = street
            contributions = {token: 0.0 for token in tokens}
            max_contrib = 0.0
            pending_bigbet.clear()

        actor = (event.actor or "").strip().lower()
        if actor not in active or actor not in contributions:
            continue

        # A pending big-bet opportunity is counted at response action time.
        if pending_bigbet.get(actor) and event.verb in {"f", "cc", "cbr"}:
            counters_by_token[actor].river_bigbet_opportunities += 1
            if event.verb == "f":
                counters_by_token[actor].river_bigbet_folds += 1
            pending_bigbet.pop(actor, None)

        if event.verb == "f":
            active.discard(actor)
            pending_bigbet.pop(actor, None)
            continue

        actor_contrib = contributions.get(actor, 0.0)
        to_call = max(0.0, max_contrib - actor_contrib)

        if event.verb == "cc":
            if to_call > 0.0:
                contributions[actor] = actor_contrib + to_call
                pot += to_call
            continue

        if event.verb != "cbr":
            continue
        if event.amount is None:
            continue

        target = max(float(event.amount), max_contrib)
        delta = max(0.0, target - actor_contrib)
        pot_before = pot
        contributions[actor] = actor_contrib + delta
        pot += delta
        max_contrib = max(max_contrib, target)

        if street != "river" or delta <= 0.0 or pot_before <= 0.0:
            continue
        ratio = delta / pot_before
        if ratio < big_bet_threshold:
            continue

        for other in list(active):
            if other == actor:
                continue
            if contributions.get(other, 0.0) < max_contrib:
                pending_bigbet[other] = True


def extract_hand_feature_counters(
    hand: ParsedHand,
    *,
    big_bet_threshold: float = 0.75,
) -> Dict[str, PlayerFeatureCounter]:
    counters_by_token = {token: PlayerFeatureCounter(hands_seen=1) for token in _player_tokens_in_hand(hand)}
    if not counters_by_token:
        return {}

    flop_actions = _street_actions(hand, "flop")
    turn_actions = _street_actions(hand, "turn")
    if _is_flop_checked_through(flop_actions):
        turn_probe = _extract_turn_probe_response(turn_actions)
        if turn_probe is not None:
            defender, response_verb = turn_probe
            if defender in counters_by_token:
                counters_by_token[defender].turn_probe_opportunities += 1
                if response_verb == "f":
                    counters_by_token[defender].turn_probe_folds += 1

    _simulate_river_bigbet_features(
        hand,
        counters_by_token,
        big_bet_threshold=big_bet_threshold,
    )
    return counters_by_token


def merge_player_feature_counters(
    counters_list: Iterable[Dict[str, PlayerFeatureCounter]],
) -> Dict[str, PlayerFeatureCounter]:
    merged: Dict[str, PlayerFeatureCounter] = {}
    for counters in counters_list:
        for player, c in counters.items():
            acc = merged.setdefault(player, PlayerFeatureCounter())
            acc.hands_seen += c.hands_seen
            acc.turn_probe_opportunities += c.turn_probe_opportunities
            acc.turn_probe_folds += c.turn_probe_folds
            acc.river_bigbet_opportunities += c.river_bigbet_opportunities
            acc.river_bigbet_folds += c.river_bigbet_folds
    return merged


def smoothed_rate(successes: int, opportunities: int, *, alpha: float = 2.0, beta: float = 2.0) -> float:
    denom = float(opportunities) + float(alpha) + float(beta)
    if denom <= 0.0:
        return 0.0
    return (float(successes) + float(alpha)) / denom

