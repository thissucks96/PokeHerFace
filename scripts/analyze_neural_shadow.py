#!/usr/bin/env python3
"""Analyze neural shadow telemetry from bridge response artifacts."""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _safe_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    if isinstance(value, (int, float)):
        return bool(value)
    return False


def _detect_street(board: Any) -> str:
    if not isinstance(board, list):
        return "unknown"
    size = len(board)
    if size >= 5:
        return "river"
    if size == 4:
        return "turn"
    if size == 3:
        return "flop"
    if size == 0:
        return "preflop"
    return f"partial_{size}"


def _iter_response_paths(response_dir: Path, max_files: int | None) -> list[Path]:
    paths = sorted(response_dir.glob("*_response_*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    if max_files is not None and max_files > 0:
        return paths[:max_files]
    return paths


def _quantile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    q = max(0.0, min(1.0, q))
    idx = (len(values) - 1) * q
    lo = int(idx)
    hi = min(lo + 1, len(values) - 1)
    frac = idx - lo
    return values[lo] * (1.0 - frac) + values[hi] * frac


def build_report(
    response_dir: Path,
    output_dir: Path,
    max_files: int | None,
) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []

    for path in _iter_response_paths(response_dir, max_files=max_files):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        if str(payload.get("status", "")).lower() != "ok":
            continue

        metrics = payload.get("metrics") if isinstance(payload.get("metrics"), dict) else {}
        neural = payload.get("neural_shadow")
        if not isinstance(neural, dict):
            neural = metrics.get("neural_shadow") if isinstance(metrics.get("neural_shadow"), dict) else {}
        result = payload.get("result") if isinstance(payload.get("result"), dict) else {}
        result_input = result.get("input") if isinstance(result.get("input"), dict) else {}
        board = result_input.get("board") if isinstance(result_input.get("board"), list) else []
        stage = path.name.split("_response_", 1)[0]
        runtime_profile = str(metrics.get("runtime_profile") or "unknown").strip().lower()
        street = _detect_street(board)

        row = {
            "response_path": str(path.resolve()),
            "stage": stage,
            "street": street,
            "runtime_profile": runtime_profile,
            "selected_strategy": str(payload.get("selected_strategy") or ""),
            "selection_reason": str(payload.get("selection_reason") or ""),
            "bridge_total_sec": _safe_float(metrics.get("total_bridge_time_sec"), 0.0),
            "solver_sec": _safe_float(metrics.get("solver_time_sec"), 0.0),
            "neural_enabled": _safe_bool(neural.get("enabled")),
            "neural_mode": str(neural.get("mode") or metrics.get("neural_mode") or ""),
            "neural_attempted": _safe_bool(neural.get("attempted")),
            "neural_available": _safe_bool(neural.get("available")),
            "neural_applied": _safe_bool(neural.get("applied")),
            "neural_elapsed_sec": _safe_float(neural.get("elapsed_sec") or metrics.get("neural_time_sec"), 0.0),
            "neural_error": str(neural.get("error") or metrics.get("neural_error") or ""),
            "selected_action": str(neural.get("selected_action") or ""),
            "neural_chosen_action": str(neural.get("neural_chosen_action") or ""),
            "agrees_with_selected": neural.get("agrees_with_selected"),
            "neural_adapter": str(neural.get("neural_adapter") or ""),
            "neural_surrogate": _safe_bool(neural.get("neural_surrogate")),
        }
        rows.append(row)

    rows.sort(key=lambda r: r["bridge_total_sec"], reverse=True)

    agree_rows = [r for r in rows if isinstance(r.get("agrees_with_selected"), bool)]
    agree_true = sum(1 for r in agree_rows if bool(r["agrees_with_selected"]))
    agree_rate = (agree_true / len(agree_rows)) if agree_rows else None
    attempted_rows = [r for r in rows if r["neural_attempted"]]
    available_rows = [r for r in rows if r["neural_available"]]
    applied_rows = [r for r in rows if r["neural_applied"]]

    by_profile: dict[str, dict[str, Any]] = {}
    by_street: dict[str, dict[str, Any]] = {}
    by_adapter: dict[str, dict[str, Any]] = {}
    grouped_profile: dict[str, list[dict[str, Any]]] = defaultdict(list)
    grouped_street: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped_profile[row["runtime_profile"]].append(row)
        grouped_street[row["street"]].append(row)

    for key, group in grouped_profile.items():
        agree_subset = [r for r in group if isinstance(r.get("agrees_with_selected"), bool)]
        by_profile[key] = {
            "count": len(group),
            "attempted": sum(1 for r in group if r["neural_attempted"]),
            "available": sum(1 for r in group if r["neural_available"]),
            "applied": sum(1 for r in group if r["neural_applied"]),
            "agree_rate": (
                sum(1 for r in agree_subset if bool(r["agrees_with_selected"])) / len(agree_subset)
                if agree_subset
                else None
            ),
            "neural_elapsed_mean_sec": (
                sum(r["neural_elapsed_sec"] for r in group) / len(group) if group else 0.0
            ),
        }

    for key, group in grouped_street.items():
        agree_subset = [r for r in group if isinstance(r.get("agrees_with_selected"), bool)]
        by_street[key] = {
            "count": len(group),
            "attempted": sum(1 for r in group if r["neural_attempted"]),
            "available": sum(1 for r in group if r["neural_available"]),
            "applied": sum(1 for r in group if r["neural_applied"]),
            "agree_rate": (
                sum(1 for r in agree_subset if bool(r["agrees_with_selected"])) / len(agree_subset)
                if agree_subset
                else None
            ),
            "neural_elapsed_mean_sec": (
                sum(r["neural_elapsed_sec"] for r in group) / len(group) if group else 0.0
            ),
        }

    grouped_adapter: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        adapter_key = row["neural_adapter"] or "none"
        grouped_adapter[adapter_key].append(row)
    for key, group in grouped_adapter.items():
        by_adapter[key] = {
            "count": len(group),
            "attempted": sum(1 for r in group if r["neural_attempted"]),
            "available": sum(1 for r in group if r["neural_available"]),
            "surrogate": sum(1 for r in group if r["neural_surrogate"]),
            "neural_elapsed_mean_sec": (
                sum(r["neural_elapsed_sec"] for r in group) / len(group) if group else 0.0
            ),
        }

    disagreement_counter = Counter()
    for row in rows:
        if row.get("agrees_with_selected") is False:
            key = f"{row.get('selected_action') or '?'} -> {row.get('neural_chosen_action') or '?'}"
            disagreement_counter[key] += 1

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "response_dir": str(response_dir.resolve()),
        "files_analyzed": len(rows),
        "summary": {
            "neural_attempted": len(attempted_rows),
            "neural_available": len(available_rows),
            "neural_applied": len(applied_rows),
            "agree_rows": len(agree_rows),
            "agree_rate": agree_rate,
            "neural_elapsed_p50_sec": _quantile([r["neural_elapsed_sec"] for r in rows], 0.5),
            "neural_elapsed_p95_sec": _quantile([r["neural_elapsed_sec"] for r in rows], 0.95),
            "bridge_total_p95_sec": _quantile([r["bridge_total_sec"] for r in rows], 0.95),
            "runtime_profiles": by_profile,
            "streets": by_street,
            "adapters": by_adapter,
            "top_disagreements": disagreement_counter.most_common(20),
        },
        "rows": rows,
    }

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    json_path = output_dir / f"neural_shadow_report_{timestamp}.json"
    csv_path = output_dir / f"neural_shadow_disagreements_{timestamp}.csv"
    json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    disagreement_rows = [r for r in rows if r.get("agrees_with_selected") is False]
    with csv_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "runtime_profile",
                "street",
                "stage",
                "selected_strategy",
                "selected_action",
                "neural_chosen_action",
                "bridge_total_sec",
                "solver_sec",
                "neural_elapsed_sec",
                "neural_mode",
                "neural_adapter",
                "neural_surrogate",
                "neural_error",
                "response_path",
            ],
        )
        writer.writeheader()
        for row in disagreement_rows:
            writer.writerow({k: row.get(k, "") for k in writer.fieldnames})

    return json_path, csv_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze neural shadow telemetry from response artifacts.")
    parser.add_argument(
        "--response-dir",
        type=Path,
        default=Path("5_Vision_Extraction/out/flop_engine"),
        help="Directory containing *_response_*.json artifacts.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("5_Vision_Extraction/out/neural_shadow_reports"),
        help="Directory to write analyzer output.",
    )
    parser.add_argument(
        "--max-files",
        type=int,
        default=None,
        help="Only analyze the most recent N response artifacts.",
    )
    args = parser.parse_args()

    if not args.response_dir.exists():
        raise SystemExit(f"Response directory not found: {args.response_dir}")

    json_path, csv_path = build_report(
        response_dir=args.response_dir,
        output_dir=args.output_dir,
        max_files=args.max_files,
    )
    print(f"Wrote neural shadow JSON report: {json_path}")
    print(f"Wrote neural shadow disagreement CSV: {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
