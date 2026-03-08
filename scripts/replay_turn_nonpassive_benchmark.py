#!/usr/bin/env python
"""Replay historical turn checked-to-hero spots through the live bridge."""

from __future__ import annotations

import argparse
import json
import time
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List

import requests

FAST_LIVE_BET_SIZING = {
    "flop": {"bet_sizes": [0.33, 0.75, 1.0, 1.25], "raise_sizes": [1.0, 2.0, 2.5, 3.0]},
    "turn": {"bet_sizes": [0.33, 0.75, 1.0, 1.25], "raise_sizes": [1.0, 2.0, 2.5, 3.0]},
    "river": {"bet_sizes": [0.33, 0.75, 1.0, 1.25], "raise_sizes": [1.0, 2.0, 2.5, 3.0]},
}


def _load_rows(input_path: Path, min_historical_latency: float, max_rows: int) -> List[Dict[str, Any]]:
    obj = json.loads(input_path.read_text(encoding="utf-8"))
    hands = obj.get("hands")
    if not isinstance(hands, list):
        raise SystemExit(f"input file has no hands list: {input_path}")

    rows: List[Dict[str, Any]] = []
    for hand_idx, hand in enumerate(hands, start=1):
        streets = hand.get("streets")
        if not isinstance(streets, list):
            continue
        for street_idx, street in enumerate(streets, start=1):
            if street.get("street") != "turn":
                continue
            if street.get("facing_action") != "checked_to_hero":
                continue
            solve_spot = street.get("solve_spot")
            if not isinstance(solve_spot, dict):
                continue
            latency_sec = float(street.get("latency_sec") or 0.0)
            if latency_sec < min_historical_latency:
                continue
            rows.append(
                {
                    "hand_index": hand_idx,
                    "street_index": street_idx,
                    "historical_latency_sec": latency_sec,
                    "historical_action": street.get("action"),
                    "historical_strategy_source": street.get("strategy_source"),
                    "solve_spot": solve_spot,
                }
            )
            if len(rows) >= max_rows:
                return rows
    return rows


def _post_spot(endpoint: str, spot: Dict[str, Any], runtime_profile: str, timeout_sec: int) -> Dict[str, Any]:
    effective_spot = dict(spot)
    if "min_exploitability" not in effective_spot:
        effective_spot["min_exploitability"] = -1.0
    if "bet_sizing" not in effective_spot:
        if str(runtime_profile or "").strip().lower() == "fast_live":
            effective_spot["bet_sizing"] = FAST_LIVE_BET_SIZING
    payload = {
        "spot": effective_spot,
        "timeout_sec": timeout_sec,
        "quiet": True,
        "auto_select_best": True,
        "ev_keep_margin": 0.001,
        "llm": {"preset": "default"},
        "enable_multi_node_locks": False,
        "runtime_profile": runtime_profile,
    }
    started = time.perf_counter()
    response = requests.post(endpoint, json=payload, timeout=timeout_sec + 10)
    elapsed = time.perf_counter() - started
    response.raise_for_status()
    data = response.json()
    data["_client_elapsed_sec"] = elapsed
    return data


def _row_summary(row: Dict[str, Any], response: Dict[str, Any]) -> Dict[str, Any]:
    neural_shadow = response.get("neural_shadow")
    if not isinstance(neural_shadow, dict):
        neural_shadow = {}
    metrics = response.get("metrics")
    if not isinstance(metrics, dict):
        metrics = {}
    return {
        "hand_index": row["hand_index"],
        "historical_latency_sec": row["historical_latency_sec"],
        "historical_action": row["historical_action"],
        "historical_strategy_source": row["historical_strategy_source"],
        "hero_range": row["solve_spot"].get("hero_range"),
        "board": row["solve_spot"].get("board"),
        "pot": row["solve_spot"].get("starting_pot"),
        "selected_strategy": response.get("selected_strategy"),
        "selection_reason": response.get("selection_reason"),
        "chosen_action": response.get("decision", {}).get("action"),
        "allowed_root_actions": response.get("allowed_root_actions"),
        "bridge_elapsed_sec": response.get("_client_elapsed_sec"),
        "bridge_metrics_total_sec": metrics.get("total_bridge_time_sec"),
        "neural_attempted": neural_shadow.get("attempted"),
        "neural_applied": neural_shadow.get("applied"),
        "neural_selected_action": neural_shadow.get("neural_selected_action"),
        "neural_elapsed_sec": neural_shadow.get("elapsed_sec"),
        "neural_surrogate": neural_shadow.get("neural_surrogate"),
        "neural_error": neural_shadow.get("error"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Replay historical turn checked-to-hero spots through the live bridge.")
    parser.add_argument(
        "--input-json",
        type=Path,
        default=Path("4_LLM_Bridge/examples/synthetic_hands/ab_shark_classic_reference_vs_fast_live_seed4090_h50.json"),
    )
    parser.add_argument(
        "--output-json",
        type=Path,
        required=True,
    )
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000/solve")
    parser.add_argument("--runtime-profile", default="fast_live")
    parser.add_argument("--timeout-sec", type=int, default=10)
    parser.add_argument("--min-historical-latency", type=float, default=5.0)
    parser.add_argument("--max-rows", type=int, default=20)
    args = parser.parse_args()

    rows = _load_rows(
        input_path=args.input_json.resolve(),
        min_historical_latency=float(args.min_historical_latency),
        max_rows=int(args.max_rows),
    )
    if not rows:
        raise SystemExit("no matching turn checked-to-hero rows found")

    results: List[Dict[str, Any]] = []
    action_counter: Counter[str] = Counter()
    strategy_counter: Counter[str] = Counter()
    applied_count = 0
    total_elapsed: List[float] = []

    for row in rows:
        response = _post_spot(
            endpoint=args.endpoint,
            spot=row["solve_spot"],
            runtime_profile=str(args.runtime_profile),
            timeout_sec=int(args.timeout_sec),
        )
        summary = _row_summary(row, response)
        results.append(summary)
        action_counter[str(summary["chosen_action"])] += 1
        strategy_counter[str(summary["selected_strategy"])] += 1
        if bool(summary["neural_applied"]):
            applied_count += 1
        if isinstance(summary["bridge_elapsed_sec"], (int, float)):
            total_elapsed.append(float(summary["bridge_elapsed_sec"]))

    total_elapsed_sorted = sorted(total_elapsed)
    p95_elapsed = None
    if total_elapsed_sorted:
        idx = max(0, round(0.95 * (len(total_elapsed_sorted) - 1)))
        p95_elapsed = total_elapsed_sorted[idx]

    report = {
        "schema_version": "turn_nonpassive_replay_v1",
        "input_json": str(args.input_json.resolve()),
        "runtime_profile": str(args.runtime_profile),
        "rows_replayed": len(results),
        "historical_latency_filter_sec": float(args.min_historical_latency),
        "chosen_action_counts": dict(action_counter),
        "selected_strategy_counts": dict(strategy_counter),
        "neural_applied_count": applied_count,
        "avg_bridge_elapsed_sec": (sum(total_elapsed) / len(total_elapsed)) if total_elapsed else None,
        "p95_bridge_elapsed_sec": p95_elapsed,
        "rows": results,
    }
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
