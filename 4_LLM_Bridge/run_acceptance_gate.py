#!/usr/bin/env python
"""Run canonical acceptance benchmarks with preflight filtering and pass/fail gating."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests

from llm_client import PRESET_CONFIGS


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SHARK_CLI = ROOT / "1_Engine_Core" / "build_ninja_vcpkg_rel" / "shark_cli.exe"
CLOUD_CALL_CAP = 10


def _is_cloud_preset(preset: str) -> bool:
    config = PRESET_CONFIGS.get(preset, {})
    return str(config.get("provider", "")).lower() == "openai"


def _extract_allowed_root_actions(result_payload: Dict[str, Any]) -> List[str]:
    allowed: List[str] = []
    root_actions = result_payload.get("root_actions", [])
    if not isinstance(root_actions, list):
        return allowed
    for item in root_actions:
        if not isinstance(item, dict):
            continue
        action = str(item.get("action", "")).strip().lower()
        if not action:
            continue
        if action in {"bet", "raise"}:
            amount = item.get("amount")
            if isinstance(amount, (int, float)):
                allowed.append(f"{action}:{int(amount)}")
            else:
                allowed.append(action)
        else:
            allowed.append(action)
    deduped: List[str] = []
    seen = set()
    for action in allowed:
        if action in seen:
            continue
        seen.add(action)
        deduped.append(action)
    return deduped


def _run_baseline_shark(shark_cli: Path, spot_path: Path, timeout_sec: int) -> Dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="acceptance_preflight_") as tmp:
        out_path = Path(tmp) / "result.json"
        cmd = [str(shark_cli), "--input", str(spot_path), "--output", str(out_path), "--quiet"]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"shark_cli failed rc={proc.returncode}: {proc.stderr[-1200:]}")
        return json.loads(out_path.read_text(encoding="utf-8"))


def _load_spot(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _extract_spot_opponent_profile(spot: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    meta = spot.get("meta")
    if not isinstance(meta, dict):
        return None
    profile = meta.get("opponent_profile")
    if isinstance(profile, dict):
        return profile
    return None


def _extract_spot_rollout_classes(spot: Dict[str, Any]) -> Dict[str, bool]:
    meta = spot.get("meta")
    if not isinstance(meta, dict):
        return {}
    classes = meta.get("rollout_classes")
    if not isinstance(classes, dict):
        return {}
    out: Dict[str, bool] = {}
    for key, value in classes.items():
        out[str(key)] = bool(value)
    return out


def _resolve_spots(manifest_path: Optional[Path], spot_dir: Optional[Path]) -> List[Path]:
    if manifest_path:
        rows = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(rows, list):
            raise ValueError("canonical_manifest must be a JSON array.")
        spots = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            p = row.get("spot_path")
            if not p:
                continue
            candidate = Path(str(p))
            if not candidate.is_absolute():
                candidate = (manifest_path.parent / candidate).resolve()
            spots.append(candidate)
        return spots
    if not spot_dir:
        raise ValueError("Provide either --canonical-manifest or --spot-dir.")
    return sorted(spot_dir.glob("*.json"))


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Run acceptance gate against canonical spot pack.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000/solve")
    parser.add_argument("--canonical-manifest", help="Path to canonical_manifest.json.")
    parser.add_argument("--spot-dir", help="Fallback: directory containing spot JSON files.")
    parser.add_argument("--preset", default="local_qwen3_coder_30b")
    parser.add_argument("--calls-per-spot", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=1800.0, help="HTTP timeout seconds.")
    parser.add_argument("--solver-timeout", type=int, default=1200)
    parser.add_argument(
        "--runtime-profile",
        choices=["fast", "fast_live", "normal"],
        default=None,
        help="Optional runtime profile forwarded to bridge /solve (fast|normal).",
    )
    parser.add_argument("--ev-keep-margin", type=float, default=0.005)
    parser.add_argument("--calibrate-noise-runs", type=int, default=0, help="Baseline repeats per spot for noise.")
    parser.add_argument("--noise-epsilon", type=float, default=0.001)
    parser.add_argument("--skip-trivial-check-only", action="store_true", default=True)
    parser.add_argument("--fallback-max", type=float, default=0.05)
    parser.add_argument("--lock-applied-min", type=float, default=0.95)
    parser.add_argument("--keep-rate-min", type=float, default=0.000001)
    parser.add_argument("--output", required=True, help="Path to acceptance summary JSON.")
    parser.add_argument("--details", help="Optional path to write per-call records JSON.")
    parser.add_argument("--shark-cli", help="Path to shark_cli for preflight/noise runs.")
    parser.add_argument(
        "--use-spot-opponent-profile",
        action="store_true",
        help="Attach spot.meta.opponent_profile to each solve request if available.",
    )
    parser.add_argument(
        "--opponent-profile-file",
        help="Optional JSON file with static opponent profile attached to all solve requests.",
    )
    parser.add_argument(
        "--enable-multi-node-locks",
        action="store_true",
        help="Force enable_multi_node_locks=true for all requests in this gate run.",
    )
    parser.add_argument(
        "--multi-node-classes",
        nargs="+",
        default=[],
        help="Enable multi-node only when spot.meta.rollout_classes contains any of these true tags.",
    )
    args = parser.parse_args()

    manifest = Path(args.canonical_manifest).resolve() if args.canonical_manifest else None
    spot_dir = Path(args.spot_dir).resolve() if args.spot_dir else None
    shark_cli = Path(args.shark_cli).resolve() if args.shark_cli else DEFAULT_SHARK_CLI
    if not shark_cli.exists():
        raise SystemExit(f"shark_cli not found: {shark_cli}")

    calls_per_spot = max(1, args.calls_per_spot)
    if _is_cloud_preset(args.preset):
        calls_per_spot = min(calls_per_spot, CLOUD_CALL_CAP)

    spots = _resolve_spots(manifest, spot_dir)
    if not spots:
        raise SystemExit("No spots found.")

    preflight_rows: List[Dict[str, Any]] = []
    eligible_spots: List[Path] = []
    noise_ranges: List[float] = []
    static_opponent_profile: Optional[Dict[str, Any]] = None
    if args.opponent_profile_file:
        static_candidate = json.loads(Path(args.opponent_profile_file).read_text(encoding="utf-8"))
        if not isinstance(static_candidate, dict):
            raise SystemExit("opponent-profile-file must contain a JSON object.")
        static_opponent_profile = static_candidate

    for spot_path in spots:
        if not spot_path.exists():
            preflight_rows.append({"spot": str(spot_path), "status": "missing"})
            continue
        baseline = _run_baseline_shark(shark_cli, spot_path, timeout_sec=args.solver_timeout)
        allowed = _extract_allowed_root_actions(baseline)
        trivial = len(allowed) == 1 and allowed[0] == "check"
        row = {
            "spot": str(spot_path),
            "allowed_root_actions": allowed,
            "trivial_check_only": trivial,
            "baseline_exploitability_pct": baseline.get("final_exploitability_pct"),
        }
        if trivial and args.skip_trivial_check_only:
            row["status"] = "skipped_trivial"
        else:
            row["status"] = "eligible"
            eligible_spots.append(spot_path)
        preflight_rows.append(row)

        if args.calibrate_noise_runs and args.calibrate_noise_runs > 1:
            exploits: List[float] = []
            for _ in range(args.calibrate_noise_runs):
                replay = _run_baseline_shark(shark_cli, spot_path, timeout_sec=args.solver_timeout)
                value = _float_or_none(replay.get("final_exploitability_pct"))
                if value is not None:
                    exploits.append(value)
            if len(exploits) >= 2:
                noise_ranges.append(max(exploits) - min(exploits))

    records: List[Dict[str, Any]] = []
    spot_profile_used = 0
    static_profile_used = 0
    requested_multi_node_classes = [str(c).strip() for c in (args.multi_node_classes or []) if str(c).strip()]
    multi_node_enabled_spots = 0
    for spot_path in eligible_spots:
        spot = _load_spot(spot_path)
        spot_profile = _extract_spot_opponent_profile(spot) if args.use_spot_opponent_profile else None
        rollout_classes = _extract_spot_rollout_classes(spot)
        class_trigger = any(bool(rollout_classes.get(c, False)) for c in requested_multi_node_classes)
        enable_multi_node = bool(args.enable_multi_node_locks or class_trigger)
        if enable_multi_node:
            multi_node_enabled_spots += 1
        if spot_profile is not None:
            spot_profile_used += 1
        if static_opponent_profile is not None:
            static_profile_used += 1
        for _ in range(calls_per_spot):
            payload = {
                "spot": spot,
                "timeout_sec": args.solver_timeout,
                "quiet": True,
                "ev_keep_margin": args.ev_keep_margin,
                "llm": {"preset": args.preset, "mode": "benchmark"},
            }
            if args.runtime_profile:
                payload["runtime_profile"] = args.runtime_profile
            if enable_multi_node:
                payload["enable_multi_node_locks"] = True
            if static_opponent_profile is not None:
                payload["opponent_profile"] = static_opponent_profile
            elif spot_profile is not None:
                payload["opponent_profile"] = spot_profile
            started = time.perf_counter()
            resp = requests.post(args.endpoint, json=payload, timeout=args.timeout)
            elapsed = time.perf_counter() - started
            if resp.status_code >= 400:
                records.append(
                    {
                        "spot": str(spot_path),
                        "status_code": resp.status_code,
                        "request_wall_time_sec": elapsed,
                        "error": resp.text[-2000:],
                    }
                )
                continue
            body = resp.json()
            metrics = body.get("metrics", {})
            node_lock = body.get("node_lock", {}) if isinstance(body.get("node_lock"), dict) else {}
            node_lock_meta = node_lock.get("meta", {}) if isinstance(node_lock.get("meta"), dict) else {}
            llm_error = metrics.get("llm_error")
            fallback_applied = bool(node_lock_meta.get("fallback_applied", False) or bool(llm_error))
            records.append(
                {
                    "spot": str(spot_path),
                    "status_code": resp.status_code,
                    "request_wall_time_sec": elapsed,
                    "selected_strategy": body.get("selected_strategy"),
                    "selection_reason": body.get("selection_reason"),
                    "node_lock_kept": bool(body.get("node_lock_kept", False)),
                    "fallback_applied": fallback_applied,
                    "llm_error": llm_error,
                    "lock_applied": bool(metrics.get("lock_applied", False)),
                    "lock_applications": metrics.get("lock_applications", 0),
                    "lock_confidence": metrics.get("lock_confidence"),
                    "lock_confidence_tag": metrics.get("lock_confidence_tag"),
                    "lock_quality_score": metrics.get("lock_quality_score"),
                    "node_lock_target_count": metrics.get("node_lock_target_count"),
                    "opponent_profile_used": bool("opponent_profile" in payload),
                    "multi_node_enabled": bool(payload.get("enable_multi_node_locks", False)),
                    "llm_time_sec": metrics.get("llm_time_sec"),
                    "solver_time_sec": metrics.get("solver_time_sec"),
                    "total_bridge_time_sec": metrics.get("total_bridge_time_sec"),
                    "exploitability_delta_pct": metrics.get("exploitability_delta_pct"),
                    "baseline_exploitability_pct": metrics.get("baseline_exploitability_pct"),
                    "locked_exploitability_pct": metrics.get("locked_exploitability_pct"),
                }
            )

    ok_records = [r for r in records if r.get("status_code") == 200]
    total_calls = len(records)
    total_ok = len(ok_records)
    fallback_rate = sum(1 for r in ok_records if r.get("fallback_applied")) / total_ok if total_ok else 1.0
    lock_applied_rate = sum(1 for r in ok_records if r.get("lock_applied")) / total_ok if total_ok else 0.0
    keep_rate = sum(1 for r in ok_records if r.get("node_lock_kept")) / total_ok if total_ok else 0.0

    llm_times = [float(r["llm_time_sec"]) for r in ok_records if isinstance(r.get("llm_time_sec"), (int, float))]
    solver_times = [float(r["solver_time_sec"]) for r in ok_records if isinstance(r.get("solver_time_sec"), (int, float))]
    total_times = [
        float(r["total_bridge_time_sec"]) for r in ok_records if isinstance(r.get("total_bridge_time_sec"), (int, float))
    ]
    quality_scores = [float(r["lock_quality_score"]) for r in ok_records if isinstance(r.get("lock_quality_score"), (int, float))]
    confidences = [float(r["lock_confidence"]) for r in ok_records if isinstance(r.get("lock_confidence"), (int, float))]

    noise_p95 = _percentile(noise_ranges, 0.95)
    recommended_margin = (noise_p95 + args.noise_epsilon) if noise_p95 is not None else None

    gate_pass = (
        fallback_rate <= args.fallback_max
        and lock_applied_rate >= args.lock_applied_min
        and keep_rate > args.keep_rate_min
    )

    summary = {
        "preset": args.preset,
        "endpoint": args.endpoint,
        "calls_per_spot_requested": args.calls_per_spot,
        "calls_per_spot_effective": calls_per_spot,
        "cloud_call_cap_applied": bool(_is_cloud_preset(args.preset) and calls_per_spot < args.calls_per_spot),
        "canonical_manifest": str(manifest) if manifest else None,
        "spot_dir": str(spot_dir) if spot_dir else None,
        "spots_total": len(spots),
        "spots_eligible": len(eligible_spots),
        "spots_skipped_trivial": sum(1 for row in preflight_rows if row.get("status") == "skipped_trivial"),
        "use_spot_opponent_profile": bool(args.use_spot_opponent_profile),
        "static_opponent_profile_file": str(Path(args.opponent_profile_file).resolve()) if args.opponent_profile_file else None,
        "spot_opponent_profiles_detected": spot_profile_used,
        "static_opponent_profile_applied_to_spots": static_profile_used,
        "enable_multi_node_locks": bool(args.enable_multi_node_locks),
        "multi_node_classes": requested_multi_node_classes,
        "multi_node_enabled_spots": multi_node_enabled_spots,
        "runtime_profile": args.runtime_profile,
        "calls_total": total_calls,
        "calls_http_ok": total_ok,
        "fallback_rate": fallback_rate,
        "lock_applied_rate": lock_applied_rate,
        "keep_rate": keep_rate,
        "ev_keep_margin": args.ev_keep_margin,
        "noise_calibration_runs": args.calibrate_noise_runs,
        "noise_range_samples": noise_ranges,
        "noise_p95": noise_p95,
        "recommended_ev_keep_margin": recommended_margin,
        "llm_time_avg_sec": statistics.mean(llm_times) if llm_times else None,
        "solver_time_avg_sec": statistics.mean(solver_times) if solver_times else None,
        "total_bridge_time_avg_sec": statistics.mean(total_times) if total_times else None,
        "lock_quality_avg_score": statistics.mean(quality_scores) if quality_scores else None,
        "lock_confidence_avg": statistics.mean(confidences) if confidences else None,
        "criteria": {
            "fallback_max": args.fallback_max,
            "lock_applied_min": args.lock_applied_min,
            "keep_rate_min": args.keep_rate_min,
        },
        "pass": gate_pass,
        "preflight": preflight_rows,
    }

    out_path = Path(args.output).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    if args.details:
        details_path = Path(args.details).resolve()
        details_path.parent.mkdir(parents=True, exist_ok=True)
        details_path.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")

    print(json.dumps({"output": str(out_path), "pass": gate_pass, "summary": summary}, indent=2))
    return 0 if gate_pass else 2


if __name__ == "__main__":
    raise SystemExit(main())
