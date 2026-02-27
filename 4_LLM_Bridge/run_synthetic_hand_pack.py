#!/usr/bin/env python
"""Run synthetic hand decision packs through /solve and emit timing bottleneck reports."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from requests import RequestException


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACK = ROOT / "4_LLM_Bridge" / "examples" / "synthetic_hands" / "ten_hand_progression.json"


def _load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _float_or_none(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _percentile(values: List[float], p: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = max(0.0, min(1.0, p)) * (len(ordered) - 1)
    lo = int(rank)
    hi = min(lo + 1, len(ordered) - 1)
    frac = rank - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def _build_request_payload(
    *,
    engine_spot: Dict[str, Any],
    preset: str,
    solver_timeout: int,
    runtime_profile: Optional[str],
    enable_multi_node_locks: bool,
    ev_keep_margin: float,
) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "spot": engine_spot,
        "timeout_sec": solver_timeout,
        "quiet": True,
        "auto_select_best": True,
        "ev_keep_margin": ev_keep_margin,
        "llm": {"preset": preset},
        "enable_multi_node_locks": enable_multi_node_locks,
    }
    if runtime_profile:
        payload["runtime_profile"] = runtime_profile
    return payload


def _safe_div(numerator: float, denominator: float) -> Optional[float]:
    if denominator <= 0:
        return None
    return numerator / denominator


def _summarize_stage_distribution(rows: List[Dict[str, Any]], key: str) -> Dict[str, Optional[float]]:
    vals: List[float] = []
    for row in rows:
        val = row.get(key)
        if isinstance(val, (int, float)):
            vals.append(float(val))
    if not vals:
        return {
            "avg_sec": None,
            "p50_sec": None,
            "p95_sec": None,
            "max_sec": None,
            "total_sec": 0.0,
        }
    return {
        "avg_sec": statistics.mean(vals),
        "p50_sec": _percentile(vals, 0.50),
        "p95_sec": _percentile(vals, 0.95),
        "max_sec": max(vals),
        "total_sec": sum(vals),
    }


def _hand_summary(hand_rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    total = len(hand_rows)
    success = sum(1 for r in hand_rows if r.get("http_ok") and r.get("status_ok"))
    failures = total - success
    wall_vals = [float(r["request_wall_time_sec"]) for r in hand_rows if isinstance(r.get("request_wall_time_sec"), (int, float))]
    return {
        "decision_points": total,
        "success_count": success,
        "failure_count": failures,
        "success_rate": _safe_div(float(success), float(total)),
        "wall_time_total_sec": sum(wall_vals),
        "wall_time_avg_sec": statistics.mean(wall_vals) if wall_vals else None,
        "wall_time_p95_sec": _percentile(wall_vals, 0.95),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run synthetic hand pack against bridge_server /solve and emit timing report JSON.")
    parser.add_argument("--pack", default=str(DEFAULT_PACK), help="Path to synthetic hand pack JSON.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000/solve", help="Bridge /solve endpoint.")
    parser.add_argument("--preset", default="local_qwen3_coder_30b", help="LLM preset to use (default local_qwen3_coder_30b).")
    parser.add_argument("--runtime-profile", choices=["fast", "normal"], default=None, help="Optional runtime profile override.")
    parser.add_argument("--solver-timeout", type=int, default=600, help="Per-request solver timeout (sec).")
    parser.add_argument("--http-timeout", type=float, default=900.0, help="HTTP request timeout (sec).")
    parser.add_argument("--ev-keep-margin", type=float, default=0.001, help="Margin gate passed to bridge.")
    parser.add_argument("--disable-multi-node-locks", action="store_true", help="Force root-only lock generation for this run.")
    parser.add_argument("--max-points", type=int, default=0, help="Optional cap on total decision points processed (0 = all).")
    parser.add_argument("--output", required=True, help="Output path for timing report JSON.")
    args = parser.parse_args()

    pack_path = Path(args.pack).resolve()
    if not pack_path.exists():
        raise SystemExit(f"Pack not found: {pack_path}")

    payload = _load_json(pack_path)
    if not isinstance(payload, dict):
        raise SystemExit("Pack root must be an object.")

    hands = payload.get("hands")
    if not isinstance(hands, list) or not hands:
        raise SystemExit("Pack must include non-empty 'hands' array.")

    point_rows: List[Dict[str, Any]] = []
    hand_rows_by_id: Dict[str, List[Dict[str, Any]]] = {}

    started_all = time.perf_counter()
    processed = 0

    for hand_index, hand in enumerate(hands, start=1):
        if not isinstance(hand, dict):
            continue
        hand_id = str(hand.get("hand_id") or f"hand_{hand_index:02d}")
        decision_points = hand.get("decision_points")
        if not isinstance(decision_points, list):
            continue

        for point_index, point in enumerate(decision_points, start=1):
            if args.max_points > 0 and processed >= args.max_points:
                break
            if not isinstance(point, dict):
                continue

            street = str(point.get("street") or "unknown")
            engine_spot = point.get("engine_spot")
            if not isinstance(engine_spot, dict):
                row = {
                    "hand_id": hand_id,
                    "hand_index": hand_index,
                    "point_index": point_index,
                    "street": street,
                    "http_ok": False,
                    "status_ok": False,
                    "error": "missing_engine_spot",
                    "request_wall_time_sec": 0.0,
                }
                point_rows.append(row)
                hand_rows_by_id.setdefault(hand_id, []).append(row)
                processed += 1
                continue

            req_payload = _build_request_payload(
                engine_spot=engine_spot,
                preset=args.preset,
                solver_timeout=args.solver_timeout,
                runtime_profile=args.runtime_profile,
                enable_multi_node_locks=(not args.disable_multi_node_locks),
                ev_keep_margin=args.ev_keep_margin,
            )

            wall_start = time.perf_counter()
            status_code: Optional[int] = None
            resp_json: Optional[Dict[str, Any]] = None
            req_error: Optional[str] = None
            try:
                response = requests.post(args.endpoint, json=req_payload, timeout=args.http_timeout)
                status_code = response.status_code
                response.raise_for_status()
                body = response.json()
                if isinstance(body, dict):
                    resp_json = body
                else:
                    req_error = "non_object_json_response"
            except RequestException as exc:
                req_error = f"request_exception: {exc}"
            except json.JSONDecodeError as exc:
                req_error = f"json_decode_error: {exc}"
            wall_elapsed = time.perf_counter() - wall_start

            metrics = resp_json.get("metrics") if isinstance(resp_json, dict) and isinstance(resp_json.get("metrics"), dict) else {}
            llm_time = _float_or_none(metrics.get("llm_time_sec"))
            baseline_solver_time = _float_or_none(metrics.get("baseline_solver_time_sec"))
            locked_solver_time = _float_or_none(metrics.get("locked_solver_time_sec"))
            locked_solver_time_total = _float_or_none(metrics.get("locked_solver_time_total_sec"))
            bridge_total = _float_or_none(metrics.get("total_bridge_time_sec"))
            solver_selected = _float_or_none(metrics.get("solver_time_sec"))

            locked_stage = locked_solver_time_total
            if locked_stage is None:
                locked_stage = locked_solver_time

            known_sum = 0.0
            for v in (llm_time, baseline_solver_time, locked_stage):
                if isinstance(v, float):
                    known_sum += v
            bridge_overhead = None
            if isinstance(bridge_total, float):
                bridge_overhead = max(0.0, bridge_total - known_sum)

            row = {
                "hand_id": hand_id,
                "hand_index": hand_index,
                "point_index": point_index,
                "street": street,
                "hero_to_act": bool(point.get("hero_to_act", False)),
                "players_in_hand": point.get("players_in_hand"),
                "last_action": point.get("last_action"),
                "http_ok": req_error is None,
                "status_ok": bool(isinstance(resp_json, dict) and resp_json.get("status") == "ok"),
                "status_code": status_code,
                "error": req_error,
                "selected_strategy": resp_json.get("selected_strategy") if isinstance(resp_json, dict) else None,
                "selection_reason": resp_json.get("selection_reason") if isinstance(resp_json, dict) else None,
                "node_lock_kept": resp_json.get("node_lock_kept") if isinstance(resp_json, dict) else None,
                "llm_error": metrics.get("llm_error") if isinstance(metrics, dict) else None,
                "request_wall_time_sec": wall_elapsed,
                "bridge_total_time_sec": bridge_total,
                "llm_time_sec": llm_time,
                "baseline_solver_time_sec": baseline_solver_time,
                "locked_solver_time_sec": locked_solver_time,
                "locked_solver_time_total_sec": locked_stage,
                "solver_selected_time_sec": solver_selected,
                "bridge_overhead_time_sec": bridge_overhead,
                "final_exploitability_pct": _float_or_none(metrics.get("final_exploitability_pct")),
                "baseline_exploitability_pct": _float_or_none(metrics.get("baseline_exploitability_pct")),
                "locked_exploitability_pct": _float_or_none(metrics.get("locked_exploitability_pct")),
                "exploitability_delta_pct": _float_or_none(metrics.get("exploitability_delta_pct")),
                "lock_applied": metrics.get("lock_applied") if isinstance(metrics, dict) else None,
                "lock_confidence": _float_or_none(metrics.get("lock_confidence")),
                "lock_quality_score": _float_or_none(metrics.get("lock_quality_score")),
                "runtime_profile": metrics.get("runtime_profile") if isinstance(metrics, dict) else None,
            }

            point_rows.append(row)
            hand_rows_by_id.setdefault(hand_id, []).append(row)
            processed += 1
            status_label = "ok" if (row["http_ok"] and row["status_ok"]) else "fail"
            print(
                f"[{processed}] {status_label} hand={hand_id} point={point_index} street={street} "
                f"wall={wall_elapsed:.2f}s selected={row.get('selected_strategy')} reason={row.get('selection_reason')}"
            )

        if args.max_points > 0 and processed >= args.max_points:
            break

    total_elapsed = time.perf_counter() - started_all

    success_rows = [r for r in point_rows if r.get("http_ok") and r.get("status_ok")]
    fail_rows = [r for r in point_rows if r not in success_rows]

    stage_keys = {
        "request_wall": "request_wall_time_sec",
        "bridge_total": "bridge_total_time_sec",
        "llm": "llm_time_sec",
        "baseline_solver": "baseline_solver_time_sec",
        "locked_solver_total": "locked_solver_time_total_sec",
        "bridge_overhead": "bridge_overhead_time_sec",
    }

    stage_stats: Dict[str, Dict[str, Optional[float]]] = {}
    for label, key in stage_keys.items():
        stage_stats[label] = _summarize_stage_distribution(success_rows, key)

    stage_totals = {label: float(stats.get("total_sec") or 0.0) for label, stats in stage_stats.items()}
    nonzero_stage_totals = {k: v for k, v in stage_totals.items() if v > 0.0}

    bottleneck_by_total: Optional[Dict[str, Any]] = None
    if nonzero_stage_totals:
        stage_name = max(nonzero_stage_totals, key=nonzero_stage_totals.get)
        total_val = nonzero_stage_totals[stage_name]
        total_sum = sum(nonzero_stage_totals.values())
        bottleneck_by_total = {
            "stage": stage_name,
            "total_sec": total_val,
            "share_of_measured_stage_time": _safe_div(total_val, total_sum),
        }

    bottleneck_by_avg: Optional[Dict[str, Any]] = None
    avg_candidates = {
        label: float(stats["avg_sec"])
        for label, stats in stage_stats.items()
        if isinstance(stats.get("avg_sec"), (int, float)) and float(stats["avg_sec"]) > 0.0
    }
    if avg_candidates:
        avg_stage = max(avg_candidates, key=avg_candidates.get)
        bottleneck_by_avg = {
            "stage": avg_stage,
            "avg_sec": avg_candidates[avg_stage],
        }

    ranked_points = sorted(
        point_rows,
        key=lambda r: float(r.get("request_wall_time_sec") or 0.0),
        reverse=True,
    )

    slowest_points = []
    for idx, row in enumerate(ranked_points[:10], start=1):
        slowest_points.append(
            {
                "rank": idx,
                "hand_id": row.get("hand_id"),
                "point_index": row.get("point_index"),
                "street": row.get("street"),
                "request_wall_time_sec": row.get("request_wall_time_sec"),
                "selected_strategy": row.get("selected_strategy"),
                "selection_reason": row.get("selection_reason"),
                "llm_time_sec": row.get("llm_time_sec"),
                "baseline_solver_time_sec": row.get("baseline_solver_time_sec"),
                "locked_solver_time_total_sec": row.get("locked_solver_time_total_sec"),
                "bridge_overhead_time_sec": row.get("bridge_overhead_time_sec"),
                "http_ok": row.get("http_ok"),
                "status_ok": row.get("status_ok"),
                "error": row.get("error"),
            }
        )

    hand_summaries: Dict[str, Any] = {}
    for hand_id, rows in hand_rows_by_id.items():
        hand_summaries[hand_id] = _hand_summary(rows)

    output_payload = {
        "schema_version": "synthetic_pack_timing_report.v1",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "run_config": {
            "pack_path": str(pack_path),
            "endpoint": args.endpoint,
            "preset": args.preset,
            "runtime_profile": args.runtime_profile,
            "solver_timeout_sec": args.solver_timeout,
            "http_timeout_sec": args.http_timeout,
            "ev_keep_margin": args.ev_keep_margin,
            "enable_multi_node_locks": not args.disable_multi_node_locks,
            "max_points": args.max_points,
        },
        "pack_info": {
            "description": payload.get("description"),
            "notes": payload.get("notes"),
            "hand_count": len(hands),
        },
        "coverage": {
            "decision_points_processed": len(point_rows),
            "success_count": len(success_rows),
            "failure_count": len(fail_rows),
            "all_points_successful": len(point_rows) > 0 and len(fail_rows) == 0,
            "success_rate": _safe_div(float(len(success_rows)), float(len(point_rows))) if point_rows else None,
            "run_wall_time_sec": total_elapsed,
        },
        "timing": {
            "stages": stage_stats,
            "bottleneck_by_total": bottleneck_by_total,
            "bottleneck_by_avg": bottleneck_by_avg,
        },
        "slowest_points": slowest_points,
        "hand_summaries": hand_summaries,
        "failures": fail_rows,
        "point_results": point_rows,
    }

    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output_payload, indent=2) + "\n", encoding="utf-8")

    print(f"Synthetic timing report written: {output_path}")
    print(
        "Summary: "
        f"points={len(point_rows)} "
        f"ok={len(success_rows)} "
        f"fail={len(fail_rows)} "
        f"bottleneck_total={(bottleneck_by_total or {}).get('stage')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
