#!/usr/bin/env python
"""Run capped benchmark batches against bridge_server /solve endpoint."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path
from typing import Dict, List

import requests
from requests import RequestException

from llm_client import PRESET_CONFIGS


CLOUD_MAX_CALLS_PER_MODEL = 10


def _is_cloud_preset(preset: str) -> bool:
    cfg = PRESET_CONFIGS.get(preset, {})
    return str(cfg.get("provider", "")).lower() == "openai"


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def summarize(records: List[dict]) -> dict:
    if not records:
        return {}

    def vals(key: str) -> List[float]:
        out = []
        for r in records:
            v = r.get(key)
            if isinstance(v, (int, float)):
                out.append(float(v))
        return out

    llm_times = vals("llm_time_sec")
    solver_times = vals("solver_time_sec")
    total_times = vals("total_bridge_time_sec")
    exploits = vals("final_exploitability_pct")
    deltas = vals("exploitability_delta_pct")

    return {
        "calls": len(records),
        "llm_time_avg_sec": statistics.mean(llm_times) if llm_times else None,
        "solver_time_avg_sec": statistics.mean(solver_times) if solver_times else None,
        "total_time_avg_sec": statistics.mean(total_times) if total_times else None,
        "exploitability_avg_pct": statistics.mean(exploits) if exploits else None,
        "exploitability_delta_avg_pct": statistics.mean(deltas) if deltas else None,
        "lock_applied_rate": sum(1 for r in records if r.get("lock_applied")) / len(records),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark bridge /solve for multiple model presets.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000/solve")
    parser.add_argument("--spot", required=True, help="Path to spot JSON.")
    parser.add_argument(
        "--presets",
        nargs="+",
        default=["local_gpt_oss_20b", "local_qwen3_coder_30b", "openai_fast", "openai_52"],
        help="LLM presets to benchmark.",
    )
    parser.add_argument("--calls-per-model", type=int, default=3, help="Calls per model preset (hard max 10).")
    parser.add_argument(
        "--max-calls-local",
        type=int,
        default=1000,
        help="Cap for local presets. Cloud presets remain capped at 10.",
    )
    parser.add_argument("--timeout", type=float, default=1200.0)
    parser.add_argument("--solver-timeout", type=int, default=1200)
    parser.add_argument("--compute-baseline-delta", action="store_true")
    parser.add_argument("--output", required=True, help="Path to output benchmark report JSON.")
    args = parser.parse_args()

    spot = load_json(Path(args.spot))

    report: Dict[str, dict] = {"endpoint": args.endpoint, "calls_per_model_requested": args.calls_per_model, "models": {}}

    for preset in args.presets:
        if _is_cloud_preset(preset):
            calls = max(1, min(args.calls_per_model, CLOUD_MAX_CALLS_PER_MODEL))
            if args.calls_per_model > CLOUD_MAX_CALLS_PER_MODEL:
                print(
                    f"Requested calls-per-model {args.calls_per_model} exceeds cloud max "
                    f"{CLOUD_MAX_CALLS_PER_MODEL} for {preset}; using {calls}."
                )
        else:
            calls = max(1, min(args.calls_per_model, max(1, args.max_calls_local)))
            if args.calls_per_model > args.max_calls_local:
                print(f"Requested calls-per-model {args.calls_per_model} exceeds local max {args.max_calls_local}; using {calls}.")

        model_records: List[dict] = []
        print(f"\n==> Benchmarking preset: {preset} ({calls} calls)")

        for i in range(calls):
            payload = {
                "spot": spot,
                "timeout_sec": args.solver_timeout,
                "quiet": True,
                "compute_baseline_delta": args.compute_baseline_delta,
                "llm": {"preset": preset},
            }
            started = time.perf_counter()
            try:
                resp = requests.post(args.endpoint, json=payload, timeout=args.timeout)
                elapsed = time.perf_counter() - started
            except RequestException as exc:
                elapsed = time.perf_counter() - started
                print(f"  [{i+1}/{calls}] ERROR request failed")
                model_records.append(
                    {
                        "status_code": 0,
                        "error": str(exc),
                        "request_wall_time_sec": elapsed,
                    }
                )
                continue

            if resp.status_code >= 400:
                print(f"  [{i+1}/{calls}] ERROR {resp.status_code}")
                model_records.append(
                    {
                        "status_code": resp.status_code,
                        "error": resp.text[-2000:],
                        "request_wall_time_sec": elapsed,
                    }
                )
                continue

            body = resp.json()
            metrics = body.get("metrics", {})
            record = {
                "status_code": resp.status_code,
                "request_wall_time_sec": elapsed,
                "llm_time_sec": metrics.get("llm_time_sec"),
                "solver_time_sec": metrics.get("solver_time_sec"),
                "total_bridge_time_sec": metrics.get("total_bridge_time_sec"),
                "final_exploitability_pct": metrics.get("final_exploitability_pct"),
                "exploitability_delta_pct": metrics.get("exploitability_delta_pct"),
                "lock_applied": metrics.get("lock_applied", False),
                "lock_applications": metrics.get("lock_applications", 0),
            }
            model_records.append(record)
            llm_display = record["llm_time_sec"] if isinstance(record["llm_time_sec"], (int, float)) else -1.0
            solver_display = record["solver_time_sec"] if isinstance(record["solver_time_sec"], (int, float)) else -1.0
            print(
                f"  [{i+1}/{calls}] ok | llm={llm_display:.3f}s "
                f"| solver={solver_display:.3f}s | exploit={record['final_exploitability_pct']}"
            )

        report["models"][preset] = {
            "calls_per_model_effective": calls,
            "provider": PRESET_CONFIGS.get(preset, {}).get("provider", "unknown"),
            "summary": summarize([r for r in model_records if r.get("status_code") == 200]),
            "records": model_records,
        }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"\nBenchmark report written: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
