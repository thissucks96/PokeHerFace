#!/usr/bin/env python3
"""Repair facing_bet in frozen reference labels using active_node_path fallback."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from shared_feature_contract import FEATURE_DEFAULT_INPUT_DIM, feature_contract_metadata


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


def _extract_last_bet_amount_from_active_node_path(active_node_path: str) -> int | None:
    path_value = str(active_node_path or "").strip().lower()
    if not path_value:
        return None
    for segment in reversed(path_value.split("/")):
        token = segment.strip()
        if ":bet:" not in token and ":raise:" not in token:
            continue
        try:
            return int(float(token.rsplit(":", 1)[1]))
        except (TypeError, ValueError):
            continue
    return None


def _effective_stack_under_pressure(features: dict[str, Any]) -> float:
    hero_chips = _safe_float(features.get("hero_chips"), 0.0)
    villain_chips = _safe_float(features.get("villain_chips"), 0.0)
    if hero_chips > 0.0 and villain_chips > 0.0:
        return min(hero_chips, villain_chips)

    starting_stack = _safe_float(features.get("starting_stack"), 0.0)
    hero_commit = _safe_float(features.get("hero_street_commit"), 0.0)
    villain_commit = _safe_float(features.get("villain_street_commit"), 0.0)
    if starting_stack > 0.0:
        return min(
            max(0.0, starting_stack - hero_commit),
            max(0.0, starting_stack - villain_commit),
        )
    return 0.0


def _pot_odds(features: dict[str, Any]) -> float:
    facing_bet = max(0.0, _safe_float(features.get("facing_bet"), 0.0))
    current_pot = max(0.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 0.0))
    denom = current_pot + facing_bet
    if facing_bet <= 0.0 or denom <= 0.0:
        return 0.0
    return facing_bet / denom


def _spr_under_pressure(features: dict[str, Any]) -> float:
    facing_bet = max(0.0, _safe_float(features.get("facing_bet"), 0.0))
    current_pot = max(0.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 0.0))
    denom = current_pot + facing_bet
    if denom <= 0.0:
        return 0.0
    return _effective_stack_under_pressure(features) / denom


def _repair_row(row: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    source_row = row.get("source_row") if isinstance(row.get("source_row"), dict) else None
    if not source_row:
        return row, False
    features = source_row.get("features") if isinstance(source_row.get("features"), dict) else None
    source = source_row.get("source") if isinstance(source_row.get("source"), dict) else {}
    if not features:
        return row, False

    changed = False
    current_facing = _safe_int(features.get("facing_bet"), 0)
    if current_facing <= 0:
        active = str(features.get("active_node_path") or "").strip()
        derived = _safe_int(_extract_last_bet_amount_from_active_node_path(active), 0)
        if derived > 0:
            features["facing_bet"] = derived
            changed = True

    expected_pot_odds = _pot_odds(features)
    if abs(_safe_float(features.get("pot_odds"), -1.0) - expected_pot_odds) > 1e-9:
        features["pot_odds"] = expected_pot_odds
        changed = True

    expected_spr = _spr_under_pressure(features)
    if abs(_safe_float(features.get("spr_under_pressure"), -1.0) - expected_spr) > 1e-9:
        features["spr_under_pressure"] = expected_spr
        changed = True

    if not changed:
        current_contract = row.get("feature_contract") if isinstance(row.get("feature_contract"), dict) else {}
        source_contract = source_row.get("feature_contract") if isinstance(source_row.get("feature_contract"), dict) else {}
        expected = feature_contract_metadata(source=source, features=features, input_dim=FEATURE_DEFAULT_INPUT_DIM)
        if current_contract == expected and source_contract == expected:
            return row, False

    source_row["features"] = features
    refreshed_contract = feature_contract_metadata(source=source, features=features, input_dim=FEATURE_DEFAULT_INPUT_DIM)
    source_row["feature_contract"] = refreshed_contract
    row["source_row"] = source_row
    row["feature_contract"] = refreshed_contract
    return row, True


def main() -> int:
    parser = argparse.ArgumentParser(description="Repair frozen reference label facing_bet values from active_node_path.")
    parser.add_argument(
        "--input-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"),
        help="Frozen reference labels JSONL to repair.",
    )
    parser.add_argument(
        "--output-jsonl",
        type=Path,
        default=None,
        help="Optional output JSONL. Defaults to in-place rewrite via temp file.",
    )
    args = parser.parse_args()

    input_path = args.input_jsonl.resolve()
    if not input_path.exists():
        print(json.dumps({"ok": False, "error": f"missing_input:{input_path}"}))
        return 2

    output_path = args.output_jsonl.resolve() if args.output_jsonl else input_path
    temp_path = output_path.with_suffix(output_path.suffix + ".tmp")

    total_rows = 0
    repaired_rows = 0

    with input_path.open("r", encoding="utf-8") as src, temp_path.open("w", encoding="utf-8", newline="\n") as dst:
        for line in src:
            stripped = line.strip()
            if not stripped:
                continue
            row = json.loads(stripped)
            total_rows += 1
            row, changed = _repair_row(row)
            if changed:
                repaired_rows += 1
            dst.write(json.dumps(row, separators=(",", ":")) + "\n")

    temp_path.replace(output_path)

    print(
        json.dumps(
            {
                "generated_at_utc": datetime.now(timezone.utc).isoformat(),
                "input_jsonl": str(input_path),
                "output_jsonl": str(output_path),
                "rows_total": total_rows,
                "rows_repaired": repaired_rows,
                "ok": True,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
