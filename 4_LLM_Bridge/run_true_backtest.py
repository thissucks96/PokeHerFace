#!/usr/bin/env python
"""Run A/B/C routing backtests and report bb/100 + safety + latency metrics."""

from __future__ import annotations

import argparse
import json
import random
import statistics
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from requests import RequestException

from llm_client import PRESET_CONFIGS


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SHARK_CLI = ROOT / "1_Engine_Core" / "build_ninja_vcpkg_rel" / "shark_cli.exe"

MODE_BASELINE = "baseline_gto"
MODE_CLASS1_LIVE = "class1_live_shadow23"
MODE_FULL_MULTI = "full_multi_node_benchmark"
MODE_CHOICES = [MODE_BASELINE, MODE_CLASS1_LIVE, MODE_FULL_MULTI]

CLOUD_SPOT_CAP = 10


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


def _is_cloud_preset(preset: str) -> bool:
    cfg = PRESET_CONFIGS.get(preset, {})
    return str(cfg.get("provider", "")).strip().lower() == "openai"


def _load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _resolve_spots(manifests: List[Path], spot_dirs: List[Path]) -> List[Path]:
    spots: List[Path] = []
    for manifest in manifests:
        payload = _load_json(manifest)
        if not isinstance(payload, list):
            raise ValueError(f"Manifest must be a JSON array: {manifest}")
        for row in payload:
            if not isinstance(row, dict):
                continue
            p = row.get("spot_path")
            if not p:
                continue
            candidate = Path(str(p))
            if not candidate.is_absolute():
                candidate = (manifest.parent / candidate).resolve()
            spots.append(candidate)
    for spot_dir in spot_dirs:
        spots.extend(sorted(spot_dir.glob("*.json")))

    deduped: List[Path] = []
    seen = set()
    for spot in spots:
        r = spot.resolve()
        if r in seen:
            continue
        seen.add(r)
        deduped.append(r)
    return deduped


def _run_baseline_shark(shark_cli: Path, spot: Dict[str, Any], timeout_sec: int) -> Dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="backtest_baseline_") as tmp:
        tmp_dir = Path(tmp)
        spot_path = tmp_dir / "spot.json"
        out_path = tmp_dir / "result.json"
        spot_path.write_text(json.dumps(spot, indent=2) + "\n", encoding="utf-8")
        cmd = [str(shark_cli), "--input", str(spot_path), "--output", str(out_path), "--quiet"]
        started = time.perf_counter()
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec, check=False)
        elapsed = time.perf_counter() - started
        if proc.returncode != 0:
            raise RuntimeError(f"shark_cli failed rc={proc.returncode}: {proc.stderr[-1200:]}")
        result = _load_json(out_path)
        return {"result": result, "solver_wall_time_sec": elapsed}


def _bb100_from_delta(spot: Dict[str, Any], exploitability_delta_pct: Optional[float]) -> Optional[float]:
    if exploitability_delta_pct is None:
        return None
    pot = _float_or_none(spot.get("starting_pot"))
    bb = _float_or_none(spot.get("minimum_bet"))
    if pot is None or bb is None or bb <= 0.0:
        return None
    # Improvement in bb per hand from lower exploitability, scaled to bb/100.
    improvement_bb = (-exploitability_delta_pct / 100.0) * (pot / bb)
    return improvement_bb * 100.0


def _build_request_payload(
    *,
    mode: str,
    spot: Dict[str, Any],
    preset: str,
    solver_timeout: int,
    ev_keep_margin: float,
    include_spot_profile: bool,
    runtime_profile: Optional[str],
) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "spot": spot,
        "timeout_sec": solver_timeout,
        "quiet": True,
        "ev_keep_margin": ev_keep_margin,
        "llm": {"preset": preset},
    }
    if runtime_profile:
        payload["runtime_profile"] = runtime_profile
    if include_spot_profile:
        meta = spot.get("meta")
        if isinstance(meta, dict):
            profile = meta.get("opponent_profile")
            if isinstance(profile, dict):
                payload["opponent_profile"] = profile

    if mode == MODE_CLASS1_LIVE:
        # Production route: class-conditional policy in bridge_server enforces turn live / river shadow.
        payload["enable_multi_node_locks"] = True
    elif mode == MODE_FULL_MULTI:
        # Benchmark route: bypass production routing for full multi-node stress.
        payload["enable_multi_node_locks"] = True
        payload["llm"]["mode"] = "benchmark"
    else:
        raise ValueError(f"Unsupported bridge mode payload: {mode}")

    return payload


def _summarize_mode(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    total = len(records)
    ok = [r for r in records if r.get("status_code") == 200]
    ok_n = len(ok)

    def _vals(key: str) -> List[float]:
        out: List[float] = []
        for row in ok:
            value = row.get(key)
            if isinstance(value, (int, float)):
                out.append(float(value))
        return out

    fallback_rate = (sum(1 for r in ok if r.get("fallback_applied")) / ok_n) if ok_n else None
    keep_rate = (sum(1 for r in ok if r.get("node_lock_kept")) / ok_n) if ok_n else None
    lock_applied_rate = (sum(1 for r in ok if r.get("lock_applied")) / ok_n) if ok_n else None

    ev_deltas = _vals("exploitability_delta_pct")
    bb100 = _vals("bb100")
    latencies = _vals("latency_sec")
    llm_times = _vals("llm_time_sec")
    solver_times = _vals("solver_time_sec")

    selected_counts: Dict[str, int] = {}
    for row in ok:
        key = str(row.get("selected_strategy", "unknown"))
        selected_counts[key] = selected_counts.get(key, 0) + 1

    return {
        "calls_total": total,
        "calls_http_ok": ok_n,
        "error_rate": ((total - ok_n) / total) if total else None,
        "fallback_rate": fallback_rate,
        "lock_applied_rate": lock_applied_rate,
        "keep_rate": keep_rate,
        "ev_delta_avg_pct": statistics.mean(ev_deltas) if ev_deltas else None,
        "ev_delta_median_pct": statistics.median(ev_deltas) if ev_deltas else None,
        "ev_delta_improved_rate": (sum(1 for v in ev_deltas if v < 0.0) / len(ev_deltas)) if ev_deltas else None,
        "bb100_avg": statistics.mean(bb100) if bb100 else None,
        "bb100_median": statistics.median(bb100) if bb100 else None,
        "latency_p50_sec": _percentile(latencies, 0.50),
        "latency_p95_sec": _percentile(latencies, 0.95),
        "llm_time_avg_sec": statistics.mean(llm_times) if llm_times else None,
        "solver_time_avg_sec": statistics.mean(solver_times) if solver_times else None,
        "selected_strategy_counts": selected_counts,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run A/B/C true backtest routing comparison.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000/solve")
    parser.add_argument("--manifest", action="append", default=[], help="Canonical manifest JSON (repeatable).")
    parser.add_argument("--spot-dir", action="append", default=[], help="Directory with spot JSON files (repeatable).")
    parser.add_argument("--preset", default="local_qwen3_coder_30b")
    parser.add_argument("--modes", nargs="+", default=MODE_CHOICES, choices=MODE_CHOICES)
    parser.add_argument("--max-spots", type=int, default=0, help="Optional cap after shuffle/order (0=all).")
    parser.add_argument("--seed", type=int, default=4090, help="Shuffle seed.")
    parser.add_argument("--no-shuffle", action="store_true")
    parser.add_argument("--timeout", type=float, default=1800.0, help="HTTP timeout seconds.")
    parser.add_argument("--solver-timeout", type=int, default=1200)
    parser.add_argument("--runtime-profile", choices=["fast", "normal"], default=None)
    parser.add_argument("--ev-keep-margin", type=float, default=0.001)
    parser.add_argument("--shark-cli", default=str(DEFAULT_SHARK_CLI))
    parser.add_argument("--no-opponent-profile", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    manifests = [Path(p).resolve() for p in args.manifest]
    spot_dirs = [Path(p).resolve() for p in args.spot_dir]
    shark_cli = Path(args.shark_cli).resolve()
    if not shark_cli.exists():
        raise SystemExit(f"shark_cli not found: {shark_cli}")
    if not manifests and not spot_dirs:
        raise SystemExit("Provide at least one --manifest or --spot-dir.")

    spots = _resolve_spots(manifests, spot_dirs)
    if not spots:
        raise SystemExit("No spot files found.")
    missing = [str(p) for p in spots if not p.exists()]
    if missing:
        raise SystemExit(f"Spot files missing ({len(missing)}).")

    if not args.no_shuffle:
        rng = random.Random(args.seed)
        rng.shuffle(spots)
    if args.max_spots > 0:
        spots = spots[: args.max_spots]

    cloud_cap_applied = False
    if _is_cloud_preset(args.preset) and len(spots) > CLOUD_SPOT_CAP:
        spots = spots[:CLOUD_SPOT_CAP]
        cloud_cap_applied = True

    spot_payloads: Dict[str, Dict[str, Any]] = {}
    baseline_cache: Dict[str, Dict[str, Any]] = {}
    records_by_mode: Dict[str, List[Dict[str, Any]]] = {mode: [] for mode in args.modes}

    for spot_path in spots:
        spot = _load_json(spot_path)
        spot_key = str(spot_path)
        spot_payloads[spot_key] = spot

        baseline_started = time.perf_counter()
        try:
            baseline = _run_baseline_shark(shark_cli, spot, timeout_sec=args.solver_timeout)
            baseline_elapsed = time.perf_counter() - baseline_started
            baseline_result = baseline["result"]
            baseline_exp = _float_or_none(baseline_result.get("final_exploitability_pct"))
            baseline_cache[spot_key] = {
                "status_code": 200,
                "baseline_exploitability_pct": baseline_exp,
                "solver_time_sec": baseline.get("solver_wall_time_sec", baseline_elapsed),
            }
        except Exception as exc:  # pylint: disable=broad-except
            baseline_cache[spot_key] = {
                "status_code": 500,
                "error": str(exc),
                "baseline_exploitability_pct": None,
                "solver_time_sec": time.perf_counter() - baseline_started,
            }

    for mode in args.modes:
        for spot_path in spots:
            spot_key = str(spot_path)
            spot = spot_payloads[spot_key]
            baseline = baseline_cache[spot_key]
            baseline_exp = _float_or_none(baseline.get("baseline_exploitability_pct"))

            if mode == MODE_BASELINE:
                record = {
                    "spot": spot_key,
                    "mode": mode,
                    "status_code": baseline.get("status_code", 500),
                    "selected_strategy": "baseline_gto",
                    "selection_reason": "direct_shark_baseline",
                    "node_lock_kept": False,
                    "fallback_applied": False,
                    "lock_applied": False,
                    "baseline_exploitability_pct": baseline_exp,
                    "final_exploitability_pct": baseline_exp,
                    "exploitability_delta_pct": 0.0 if baseline_exp is not None else None,
                    "bb100": 0.0 if baseline_exp is not None else None,
                    "latency_sec": _float_or_none(baseline.get("solver_time_sec")),
                    "solver_time_sec": _float_or_none(baseline.get("solver_time_sec")),
                    "llm_time_sec": 0.0,
                    "error": baseline.get("error"),
                }
                records_by_mode[mode].append(record)
                continue

            payload = _build_request_payload(
                mode=mode,
                spot=spot,
                preset=args.preset,
                solver_timeout=args.solver_timeout,
                ev_keep_margin=args.ev_keep_margin,
                include_spot_profile=not args.no_opponent_profile,
                runtime_profile=args.runtime_profile,
            )
            started = time.perf_counter()
            try:
                resp = requests.post(args.endpoint, json=payload, timeout=args.timeout)
                wall = time.perf_counter() - started
            except RequestException as exc:
                records_by_mode[mode].append(
                    {
                        "spot": spot_key,
                        "mode": mode,
                        "status_code": 0,
                        "error": str(exc),
                        "latency_sec": time.perf_counter() - started,
                    }
                )
                continue

            if resp.status_code >= 400:
                records_by_mode[mode].append(
                    {
                        "spot": spot_key,
                        "mode": mode,
                        "status_code": resp.status_code,
                        "error": resp.text[-2000:],
                        "latency_sec": wall,
                    }
                )
                continue

            body = resp.json()
            metrics = body.get("metrics", {}) if isinstance(body.get("metrics"), dict) else {}
            node_lock = body.get("node_lock", {}) if isinstance(body.get("node_lock"), dict) else {}
            node_lock_meta = node_lock.get("meta", {}) if isinstance(node_lock.get("meta"), dict) else {}
            llm_error = metrics.get("llm_error")
            fallback_applied = bool(node_lock_meta.get("fallback_applied", False) or bool(llm_error))

            final_exp = _float_or_none(metrics.get("final_exploitability_pct"))
            delta = _float_or_none(metrics.get("exploitability_delta_pct"))
            if delta is None and baseline_exp is not None and final_exp is not None:
                delta = final_exp - baseline_exp

            record = {
                "spot": spot_key,
                "mode": mode,
                "status_code": resp.status_code,
                "selected_strategy": body.get("selected_strategy"),
                "selection_reason": body.get("selection_reason"),
                "node_lock_kept": bool(body.get("node_lock_kept", False)),
                "fallback_applied": fallback_applied,
                "lock_applied": bool(metrics.get("lock_applied", False)),
                "baseline_exploitability_pct": baseline_exp,
                "final_exploitability_pct": final_exp,
                "exploitability_delta_pct": delta,
                "bb100": _bb100_from_delta(spot, delta),
                "latency_sec": _float_or_none(metrics.get("total_bridge_time_sec")) or wall,
                "solver_time_sec": _float_or_none(metrics.get("solver_time_sec")),
                "llm_time_sec": _float_or_none(metrics.get("llm_time_sec")),
                "multi_node_enabled": bool(metrics.get("multi_node_enabled", False)),
                "multi_node_policy_reason": metrics.get("multi_node_policy_reason"),
                "error": llm_error,
            }
            records_by_mode[mode].append(record)

    summaries = {mode: _summarize_mode(records_by_mode[mode]) for mode in args.modes}
    report = {
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "endpoint": args.endpoint,
        "shark_cli": str(shark_cli),
        "preset": args.preset,
        "ev_keep_margin": args.ev_keep_margin,
        "runtime_profile": args.runtime_profile,
        "modes": args.modes,
        "seed": args.seed,
        "shuffle": not args.no_shuffle,
        "cloud_spot_cap_applied": cloud_cap_applied,
        "spots_total": len(spots),
        "spot_inputs": [str(p) for p in spots],
        "summaries": summaries,
        "records": records_by_mode,
        "notes": {
            "bb100_definition": "Derived from exploitability delta proxy: (-delta_pct/100)*(starting_pot/minimum_bet)*100.",
            "baseline_mode": "Direct shark_cli baseline solve (no LLM, no lock).",
        },
    }

    out_path = Path(args.output).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(out_path), "summaries": summaries}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
