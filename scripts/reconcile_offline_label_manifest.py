#!/usr/bin/env python3
"""Rebuild offline label manifest stats from the output JSONL source of truth."""

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

from scripts.label_reference_offline import (  # type: ignore
    _load_jsonl_rows,
    _load_manifest,
    _reconcile_resume_state,
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_failure_samples(error_jsonl: Path, limit: int) -> list[dict[str, Any]]:
    if limit <= 0 or not error_jsonl.exists():
        return []
    samples = _load_jsonl_rows(error_jsonl)
    if len(samples) <= limit:
        return samples
    return samples[-limit:]


def _write_manifest(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Reconcile offline label manifest from output JSONL truth.")
    parser.add_argument(
        "--input-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl"),
    )
    parser.add_argument(
        "--output-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"),
    )
    parser.add_argument(
        "--error-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/offline_label_errors.jsonl"),
    )
    parser.add_argument(
        "--manifest-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/offline_label_manifest.json"),
    )
    parser.add_argument("--failure-sample-limit", type=int, default=200)
    args = parser.parse_args()

    input_jsonl = args.input_jsonl.resolve()
    output_jsonl = args.output_jsonl.resolve()
    error_jsonl = args.error_jsonl.resolve()
    manifest_json = args.manifest_json.resolve()

    if not input_jsonl.exists():
        raise SystemExit(f"input dataset not found: {input_jsonl}")

    rows = _load_jsonl_rows(input_jsonl)
    prior_manifest = _load_manifest(manifest_json) or {}
    prior_stats = prior_manifest.get("stats") if isinstance(prior_manifest.get("stats"), dict) else {}

    resume_state = _reconcile_resume_state(
        rows=rows,
        output_jsonl=output_jsonl,
        error_jsonl=error_jsonl,
    )

    success_ids = set(resume_state["success_ids"])
    error_ids = set(resume_state["error_ids"])
    done_row_ids = set(resume_state["done_row_ids"])
    overlap_row_ids = set(resume_state["overlap_row_ids"])
    first_missing_index = int(resume_state["first_missing_index"])

    stats = {
        "total_input_rows": len(rows),
        "attempted": len(success_ids) + len(error_ids),
        "succeeded": len(success_ids),
        "failed": len(error_ids),
        "skipped_existing": min(first_missing_index, len(done_row_ids)),
        "processed_rows": min(first_missing_index, len(rows)),
        "consecutive_failures": 0,
        "next_index": first_missing_index,
        "stopped_reason": str(prior_stats.get("stopped_reason") or "reconciled_from_outputs"),
    }

    payload = {
        "schema_version": int(prior_manifest.get("schema_version", 1) or 1),
        "generated_at_utc": _utc_now(),
        "started_at_utc": str(prior_manifest.get("started_at_utc") or ""),
        "input_jsonl": str(prior_manifest.get("input_jsonl") or input_jsonl),
        "output_jsonl": str(prior_manifest.get("output_jsonl") or output_jsonl),
        "error_jsonl": str(prior_manifest.get("error_jsonl") or error_jsonl),
        "endpoint": str(prior_manifest.get("endpoint") or "http://127.0.0.1:8000/solve"),
        "runtime_profile": str(prior_manifest.get("runtime_profile") or "shark_classic"),
        "timeout_sec": int(prior_manifest.get("timeout_sec", 0) or 0),
        "stats": stats,
        "resume_reconciliation": {
            "enabled": True,
            "source_of_truth": "outputs_jsonl",
            "manifest_present": bool(prior_manifest),
            "ignored_manifest_cursor": prior_stats.get("next_index"),
            "ignored_manifest_stats": prior_stats,
            "reconciled": {
                "labels_unique": len(success_ids),
                "errors_unique": len(error_ids),
                "done_unique": len(done_row_ids),
                "overlap_unique": len(overlap_row_ids),
                "first_missing_index": first_missing_index,
                "first_missing_row_id": str(resume_state["first_missing_row_id"] or ""),
                "ignored_success_ids_not_in_input": int(resume_state["ignored_success_ids"]),
                "ignored_error_ids_not_in_input": int(resume_state["ignored_error_ids"]),
            },
        },
        "failure_samples": _load_failure_samples(error_jsonl, max(0, int(args.failure_sample_limit))),
    }

    _write_manifest(manifest_json, payload)
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
