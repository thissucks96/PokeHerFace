#!/usr/bin/env python
"""Build smoothed opponent-feature profiles from PHH files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

from phh_features.aggregate import AggregationConfig, aggregate_opponent_features


def _iter_phh_files(phh_dir: Path) -> Iterable[Path]:
    return sorted(phh_dir.rglob("*.phh"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract smoothed opponent features from PHH files.")
    parser.add_argument("--phh-dir", required=True, help="Directory containing .phh files.")
    parser.add_argument("--output", required=True, help="Summary output JSON path.")
    parser.add_argument("--profiles-jsonl", help="Optional player-profiles JSONL output path.")
    parser.add_argument("--alpha", type=float, default=2.0, help="Bayesian smoothing alpha.")
    parser.add_argument("--beta", type=float, default=2.0, help="Bayesian smoothing beta.")
    parser.add_argument(
        "--big-bet-threshold",
        type=float,
        default=0.75,
        help="River big-bet threshold as bet_size / pot_before_bet.",
    )
    parser.add_argument(
        "--allowed-variants",
        nargs="+",
        default=["NT"],
        help="Allowed PHH variants for extraction (default: NT).",
    )
    args = parser.parse_args()

    phh_dir = Path(args.phh_dir).resolve()
    out_path = Path(args.output).resolve()
    if not phh_dir.exists():
        raise SystemExit(f"PHH directory not found: {phh_dir}")

    config = AggregationConfig(
        alpha=args.alpha,
        beta=args.beta,
        big_bet_threshold=args.big_bet_threshold,
        allowed_variants=tuple(args.allowed_variants),
    )
    payload = aggregate_opponent_features(_iter_phh_files(phh_dir), config=config)
    payload["phh_dir"] = str(phh_dir)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    if args.profiles_jsonl:
        jsonl_path = Path(args.profiles_jsonl).resolve()
        jsonl_path.parent.mkdir(parents=True, exist_ok=True)
        with jsonl_path.open("w", encoding="utf-8") as f:
            for player, profile in sorted((payload.get("profiles_by_player") or {}).items()):
                row = {"player": player, **profile}
                f.write(json.dumps(row, ensure_ascii=True) + "\n")

    print(
        json.dumps(
            {
                "output": str(out_path),
                "parsed_hands": payload.get("summary", {}).get("parsed_hands"),
                "player_count": payload.get("summary", {}).get("player_count"),
                "error_count": payload.get("summary", {}).get("error_count"),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

