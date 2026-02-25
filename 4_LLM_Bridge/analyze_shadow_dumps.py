#!/usr/bin/env python
"""Analyze shadow/backtest dumps for River failure patterns."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def _load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _float_or_none(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _is_river_spot(spot_path: str) -> bool:
    low = spot_path.lower()
    if "canonical_river20" in low:
        return True
    try:
        payload = _load_json(Path(spot_path))
        board = payload.get("board", [])
        return isinstance(board, list) and len(board) >= 5
    except Exception:
        return "river" in low


def _spot_meta(spot_path: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {"texture": "unknown", "rollout_classes": {}}
    try:
        payload = _load_json(Path(spot_path))
    except Exception:
        return out
    meta = payload.get("meta", {})
    if isinstance(meta, dict):
        texture = meta.get("texture")
        if isinstance(texture, str) and texture.strip():
            out["texture"] = texture.strip().lower()
        classes = meta.get("rollout_classes")
        if isinstance(classes, dict):
            out["rollout_classes"] = {str(k): bool(v) for k, v in classes.items()}
    return out


def _mode_map(records: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {}
    for row in records:
        spot = str(row.get("spot", "")).strip()
        if not spot:
            continue
        out[spot] = row
    return out


def _mean(values: List[float]) -> Optional[float]:
    if not values:
        return None
    return statistics.mean(values)


def _median(values: List[float]) -> Optional[float]:
    if not values:
        return None
    return statistics.median(values)


def analyze(
    report: Dict[str, Any],
    *,
    control_mode: str,
    challenger_mode: str,
    top_n: int,
    river_only: bool,
) -> Dict[str, Any]:
    records_by_mode = report.get("records", {})
    control_records = records_by_mode.get(control_mode, [])
    challenger_records = records_by_mode.get(challenger_mode, [])
    if not isinstance(control_records, list) or not isinstance(challenger_records, list):
        raise ValueError("Backtest report missing expected records by mode.")

    control_map = _mode_map(control_records)
    challenger_map = _mode_map(challenger_records)
    shared_spots = sorted(set(control_map.keys()) & set(challenger_map.keys()))
    if river_only:
        shared_spots = [spot for spot in shared_spots if _is_river_spot(spot)]

    comparisons: List[Dict[str, Any]] = []
    for spot in shared_spots:
        a = control_map[spot]
        b = challenger_map[spot]
        a_delta = _float_or_none(a.get("exploitability_delta_pct"))
        b_delta = _float_or_none(b.get("exploitability_delta_pct"))
        a_bb100 = _float_or_none(a.get("bb100"))
        b_bb100 = _float_or_none(b.get("bb100"))
        gap_pct = (b_delta - a_delta) if (a_delta is not None and b_delta is not None) else None
        gap_bb100 = (b_bb100 - a_bb100) if (a_bb100 is not None and b_bb100 is not None) else None
        meta = _spot_meta(spot)
        comparisons.append(
            {
                "spot": spot,
                "texture": meta.get("texture", "unknown"),
                "rollout_classes": meta.get("rollout_classes", {}),
                "control_delta_pct": a_delta,
                "challenger_delta_pct": b_delta,
                "delta_gap_pct": gap_pct,
                "control_bb100": a_bb100,
                "challenger_bb100": b_bb100,
                "bb100_gap": gap_bb100,
                "control_selection_reason": a.get("selection_reason"),
                "challenger_selection_reason": b.get("selection_reason"),
                "challenger_multi_node_policy_reason": b.get("multi_node_policy_reason"),
                "control_lock_applied": a.get("lock_applied"),
                "challenger_lock_applied": b.get("lock_applied"),
                "control_keep": a.get("node_lock_kept"),
                "challenger_keep": b.get("node_lock_kept"),
            }
        )

    valid_gap_pct = [row for row in comparisons if row.get("delta_gap_pct") is not None]
    valid_gap_bb = [row for row in comparisons if row.get("bb100_gap") is not None]
    worse = [row for row in valid_gap_pct if float(row["delta_gap_pct"]) > 0.0]
    better = [row for row in valid_gap_pct if float(row["delta_gap_pct"]) < 0.0]
    flat = [row for row in valid_gap_pct if float(row["delta_gap_pct"]) == 0.0]

    by_texture: Dict[str, List[Dict[str, Any]]] = {}
    for row in valid_gap_pct:
        key = str(row.get("texture", "unknown"))
        by_texture.setdefault(key, []).append(row)
    texture_summary: Dict[str, Any] = {}
    for texture, rows in by_texture.items():
        gaps = [float(r["delta_gap_pct"]) for r in rows]
        bbg = [float(r["bb100_gap"]) for r in rows if r.get("bb100_gap") is not None]
        texture_summary[texture] = {
            "count": len(rows),
            "delta_gap_avg_pct": _mean(gaps),
            "delta_gap_median_pct": _median(gaps),
            "bb100_gap_avg": _mean(bbg),
            "worse_rate": sum(1 for g in gaps if g > 0.0) / len(gaps) if gaps else None,
        }

    top_worse = sorted(worse, key=lambda r: float(r["delta_gap_pct"]), reverse=True)[:top_n]
    top_better = sorted(better, key=lambda r: float(r["delta_gap_pct"]))[:top_n]

    selection_counts: Dict[str, int] = {}
    policy_counts: Dict[str, int] = {}
    for row in worse:
        reason = str(row.get("challenger_selection_reason"))
        selection_counts[reason] = selection_counts.get(reason, 0) + 1
        policy = str(row.get("challenger_multi_node_policy_reason"))
        policy_counts[policy] = policy_counts.get(policy, 0) + 1

    summary = {
        "control_mode": control_mode,
        "challenger_mode": challenger_mode,
        "river_only": river_only,
        "spots_compared": len(shared_spots),
        "valid_delta_gap_spots": len(valid_gap_pct),
        "challenger_worse_count": len(worse),
        "challenger_better_count": len(better),
        "challenger_flat_count": len(flat),
        "challenger_worse_rate": (len(worse) / len(valid_gap_pct)) if valid_gap_pct else None,
        "delta_gap_avg_pct": _mean([float(r["delta_gap_pct"]) for r in valid_gap_pct]),
        "delta_gap_median_pct": _median([float(r["delta_gap_pct"]) for r in valid_gap_pct]),
        "bb100_gap_avg": _mean([float(r["bb100_gap"]) for r in valid_gap_bb]),
        "bb100_gap_median": _median([float(r["bb100_gap"]) for r in valid_gap_bb]),
        "challenger_worse_selection_reasons": selection_counts,
        "challenger_worse_policy_reasons": policy_counts,
    }

    return {
        "summary": summary,
        "texture_summary": texture_summary,
        "top_worse_spots": top_worse,
        "top_better_spots": top_better,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze River shadow/backtest failure patterns.")
    parser.add_argument("--backtest-report", required=True, help="Path to run_true_backtest report JSON.")
    parser.add_argument("--control-mode", default="class1_live_shadow23")
    parser.add_argument("--challenger-mode", default="full_multi_node_benchmark")
    parser.add_argument("--top-n", type=int, default=10)
    parser.add_argument("--all-streets", action="store_true", help="Analyze all spots (default River only).")
    parser.add_argument("--output", help="Optional path to write diagnostics JSON.")
    args = parser.parse_args()

    report_path = Path(args.backtest_report).resolve()
    report = _load_json(report_path)
    diagnostics = analyze(
        report,
        control_mode=args.control_mode,
        challenger_mode=args.challenger_mode,
        top_n=max(1, args.top_n),
        river_only=not args.all_streets,
    )

    output = {
        "source_report": str(report_path),
        "diagnostics": diagnostics,
    }

    if args.output:
        out_path = Path(args.output).resolve()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(output, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
