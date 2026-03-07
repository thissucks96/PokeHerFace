#!/usr/bin/env python3
"""Write deterministic train/holdout splits from frozen reference labels."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _load_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.exists():
        return rows
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                rows.append(item)
    return rows


def _row_split_token(row: dict[str, Any], split_key_field: str) -> str:
    token = str(row.get(split_key_field) or row.get("split_key") or row.get("row_id") or "").strip()
    if token:
        return token
    return hashlib.sha256(json.dumps(row, sort_keys=True).encode("utf-8")).hexdigest()


def _split_rows(rows: list[dict[str, Any]], train_split: float, seed: int, split_key_field: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    ratio = max(0.0, min(1.0, float(train_split)))
    train_rows: list[dict[str, Any]] = []
    holdout_rows: list[dict[str, Any]] = []
    for row in rows:
        token = _row_split_token(row, split_key_field=split_key_field)
        digest = hashlib.sha256(f"split|{seed}|{token}".encode("utf-8")).hexdigest()
        bucket = int(digest[:8], 16) / float(0xFFFFFFFF)
        if bucket < ratio:
            train_rows.append(row)
        else:
            holdout_rows.append(row)

    if len(rows) >= 2:
        if not train_rows and holdout_rows:
            train_rows.append(holdout_rows.pop(0))
        if not holdout_rows and train_rows:
            holdout_rows.append(train_rows.pop(-1))
    return train_rows, holdout_rows


def _write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Split frozen reference labels into deterministic train/holdout JSONL files.")
    parser.add_argument(
        "--input-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"),
        help="Frozen reference labels JSONL.",
    )
    parser.add_argument(
        "--train-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.train.jsonl"),
        help="Train split output JSONL.",
    )
    parser.add_argument(
        "--holdout-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.holdout.jsonl"),
        help="Holdout split output JSONL.",
    )
    parser.add_argument(
        "--report-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/solver_reference_labels_split_report.json"),
        help="Split report output JSON.",
    )
    parser.add_argument("--train-split", type=float, default=0.9, help="Train ratio in [0,1].")
    parser.add_argument("--seed", type=int, default=4090, help="Deterministic split seed.")
    parser.add_argument("--split-key-field", default="split_key", help="Preferred split-key field.")
    args = parser.parse_args()

    input_path = args.input_jsonl.resolve()
    train_path = args.train_jsonl.resolve()
    holdout_path = args.holdout_jsonl.resolve()
    report_path = args.report_json.resolve()

    rows = _load_rows(input_path)
    if not rows:
        print(json.dumps({"ok": False, "error": f"empty_or_missing_input:{input_path}"}))
        return 2

    train_rows, holdout_rows = _split_rows(
        rows=rows,
        train_split=args.train_split,
        seed=int(args.seed),
        split_key_field=str(args.split_key_field or "split_key"),
    )

    _write_jsonl(train_path, train_rows)
    _write_jsonl(holdout_path, holdout_rows)

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "input_jsonl": str(input_path),
        "train_jsonl": str(train_path),
        "holdout_jsonl": str(holdout_path),
        "rows_total": len(rows),
        "train_rows": len(train_rows),
        "holdout_rows": len(holdout_rows),
        "train_split": float(args.train_split),
        "seed": int(args.seed),
        "split_key_field": str(args.split_key_field or "split_key"),
        "ok": True,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
