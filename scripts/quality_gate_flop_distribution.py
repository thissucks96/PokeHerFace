#!/usr/bin/env python3
"""Quality gate for mixed-geometry flop distribution before neural training."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = {
    "input": {
        "artifact_dir": "5_Vision_Extraction/out/flop_engine",
        "max_files": 0,
        "runtime_profiles": ["fast_live"],
    },
    "gates": {
        "min_guard_hit_ratio": 0.30,
        "max_guard_hit_ratio": 0.70,
        "min_total_flops": 200,
        "min_bucket_samples": 20,
        "min_qualified_buckets": 4,
    },
    "output": {
        "report_json": "2_Neural_Brain/local_pipeline/reports/flop_distribution_quality_gate.json",
    },
}


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _iter_response_paths(artifact_dir: Path, max_files: int) -> list[Path]:
    paths = sorted(artifact_dir.glob("*_response_*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    if max_files > 0:
        return paths[:max_files]
    return paths


def _payload_path_for_response(response_path: Path) -> Path:
    return response_path.with_name(response_path.name.replace("_response_", "_payload_"))


def _parse_runtime_profiles(csv_text: str) -> set[str]:
    values = {chunk.strip().lower() for chunk in str(csv_text or "").split(",") if chunk.strip()}
    return {value for value in values if value}


def _parse_runtime_profile_list(items: Any) -> set[str]:
    if not isinstance(items, list):
        return set()
    values = {str(item).strip().lower() for item in items if str(item).strip()}
    return {value for value in values if value}


def _load_config(path: Path | None) -> dict[str, Any]:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if path and path.exists():
        payload = _load_json(path)
        if isinstance(payload, dict):
            for section in ("input", "gates", "output"):
                if isinstance(payload.get(section), dict):
                    cfg[section].update(payload[section])
    return cfg


def _range_width(range_text: str) -> int:
    tokens = [token.strip() for token in str(range_text or "").split(",")]
    return len([token for token in tokens if token])


def _spr_bucket(spr: float) -> str:
    if spr < 4.0:
        return "lt4"
    if spr < 8.0:
        return "4to8"
    if spr < 16.0:
        return "8to16"
    return "16plus"


def _facing_bucket(facing_ratio: float) -> str:
    if facing_ratio <= 0.0:
        return "f0"
    if facing_ratio <= 0.33:
        return "f0_33"
    if facing_ratio <= 0.75:
        return "f33_75"
    return "f75plus"


def _range_bucket(width: int) -> str:
    if width <= 8:
        return "w1_8"
    if width <= 16:
        return "w9_16"
    if width <= 28:
        return "w17_28"
    return "w29plus"


def _rank_value(token: str) -> int:
    rank = token[:-1].upper()
    if rank == "10":
        rank = "T"
    order = "23456789TJQKA"
    return order.index(rank) if rank in order else -1


def _board_class(board: list[str]) -> str:
    if len(board) < 3:
        return "unknown"
    flop = board[:3]
    suits = [card[-1].lower() for card in flop if len(card) >= 2]
    rank_vals = sorted([_rank_value(card) for card in flop if len(card) >= 2])
    rank_tokens = [card[:-1].upper() for card in flop if len(card) >= 2]

    if len(suits) != 3 or len(rank_vals) != 3:
        return "unknown"

    uniq_suits = len(set(suits))
    if uniq_suits == 1:
        tone = "monotone"
    elif uniq_suits == 2:
        tone = "two_tone"
    else:
        tone = "rainbow"

    paired = "paired" if len(set(rank_tokens)) < 3 else "unpaired"
    connected = "connected" if (rank_vals[-1] - rank_vals[0]) <= 4 else "disconnected"
    return f"{tone}_{paired}_{connected}"


def _parse_facing_ratio(spot: dict[str, Any]) -> float:
    starting_pot = float(max(1, _safe_int(spot.get("starting_pot"), 0)))
    active_node_path = str(spot.get("active_node_path") or "")
    if not active_node_path:
        return 0.0
    m = re.search(r"bet:(\d+)", active_node_path)
    if not m:
        return 0.0
    bet_amount = _safe_float(m.group(1), 0.0)
    return bet_amount / starting_pot if starting_pot > 0 else 0.0


def _broad_bucket_from_spot(spot: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    stack = float(max(0, _safe_int(spot.get("starting_stack"), 0)))
    pot = float(max(1, _safe_int(spot.get("starting_pot"), 0)))
    spr = stack / pot if pot > 0 else 0.0
    facing_ratio = _parse_facing_ratio(spot)
    width = _range_width(str(spot.get("villain_range") or ""))
    board = spot.get("board") if isinstance(spot.get("board"), list) else []

    spr_b = _spr_bucket(spr)
    face_b = _facing_bucket(facing_ratio)
    range_b = _range_bucket(width)
    board_b = _board_class([str(card) for card in board])

    bucket = f"spr:{spr_b}|face:{face_b}|range:{range_b}|board:{board_b}"
    meta = {
        "spr": spr,
        "facing_ratio": facing_ratio,
        "villain_range_width": width,
        "board_class": board_b,
    }
    return bucket, meta


def _is_guard_applied(response: dict[str, Any]) -> bool:
    metrics = response.get("metrics") if isinstance(response.get("metrics"), dict) else {}
    if bool(metrics.get("fast_live_flop_complexity_guard_applied")):
        return True

    selection_reason = str(response.get("selection_reason") or "").lower()
    if "complexity_guard_skip" in selection_reason:
        return True

    warnings = response.get("warnings") if isinstance(response.get("warnings"), list) else []
    for warning in warnings:
        if "complexity_guard" in str(warning).lower():
            return True
    return False


def analyze_distribution(artifact_dir: Path, max_files: int, runtime_profiles: set[str]) -> dict[str, Any]:
    scanned = 0
    flop_samples = 0
    guard_hits = 0
    runtime_counter: Counter[str] = Counter()
    broad_bucket_counter: Counter[str] = Counter()
    guard_bucket_counter: Counter[str] = Counter()
    board_class_counter: Counter[str] = Counter()

    for response_path in _iter_response_paths(artifact_dir, max_files=max_files):
        scanned += 1
        payload_path = _payload_path_for_response(response_path)
        payload = _load_json(payload_path)
        response = _load_json(response_path)
        if not payload or not response:
            continue

        stage = response_path.name.split("_response_", 1)[0].lower()
        if "villain" in stage:
            continue

        spot = payload.get("spot") if isinstance(payload.get("spot"), dict) else {}
        board = spot.get("board") if isinstance(spot.get("board"), list) else []
        if len(board) != 3:
            continue

        profile = str(payload.get("runtime_profile") or "").strip().lower()
        if not profile:
            metrics = response.get("metrics") if isinstance(response.get("metrics"), dict) else {}
            profile = str(metrics.get("runtime_profile") or "unknown").strip().lower()

        if runtime_profiles and profile not in runtime_profiles:
            continue

        flop_samples += 1
        runtime_counter[profile] += 1

        broad_bucket, bucket_meta = _broad_bucket_from_spot(spot)
        broad_bucket_counter[broad_bucket] += 1
        board_class_counter[str(bucket_meta["board_class"])] += 1

        metrics = response.get("metrics") if isinstance(response.get("metrics"), dict) else {}
        guard_bucket = str(metrics.get("fast_live_flop_complexity_guard_bucket_id") or "").strip()

        if _is_guard_applied(response):
            guard_hits += 1
            guard_bucket_counter[guard_bucket or broad_bucket] += 1

    guard_hit_ratio = (float(guard_hits) / float(flop_samples)) if flop_samples > 0 else 0.0
    return {
        "responses_scanned": scanned,
        "flop_samples": flop_samples,
        "guard_hits": guard_hits,
        "guard_hit_ratio": guard_hit_ratio,
        "runtime_profile_counts": dict(runtime_counter),
        "broad_bucket_counts": dict(broad_bucket_counter),
        "guard_bucket_counts": dict(guard_bucket_counter),
        "board_class_counts": dict(board_class_counter),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Quality gate for mixed-geometry flop distribution.")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/configs/quality_gate_config.local.json"),
        help="Optional quality gate config JSON.",
    )
    parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=None,
        help="Directory containing payload/response artifacts.",
    )
    parser.add_argument(
        "--report-json",
        type=Path,
        default=None,
        help="Output quality-gate report JSON.",
    )
    parser.add_argument("--max-files", type=int, default=-1, help="Analyze most recent N response files (-1 = config).")
    parser.add_argument(
        "--runtime-profiles",
        type=str,
        default="",
        help="CSV runtime profile filter (blank = all).",
    )
    parser.add_argument("--min-guard-hit-ratio", type=float, default=-1.0)
    parser.add_argument("--max-guard-hit-ratio", type=float, default=-1.0)
    parser.add_argument("--min-total-flops", type=int, default=-1)
    parser.add_argument("--min-bucket-samples", type=int, default=-1)
    parser.add_argument("--min-qualified-buckets", type=int, default=-1)
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when any gate fails.")
    args = parser.parse_args()

    cfg = _load_config(args.config.resolve() if args.config else None)
    input_cfg = cfg["input"]
    gate_cfg = cfg["gates"]
    output_cfg = cfg["output"]

    artifact_dir = args.artifact_dir.resolve() if isinstance(args.artifact_dir, Path) else Path(str(input_cfg["artifact_dir"])).resolve()
    if not artifact_dir.exists():
        raise SystemExit(f"artifact dir not found: {artifact_dir}")

    report_json = args.report_json.resolve() if isinstance(args.report_json, Path) else Path(str(output_cfg["report_json"])).resolve()
    max_files = int(input_cfg.get("max_files", 0)) if args.max_files < 0 else max(0, int(args.max_files))
    runtime_profiles = (
        _parse_runtime_profiles(args.runtime_profiles)
        if args.runtime_profiles
        else _parse_runtime_profile_list(input_cfg.get("runtime_profiles", []))
    )
    min_guard_hit_ratio = float(gate_cfg.get("min_guard_hit_ratio", 0.30)) if args.min_guard_hit_ratio < 0 else float(args.min_guard_hit_ratio)
    max_guard_hit_ratio = float(gate_cfg.get("max_guard_hit_ratio", 0.70)) if args.max_guard_hit_ratio < 0 else float(args.max_guard_hit_ratio)
    min_total_flops = int(gate_cfg.get("min_total_flops", 200)) if args.min_total_flops < 0 else int(args.min_total_flops)
    min_bucket_samples = int(gate_cfg.get("min_bucket_samples", 20)) if args.min_bucket_samples < 0 else int(args.min_bucket_samples)
    min_qualified_buckets = (
        int(gate_cfg.get("min_qualified_buckets", 4))
        if args.min_qualified_buckets < 0
        else int(args.min_qualified_buckets)
    )

    analysis = analyze_distribution(
        artifact_dir=artifact_dir,
        max_files=max_files,
        runtime_profiles=runtime_profiles,
    )

    broad_bucket_counts = analysis["broad_bucket_counts"]
    qualified_bucket_count = len(
        [
            bucket
            for bucket, count in broad_bucket_counts.items()
            if int(count) >= int(min_bucket_samples)
        ]
    )

    pass_guard_ratio = bool(min_guard_hit_ratio <= analysis["guard_hit_ratio"] <= max_guard_hit_ratio)
    pass_flop_min = bool(int(analysis["flop_samples"]) >= int(min_total_flops))
    pass_bucket_diversity = bool(qualified_bucket_count >= int(min_qualified_buckets))

    passed = pass_guard_ratio and pass_flop_min and pass_bucket_diversity

    top_buckets = sorted(
        broad_bucket_counts.items(),
        key=lambda kv: int(kv[1]),
        reverse=True,
    )[:20]

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "artifact_dir": str(artifact_dir),
        "runtime_profiles": sorted(runtime_profiles),
        "analysis": analysis,
        "gates": {
            "min_guard_hit_ratio": float(min_guard_hit_ratio),
            "max_guard_hit_ratio": float(max_guard_hit_ratio),
            "min_total_flops": int(min_total_flops),
            "min_bucket_samples": int(min_bucket_samples),
            "min_qualified_buckets": int(min_qualified_buckets),
        },
        "results": {
            "qualified_bucket_count": qualified_bucket_count,
            "pass_guard_hit_ratio": pass_guard_ratio,
            "pass_min_total_flops": pass_flop_min,
            "pass_bucket_diversity": pass_bucket_diversity,
            "passed": passed,
        },
        "top_broad_buckets": [
            {"bucket": bucket, "count": int(count)} for bucket, count in top_buckets
        ],
    }

    report_path = report_json
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))

    if args.strict and not passed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
