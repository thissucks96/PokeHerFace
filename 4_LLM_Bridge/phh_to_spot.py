#!/usr/bin/env python
"""Convert a PHH hand history file to a shark_cli-compatible spot.json payload."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import List


DEFAULT_HERO_RANGE = "55+,A2s+,K7s+,Q8s+,J8s+,T8s+,97s+,87s,76s,A9o+,KTo+,QJo"
DEFAULT_VILLAIN_RANGE = "33+,A2s+,K2s+,Q5s+,J7s+,T7s+,96s+,85s+,75s+,64s+,A5o+,K9o+,Q9o+,J9o+,T9o"


def _extract_value_block(text: str, key: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)}\s*=\s*(.+)$", re.MULTILINE)
    m = pattern.search(text)
    if m:
        return m.group(1).strip()
    return ""


def _extract_actions(text: str) -> List[str]:
    m = re.search(r"actions\s*=\s*\[(.*?)\]\s*(?:\n\w+\s*=|\Z)", text, re.DOTALL)
    if not m:
        return []
    block = m.group(1)
    # Support PHH action arrays quoted with either single or double quotes.
    return re.findall(r"""['"]([^'"]+)['"]""", block)


def _parse_int_list(raw: str) -> List[int]:
    raw = raw.strip()
    if not raw.startswith("[") or not raw.endswith("]"):
        return []
    out = []
    for part in raw[1:-1].split(","):
        p = part.strip()
        if not p:
            continue
        try:
            out.append(int(float(p)))
        except ValueError:
            continue
    return out


def _parse_cards(card_blob: str) -> List[str]:
    blob = card_blob.strip()
    if len(blob) % 2 != 0:
        return []
    return [blob[i : i + 2] for i in range(0, len(blob), 2)]


def _normalize_token(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return value.strip()


def _extract_board(actions: List[str]) -> List[str]:
    board: List[str] = []
    for action in actions:
        action = action.strip()
        if not action.startswith("d db "):
            continue
        card_blob = action.split(" ", 2)[2]
        cards = _parse_cards(card_blob)
        if len(cards) == 3 and len(board) < 3:
            board = cards
        elif len(cards) == 1 and len(board) < 5:
            board.append(cards[0])
    return board


def build_spot_from_phh(
    text: str,
    *,
    street: str,
    hero_range: str,
    villain_range: str,
    iterations: int,
    thread_count: int,
) -> dict:
    variant = _normalize_token(_extract_value_block(text, "variant"))
    if variant != "NT":
        raise ValueError(f"Unsupported PHH variant '{variant}'. Expected NT.")

    blinds = _parse_int_list(_extract_value_block(text, "blinds_or_straddles"))
    antes = _parse_int_list(_extract_value_block(text, "antes"))
    stacks = _parse_int_list(_extract_value_block(text, "starting_stacks"))
    min_bet_raw = _extract_value_block(text, "min_bet")
    try:
        minimum_bet = int(float(min_bet_raw)) if min_bet_raw else (blinds[1] if len(blinds) > 1 else 2)
    except ValueError:
        minimum_bet = blinds[1] if len(blinds) > 1 else 2

    starting_pot = sum(blinds) + sum(antes)
    starting_stack = min(stacks) if stacks else 100

    actions = _extract_actions(text)
    full_board = _extract_board(actions)
    if len(full_board) < 3:
        raise ValueError("Could not derive at least flop board from PHH actions.")

    street_to_len = {"flop": 3, "turn": 4, "river": 5}
    board_len = street_to_len.get(street.lower(), 3)
    board = full_board[:board_len]
    if len(board) < 3:
        board = full_board[:3]

    return {
        "hero_range": hero_range,
        "villain_range": villain_range,
        "board": board,
        "in_position_player": 2,
        "starting_stack": starting_stack,
        "starting_pot": starting_pot if starting_pot > 0 else 10,
        "minimum_bet": minimum_bet if minimum_bet > 0 else 2,
        "all_in_threshold": 0.67,
        "iterations": iterations,
        "min_exploitability": -1.0,
        "thread_count": thread_count,
        "remove_donk_bets": True,
        "raise_cap": 3,
        "compress_strategy": True,
        "bet_sizing": {
            "flop": {"bet_sizes": [0.5, 1.0], "raise_sizes": [1.0]},
            "turn": {"bet_sizes": [0.33, 0.66, 1.0], "raise_sizes": [0.5, 1.0]},
            "river": {"bet_sizes": [0.33, 0.66, 1.0], "raise_sizes": [0.5, 1.0]},
        },
        "meta": {
            "source": "phh",
            "street_target": street.lower(),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert PHH file to shark_cli spot.json.")
    parser.add_argument("--input", required=True, help="Path to .phh file.")
    parser.add_argument("--output", required=True, help="Path to output spot JSON.")
    parser.add_argument("--street", default="flop", choices=["flop", "turn", "river"], help="Target street snapshot.")
    parser.add_argument("--hero-range", default=DEFAULT_HERO_RANGE)
    parser.add_argument("--villain-range", default=DEFAULT_VILLAIN_RANGE)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--thread-count", type=int, default=14)
    args = parser.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output)
    if not in_path.exists():
        raise SystemExit(f"PHH input not found: {in_path}")

    text = in_path.read_text(encoding="utf-8")
    spot = build_spot_from_phh(
        text,
        street=args.street,
        hero_range=args.hero_range,
        villain_range=args.villain_range,
        iterations=args.iterations,
        thread_count=args.thread_count,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(spot, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote PHH-derived spot JSON: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
