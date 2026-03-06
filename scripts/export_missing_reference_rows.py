#!/usr/bin/env python3
"""Export missing offline-reference rows by bucket for targeted relabeling."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.report_reference_label_postpass import _bucket_id  # type: ignore


def _load_row_ids(path: Path) -> set[str]:
    row_ids: set[str] = set()
    if not path.exists():
        return row_ids
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(payload, dict):
                continue
            row_id = str(payload.get("row_id") or "").strip()
            if row_id:
                row_ids.add(row_id)
    return row_ids


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")


def _write_ids(path: Path, row_ids: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for row_id in row_ids:
            f.write(f"{row_id}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Export missing offline-reference rows by bucket.")
    parser.add_argument(
        "--input-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl"),
        help="Teacher/source corpus JSONL.",
    )
    parser.add_argument(
        "--labels-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"),
        help="Completed label JSONL.",
    )
    parser.add_argument(
        "--errors-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/offline_label_errors.jsonl"),
        help="Explicit failure JSONL.",
    )
    parser.add_argument(
        "--output-jsonl",
        type=Path,
        required=True,
        help="Filtered missing rows JSONL output path.",
    )
    parser.add_argument(
        "--output-ids",
        type=Path,
        required=True,
        help="Filtered missing row_id list output path.",
    )
    parser.add_argument(
        "--summary-json",
        type=Path,
        default=None,
        help="Optional summary JSON path.",
    )
    parser.add_argument(
        "--include-bucket",
        action="append",
        default=[],
        help="Bucket id to include. Repeatable. If omitted, includes all buckets.",
    )
    parser.add_argument(
        "--exclude-bucket",
        action="append",
        default=[],
        help="Bucket id to exclude. Repeatable.",
    )
    args = parser.parse_args()

    input_jsonl = args.input_jsonl.resolve()
    labels_jsonl = args.labels_jsonl.resolve()
    errors_jsonl = args.errors_jsonl.resolve()
    output_jsonl = args.output_jsonl.resolve()
    output_ids = args.output_ids.resolve()
    summary_json = args.summary_json.resolve() if args.summary_json else None

    if not input_jsonl.exists():
        raise SystemExit(f"input dataset not found: {input_jsonl}")

    success_ids = _load_row_ids(labels_jsonl)
    error_ids = _load_row_ids(errors_jsonl)
    done_ids = success_ids | error_ids

    include_buckets = {str(v).strip() for v in args.include_bucket if str(v).strip()}
    exclude_buckets = {str(v).strip() for v in args.exclude_bucket if str(v).strip()}

    selected_rows: list[dict] = []
    selected_ids: list[str] = []
    bucket_counter: Counter[str] = Counter()
    total_missing = 0

    with input_jsonl.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                continue
            row_id = str(row.get("row_id") or "").strip()
            if not row_id or row_id in done_ids:
                continue
            total_missing += 1
            bucket = _bucket_id(row)
            if include_buckets and bucket not in include_buckets:
                continue
            if bucket in exclude_buckets:
                continue
            selected_rows.append(row)
            selected_ids.append(row_id)
            bucket_counter[bucket] += 1

    _write_jsonl(output_jsonl, selected_rows)
    _write_ids(output_ids, selected_ids)

    summary = {
        "input_jsonl": str(input_jsonl),
        "labels_jsonl": str(labels_jsonl),
        "errors_jsonl": str(errors_jsonl),
        "total_missing_rows": total_missing,
        "selected_missing_rows": len(selected_rows),
        "include_buckets": sorted(include_buckets),
        "exclude_buckets": sorted(exclude_buckets),
        "bucket_counts": dict(sorted(bucket_counter.items(), key=lambda kv: kv[1], reverse=True)),
        "output_jsonl": str(output_jsonl),
        "output_ids": str(output_ids),
    }

    if summary_json is not None:
        summary_json.parent.mkdir(parents=True, exist_ok=True)
        summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
