#!/usr/bin/env python
"""PHH parsing utilities for opponent-feature extraction."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


@dataclass
class ActionEvent:
    street: str
    actor: Optional[str]
    verb: str
    amount: Optional[float]
    raw: str


@dataclass
class ParsedHand:
    source_path: str
    variant: str
    players: List[str]
    actions: List[ActionEvent]
    blinds_or_straddles: List[float]
    antes: List[float]


_VALUE_LINE = r"^{key}\s*=\s*(.+)$"
_ACTION_BLOCK = r"actions\s*=\s*\[(.*?)\]\s*(?:\n\w+\s*=|\Z)"


def _extract_value_block(text: str, key: str) -> str:
    pattern = re.compile(_VALUE_LINE.format(key=re.escape(key)), re.MULTILINE)
    m = pattern.search(text)
    return m.group(1).strip() if m else ""


def _extract_actions_raw(text: str) -> List[str]:
    m = re.search(_ACTION_BLOCK, text, re.DOTALL)
    if not m:
        return []
    block = m.group(1)
    return re.findall(r"""['"]([^'"]+)['"]""", block)


def _parse_string_list(raw: str) -> List[str]:
    blob = raw.strip()
    if not blob.startswith("[") or not blob.endswith("]"):
        return []
    return [token.strip() for token in re.findall(r"""['"]([^'"]+)['"]""", blob)]


def _parse_number_list(raw: str) -> List[float]:
    blob = raw.strip()
    if not blob.startswith("[") or not blob.endswith("]"):
        return []
    out: List[float] = []
    for part in blob[1:-1].split(","):
        token = part.strip()
        if not token:
            continue
        try:
            out.append(float(token))
        except ValueError:
            continue
    return out


def _street_transition_from_deal(card_blob: str, current_street: str) -> str:
    cards = card_blob.strip()
    if len(cards) == 6:
        return "flop"
    if len(cards) == 2:
        if current_street == "flop":
            return "turn"
        if current_street == "turn":
            return "river"
    return current_street


def _parse_action_token(token: str, street: str) -> ActionEvent:
    parts = token.strip().split()
    if not parts:
        return ActionEvent(street=street, actor=None, verb="unknown", amount=None, raw=token)

    if len(parts) >= 3 and parts[0] == "d" and parts[1] == "db":
        return ActionEvent(street=street, actor=None, verb="deal_board", amount=None, raw=token)
    if len(parts) >= 3 and parts[0] == "d" and parts[1] == "dh":
        return ActionEvent(street=street, actor=None, verb="deal_hole", amount=None, raw=token)

    actor = parts[0]
    verb = parts[1] if len(parts) >= 2 else "unknown"
    amount: Optional[float] = None
    if len(parts) >= 3:
        try:
            amount = float(parts[2])
        except ValueError:
            amount = None
    return ActionEvent(street=street, actor=actor, verb=verb, amount=amount, raw=token)


def parse_phh_text(text: str, *, source_path: str = "") -> ParsedHand:
    variant = _extract_value_block(text, "variant").strip().strip('"').strip("'")
    players = _parse_string_list(_extract_value_block(text, "players"))
    blinds_or_straddles = _parse_number_list(_extract_value_block(text, "blinds_or_straddles"))
    antes = _parse_number_list(_extract_value_block(text, "antes"))

    actions: List[ActionEvent] = []
    current_street = "preflop"
    for token in _extract_actions_raw(text):
        raw = token.strip()
        if raw.startswith("d db "):
            card_blob = raw.split(" ", 2)[2]
            current_street = _street_transition_from_deal(card_blob, current_street)
        event = _parse_action_token(raw, current_street)
        actions.append(event)

    return ParsedHand(
        source_path=source_path,
        variant=variant,
        players=players,
        actions=actions,
        blinds_or_straddles=blinds_or_straddles,
        antes=antes,
    )


def parse_phh_file(path: Path) -> ParsedHand:
    text = path.read_text(encoding="utf-8")
    return parse_phh_text(text, source_path=str(path))

