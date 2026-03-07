#!/usr/bin/env python3
"""Validate train vs holdout air-gap for neural data artifacts.

Checks:
- row_id overlap
- feature_key_hash overlap (cryptographic feature identity), when available
"""

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

from shared_feature_contract import feature_key_hash


def _row_feature_hash(row: dict[str, Any]) -> str:
    contract = row.get("feature_contract") if isinstance(row.get("feature_contract"), dict) else {}
    existing = str(contract.get("feature_key_hash") or "").strip()
    if existing:
        return existing
    source = row.get("source") if isinstance(row.get("source"), dict) else {}
    features = row.get("features") if isinstance(row.get("features"), dict) else {}
    if not source or not features:
        source_row = row.get("source_row") if isinstance(row.get("source_row"), dict) else {}
        if isinstance(source_row.get("source"), dict):
            source = source_row.get("source") or {}
        if isinstance(source_row.get("features"), dict):
            features = source_row.get("features") or {}
    if source and features:
        try:
            return str(feature_key_hash(source=source, features=features)).strip()
        except Exception:
            return ""
    return ""


def _load_unresolved_gate_ids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    if not isinstance(payload, dict):
        return set()
    out: set[str] = set()
    items = payload.get("unresolved_gate_ids")
    if isinstance(items, list):
        for item in items:
            token = str(item or "").strip()
            if token:
                out.add(token)
    return out


def _load_ids(path: Path) -> tuple[set[str], set[str], int, int]:
    row_ids: set[str] = set()
    feature_hashes: set[str] = set()
    rows = 0
    missing_feature_hash = 0
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            rows += 1
            row_id = str(row.get("row_id") or "").strip()
            if row_id:
                row_ids.add(row_id)
            fhash = _row_feature_hash(row)
            if fhash:
                feature_hashes.add(fhash)
            else:
                missing_feature_hash += 1
    return row_ids, feature_hashes, rows, missing_feature_hash


def main() -> int:
    parser = argparse.ArgumentParser(description="Check train-vs-holdout air-gap.")
    parser.add_argument("--train-jsonl", type=Path, required=True, help="Train JSONL path.")
    parser.add_argument("--holdout-jsonl", type=Path, required=True, help="Holdout JSONL path.")
    parser.add_argument(
        "--out-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/neural_airgap_report.json"),
        help="Output report JSON.",
    )
    parser.add_argument(
        "--unresolved-gate-json",
        type=Path,
        default=None,
        help="Optional unresolved gate export JSON to ensure holdout rows are not inside the accepted OOD gate set.",
    )
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on overlap.")
    args = parser.parse_args()

    train_path = args.train_jsonl.resolve()
    holdout_path = args.holdout_jsonl.resolve()
    if not train_path.exists():
        print(json.dumps({"ok": False, "error": f"missing_train_jsonl:{train_path}"}))
        return 2
    if not holdout_path.exists():
        print(json.dumps({"ok": False, "error": f"missing_holdout_jsonl:{holdout_path}"}))
        return 2

    train_ids, train_hashes, train_rows, train_missing_hash = _load_ids(train_path)
    holdout_ids, holdout_hashes, holdout_rows, holdout_missing_hash = _load_ids(holdout_path)

    overlap_row_ids = sorted(train_ids & holdout_ids)
    overlap_feature_hashes = sorted(train_hashes & holdout_hashes)
    unresolved_gate_ids = _load_unresolved_gate_ids(args.unresolved_gate_json.resolve()) if args.unresolved_gate_json else set()
    holdout_unresolved_overlap = sorted(holdout_ids & unresolved_gate_ids)

    ok = (
        (len(overlap_row_ids) == 0)
        and (len(overlap_feature_hashes) == 0)
        and (len(holdout_unresolved_overlap) == 0)
    )
    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "train_jsonl": str(train_path),
        "holdout_jsonl": str(holdout_path),
        "unresolved_gate_json": str(args.unresolved_gate_json.resolve()) if args.unresolved_gate_json else None,
        "counts": {
            "train_rows": train_rows,
            "holdout_rows": holdout_rows,
            "train_unique_row_ids": len(train_ids),
            "holdout_unique_row_ids": len(holdout_ids),
            "train_feature_hashes": len(train_hashes),
            "holdout_feature_hashes": len(holdout_hashes),
            "train_missing_feature_hash_rows": train_missing_hash,
            "holdout_missing_feature_hash_rows": holdout_missing_hash,
            "unresolved_gate_ids": len(unresolved_gate_ids),
        },
        "overlap": {
            "row_id_count": len(overlap_row_ids),
            "feature_hash_count": len(overlap_feature_hashes),
            "holdout_unresolved_gate_count": len(holdout_unresolved_overlap),
            "sample_row_ids": overlap_row_ids[:20],
            "sample_feature_hashes": overlap_feature_hashes[:20],
            "sample_holdout_unresolved_row_ids": holdout_unresolved_overlap[:20],
        },
        "ok": ok,
    }

    out_path = args.out_json.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))

    if args.strict and not ok:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
