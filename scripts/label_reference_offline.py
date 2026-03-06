#!/usr/bin/env python3
"""Offline reference labeler with manifest checkpoint/resume for local bridge /solve."""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests
from requests import RequestException

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from shared_feature_contract import FEATURE_DEFAULT_INPUT_DIM, feature_contract_metadata

try:
    import psutil  # type: ignore
except Exception:  # pragma: no cover
    psutil = None


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _load_jsonl_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                rows.append(obj)
    return rows


def _row_id_for_index(row: dict[str, Any], index: int) -> str:
    row_id = str(row.get("row_id") or "").strip()
    return row_id if row_id else f"row_{index}"


def _load_row_ids(path: Path) -> set[str]:
    done: set[str] = set()
    if not path.exists():
        return done
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                row_id = str(obj.get("row_id") or "").strip()
                if row_id:
                    done.add(row_id)
    return done


def _reconcile_resume_state(
    rows: list[dict[str, Any]],
    output_jsonl: Path,
    error_jsonl: Path,
) -> dict[str, Any]:
    valid_row_ids = {_row_id_for_index(row, index) for index, row in enumerate(rows)}
    success_ids_all = _load_row_ids(output_jsonl)
    error_ids_all = _load_row_ids(error_jsonl)
    success_ids = success_ids_all & valid_row_ids
    error_ids = error_ids_all & valid_row_ids
    done_row_ids = success_ids | error_ids
    overlap_row_ids = success_ids & error_ids

    first_missing_index = len(rows)
    first_missing_row_id = ""
    for index, row in enumerate(rows):
        row_id = _row_id_for_index(row, index)
        if row_id not in done_row_ids:
            first_missing_index = index
            first_missing_row_id = row_id
            break

    return {
        "success_ids": success_ids,
        "error_ids": error_ids,
        "done_row_ids": done_row_ids,
        "overlap_row_ids": overlap_row_ids,
        "first_missing_index": int(first_missing_index),
        "first_missing_row_id": first_missing_row_id,
        "ignored_success_ids": len(success_ids_all - valid_row_ids),
        "ignored_error_ids": len(error_ids_all - valid_row_ids),
    }


def _load_manifest(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    tmp.replace(path)


def _build_spot_from_row(row: dict[str, Any], iterations_override: int, threads_override: int) -> dict[str, Any]:
    features = row.get("features") if isinstance(row.get("features"), dict) else {}
    bet_sizing = features.get("bet_sizing") if isinstance(features.get("bet_sizing"), dict) else {}

    spot = {
        "hero_range": str(features.get("hero_range") or ""),
        "villain_range": str(features.get("villain_range") or ""),
        "board": features.get("board") if isinstance(features.get("board"), list) else [],
        "in_position_player": _safe_int(features.get("in_position_player"), 2),
        "starting_stack": _safe_int(features.get("starting_stack"), 100),
        "starting_pot": _safe_int(features.get("starting_pot"), 6),
        "minimum_bet": _safe_int(features.get("minimum_bet"), 2),
        "all_in_threshold": _safe_float(features.get("all_in_threshold"), 0.67),
        "iterations": _safe_int(features.get("iterations"), 100),
        "min_exploitability": _safe_float(features.get("min_exploitability"), -1.0),
        "thread_count": _safe_int(features.get("thread_count"), 4),
        "remove_donk_bets": bool(features.get("remove_donk_bets", True)),
        "raise_cap": _safe_int(features.get("raise_cap"), 3),
        "compress_strategy": bool(features.get("compress_strategy", True)),
        "bet_sizing": bet_sizing,
        "active_node_path": str(features.get("active_node_path") or ""),
    }

    if iterations_override > 0:
        spot["iterations"] = int(iterations_override)
    if threads_override > 0:
        spot["thread_count"] = int(threads_override)
    return spot


def _memory_snapshot_mb() -> float | None:
    if psutil is None:
        return None
    try:
        proc = psutil.Process()
        return float(proc.memory_info().rss) / (1024.0 * 1024.0)
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline reference labeling with checkpoint/resume.")
    parser.add_argument(
        "--input-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl"),
        help="Teacher dataset rows to label.",
    )
    parser.add_argument(
        "--output-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"),
        help="Output JSONL with reference labels.",
    )
    parser.add_argument(
        "--error-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/offline_label_errors.jsonl"),
        help="Error JSONL path for failed rows.",
    )
    parser.add_argument(
        "--manifest-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/offline_label_manifest.json"),
        help="Checkpoint/resume manifest path.",
    )
    parser.add_argument("--endpoint", type=str, default="http://127.0.0.1:8000/solve")
    parser.add_argument("--runtime-profile", type=str, default="shark_classic")
    parser.add_argument("--timeout-sec", type=int, default=180)
    parser.add_argument("--max-rows", type=int, default=0, help="0 means all rows.")
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--max-retries", type=int, default=2)
    parser.add_argument("--retry-delay-sec", type=float, default=2.0)
    parser.add_argument("--request-delay-sec", type=float, default=0.0)
    parser.add_argument("--checkpoint-every", type=int, default=25)
    parser.add_argument("--max-consecutive-failures", type=int, default=30)
    parser.add_argument("--cooldown-every", type=int, default=250)
    parser.add_argument("--cooldown-sec", type=float, default=5.0)
    parser.add_argument("--max-rss-mb", type=float, default=0.0, help="0 disables RSS guard.")
    parser.add_argument("--iterations-override", type=int, default=0)
    parser.add_argument("--thread-count-override", type=int, default=0)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    input_jsonl = args.input_jsonl.resolve()
    output_jsonl = args.output_jsonl.resolve()
    error_jsonl = args.error_jsonl.resolve()
    manifest_json = args.manifest_json.resolve()

    if not input_jsonl.exists():
        raise SystemExit(f"input dataset not found: {input_jsonl}")

    rows = _load_jsonl_rows(input_jsonl)
    total_input_rows = len(rows)
    if total_input_rows == 0:
        raise SystemExit("input dataset has zero rows")

    done_row_ids: set[str] = set()
    success_row_ids: set[str] = set()
    error_row_ids: set[str] = set()
    overlap_row_ids: set[str] = set()
    resume_state: dict[str, Any] | None = None
    manifest = _load_manifest(manifest_json) if args.resume else None
    if args.resume:
        resume_state = _reconcile_resume_state(
            rows=rows,
            output_jsonl=output_jsonl,
            error_jsonl=error_jsonl,
        )
        success_row_ids = set(resume_state["success_ids"])
        error_row_ids = set(resume_state["error_ids"])
        overlap_row_ids = set(resume_state["overlap_row_ids"])
        done_row_ids = set(resume_state["done_row_ids"])

    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    error_jsonl.parent.mkdir(parents=True, exist_ok=True)

    mode = "a" if args.resume else "w"
    out_f = output_jsonl.open(mode, encoding="utf-8")
    err_f = error_jsonl.open(mode, encoding="utf-8")

    started_at = _utc_now()
    stats = {
        "total_input_rows": total_input_rows,
        "attempted": 0,
        "succeeded": 0,
        "failed": 0,
        "skipped_existing": 0,
        "processed_rows": 0,
        "consecutive_failures": 0,
        "next_index": int(max(0, args.start_index)),
        "stopped_reason": "",
    }

    resume_meta = {
        "enabled": bool(args.resume),
        "source_of_truth": "outputs_jsonl" if args.resume else "runtime_only",
        "manifest_present": manifest is not None,
        "ignored_manifest_cursor": None,
        "ignored_manifest_stats": {},
        "reconciled": {},
    }

    if args.resume and resume_state is not None:
        prior = manifest.get("stats") if isinstance((manifest or {}).get("stats"), dict) else {}
        reconciled_cursor = int(resume_state["first_missing_index"])
        stats["attempted"] = len(success_row_ids) + len(error_row_ids)
        stats["succeeded"] = len(success_row_ids)
        stats["failed"] = len(error_row_ids)
        stats["skipped_existing"] = min(reconciled_cursor, len(done_row_ids))
        stats["processed_rows"] = min(reconciled_cursor, total_input_rows)
        stats["next_index"] = reconciled_cursor
        resume_meta["ignored_manifest_cursor"] = prior.get("next_index")
        resume_meta["ignored_manifest_stats"] = prior
        resume_meta["reconciled"] = {
            "labels_unique": len(success_row_ids),
            "errors_unique": len(error_row_ids),
            "done_unique": len(done_row_ids),
            "overlap_unique": len(overlap_row_ids),
            "first_missing_index": reconciled_cursor,
            "first_missing_row_id": str(resume_state["first_missing_row_id"] or ""),
            "ignored_success_ids_not_in_input": int(resume_state["ignored_success_ids"]),
            "ignored_error_ids_not_in_input": int(resume_state["ignored_error_ids"]),
        }

    cursor = int(stats["next_index"])
    max_rows = max(0, int(args.max_rows))
    checkpoint_every = max(1, int(args.checkpoint_every))
    cooldown_every = max(0, int(args.cooldown_every))

    failure_samples: list[dict[str, Any]] = []

    try:
        while cursor < total_input_rows:
            if max_rows > 0 and int(stats["processed_rows"]) >= max_rows:
                stats["stopped_reason"] = "max_rows_reached"
                break

            row = rows[cursor]
            row_id = str(row.get("row_id") or "").strip()
            if not row_id:
                row_id = f"row_{cursor}"

            if row_id in done_row_ids:
                stats["skipped_existing"] += 1
                stats["processed_rows"] += 1
                cursor += 1
                stats["next_index"] = cursor
                continue

            if args.dry_run:
                stats["processed_rows"] += 1
                cursor += 1
                stats["next_index"] = cursor
                continue

            if args.max_rss_mb > 0:
                rss = _memory_snapshot_mb()
                if rss is not None and rss >= float(args.max_rss_mb):
                    stats["stopped_reason"] = f"rss_guard_hit:{rss:.2f}mb"
                    break

            spot = _build_spot_from_row(
                row=row,
                iterations_override=int(args.iterations_override),
                threads_override=int(args.thread_count_override),
            )

            payload = {
                "spot": spot,
                "timeout_sec": int(args.timeout_sec),
                "quiet": True,
                "auto_select_best": True,
                "ev_keep_margin": 0.001,
                "enable_multi_node_locks": False,
                "runtime_profile": str(args.runtime_profile),
            }

            stats["attempted"] += 1
            ok = False
            error_text = ""
            http_status = None
            response_json: dict[str, Any] | None = None

            for attempt in range(0, max(0, int(args.max_retries)) + 1):
                try:
                    resp = requests.post(args.endpoint, json=payload, timeout=float(args.timeout_sec) + 10.0)
                    http_status = int(resp.status_code)
                    resp.raise_for_status()
                    body = resp.json()
                    if not isinstance(body, dict):
                        raise ValueError("non-dict response json")
                    if str(body.get("status") or "").lower() != "ok":
                        raise ValueError(f"response status not ok: {body.get('status')}")
                    response_json = body
                    ok = True
                    break
                except Exception as exc:
                    error_text = str(exc)
                    if isinstance(exc, RequestException) and exc.response is not None:
                        http_status = int(exc.response.status_code)
                        try:
                            error_text = f"{error_text} | body={exc.response.text}"
                        except Exception:
                            pass
                    if attempt < int(args.max_retries):
                        time.sleep(max(0.0, float(args.retry_delay_sec)))

            if ok and response_json is not None:
                result_block = response_json.get("result") if isinstance(response_json.get("result"), dict) else {}
                out_row = {
                    "row_id": row_id,
                    "split_key": str(row.get("split_key") or ""),
                    "labeled_at_utc": _utc_now(),
                    "runtime_profile": str(args.runtime_profile),
                    "feature_contract": (
                        row.get("feature_contract")
                        if isinstance(row.get("feature_contract"), dict)
                        else feature_contract_metadata(
                            source=(row.get("source") if isinstance(row.get("source"), dict) else {}),
                            features=(row.get("features") if isinstance(row.get("features"), dict) else {}),
                            input_dim=FEATURE_DEFAULT_INPUT_DIM,
                        )
                    ),
                    "source_row": {
                        "source": row.get("source"),
                        "features": row.get("features"),
                        "target": row.get("target"),
                        "feature_contract": row.get("feature_contract"),
                    },
                    "reference": {
                        "selected_strategy": response_json.get("selected_strategy"),
                        "selection_reason": response_json.get("selection_reason"),
                        "decision": result_block.get("decision"),
                        "active_node_found": bool(result_block.get("active_node_found", False)),
                        "active_node_actions": result_block.get("active_node_actions"),
                        "root_actions": result_block.get("root_actions"),
                        "metrics": response_json.get("metrics"),
                    },
                }
                out_f.write(json.dumps(out_row) + "\n")
                out_f.flush()
                done_row_ids.add(row_id)
                success_row_ids.add(row_id)
                stats["succeeded"] += 1
                stats["consecutive_failures"] = 0
            else:
                failure = {
                    "row_id": row_id,
                    "index": cursor,
                    "failed_at_utc": _utc_now(),
                    "http_status": http_status,
                    "error": error_text,
                }
                err_f.write(json.dumps(failure) + "\n")
                err_f.flush()
                done_row_ids.add(row_id)
                error_row_ids.add(row_id)
                stats["failed"] += 1
                stats["consecutive_failures"] += 1
                if len(failure_samples) < 200:
                    failure_samples.append(failure)
                if int(stats["consecutive_failures"]) >= int(args.max_consecutive_failures):
                    stats["stopped_reason"] = "max_consecutive_failures"
                    cursor += 1
                    stats["processed_rows"] += 1
                    stats["next_index"] = cursor
                    break

            stats["processed_rows"] += 1
            cursor += 1
            stats["next_index"] = cursor

            if cooldown_every > 0 and int(stats["processed_rows"]) % cooldown_every == 0:
                time.sleep(max(0.0, float(args.cooldown_sec)))

            if float(args.request_delay_sec) > 0.0:
                time.sleep(float(args.request_delay_sec))

            if int(stats["processed_rows"]) % checkpoint_every == 0:
                manifest_payload = {
                    "schema_version": 1,
                    "generated_at_utc": _utc_now(),
                    "started_at_utc": started_at,
                    "input_jsonl": str(input_jsonl),
                    "output_jsonl": str(output_jsonl),
                    "error_jsonl": str(error_jsonl),
                    "endpoint": str(args.endpoint),
                    "runtime_profile": str(args.runtime_profile),
                    "timeout_sec": int(args.timeout_sec),
                    "stats": stats,
                    "resume_reconciliation": resume_meta,
                    "failure_samples": failure_samples,
                }
                _write_manifest(manifest_json, manifest_payload)

        if not stats["stopped_reason"]:
            stats["stopped_reason"] = "completed" if cursor >= total_input_rows else "stopped"

        manifest_payload = {
            "schema_version": 1,
            "generated_at_utc": _utc_now(),
            "started_at_utc": started_at,
            "input_jsonl": str(input_jsonl),
            "output_jsonl": str(output_jsonl),
            "error_jsonl": str(error_jsonl),
            "endpoint": str(args.endpoint),
            "runtime_profile": str(args.runtime_profile),
            "timeout_sec": int(args.timeout_sec),
            "stats": stats,
            "resume_reconciliation": resume_meta,
            "failure_samples": failure_samples,
        }
        _write_manifest(manifest_json, manifest_payload)
        print(json.dumps(manifest_payload, indent=2))

        return 0 if str(stats["stopped_reason"]).startswith("completed") or args.dry_run else 0
    finally:
        out_f.close()
        err_f.close()


if __name__ == "__main__":
    raise SystemExit(main())
