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


def _repair_row(row: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    source_row = row.get("source_row") if isinstance(row.get("source_row"), dict) else None
    if not source_row:
        return row, False
    features = source_row.get("features") if isinstance(source_row.get("features"), dict) else None
    source = source_row.get("source") if isinstance(source_row.get("source"), dict) else {}
    if not features:
        return row, False

    current_facing = _safe_int(features.get("facing_bet"), 0)
    if current_facing > 0:
        return row, False

    active = str(features.get("active_node_path") or "").strip()
    derived = _safe_int(_extract_last_bet_amount_from_active_node_path(active), 0)
    if derived <= 0:
        return row, False

    features["facing_bet"] = derived
    source_row["features"] = features
    source_row["feature_contract"] = feature_contract_metadata(
        source=source,
        features=features,
        input_dim=FEATURE_DEFAULT_INPUT_DIM,
    )
    row["source_row"] = source_row
    row["feature_contract"] = feature_contract_metadata(
        source=source,
        features=features,
        input_dim=FEATURE_DEFAULT_INPUT_DIM,
    )
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
