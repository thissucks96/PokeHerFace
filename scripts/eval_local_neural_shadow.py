#!/usr/bin/env python3
"""Evaluate neural shadow report against promotion gates."""

from __future__ import annotations

import argparse
import json
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


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _latest_shadow_report(report_dir: Path) -> Path | None:
    reports = sorted(report_dir.glob("neural_shadow_report_*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    return reports[0] if reports else None


def _default_gate_config() -> dict[str, Any]:
    return {
        "minimum_rows": 100,
        "max_neural_elapsed_p95_sec": 2.0,
        "min_agree_rate_overall": 0.70,
        "min_agree_rate_by_street": {
            "flop": 0.65,
            "turn": 0.70,
            "river": 0.72,
        },
        "max_surrogate_rate": 0.5,
    }


def _load_gate_config(path: Path | None) -> dict[str, Any]:
    cfg = _default_gate_config()
    if path and path.exists():
        incoming = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(incoming, dict):
            cfg.update(incoming)
    return cfg


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate local neural shadow report against promotion gates.")
    parser.add_argument(
        "--report-json",
        type=Path,
        default=None,
        help="Path to neural shadow report JSON. If omitted, latest report in report-dir is used.",
    )
    parser.add_argument(
        "--report-dir",
        type=Path,
        default=Path("5_Vision_Extraction/out/neural_shadow_reports"),
        help="Directory used to discover latest neural shadow report.",
    )
    parser.add_argument(
        "--gates-config",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/configs/eval_gates.local.json"),
        help="Path to gate config JSON (optional).",
    )
    parser.add_argument(
        "--out-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/neural_promotion_gate_report.json"),
        help="Output gate report JSON.",
    )
    args = parser.parse_args()

    report_path = args.report_json.resolve() if isinstance(args.report_json, Path) else None
    if not report_path:
        latest = _latest_shadow_report(args.report_dir.resolve())
        if latest is None:
            print(json.dumps({"ok": False, "error": f"no_shadow_reports_found_in:{args.report_dir.resolve()}"}))
            return 2
        report_path = latest
    if not report_path.exists():
        print(json.dumps({"ok": False, "error": f"missing_report:{report_path}"}))
        return 2

    shadow = json.loads(report_path.read_text(encoding="utf-8"))
    if not isinstance(shadow, dict):
        print(json.dumps({"ok": False, "error": "invalid_shadow_report"}))
        return 2
    summary = shadow.get("summary") if isinstance(shadow.get("summary"), dict) else {}
    rows = shadow.get("rows") if isinstance(shadow.get("rows"), list) else []
    by_street = summary.get("streets") if isinstance(summary.get("streets"), dict) else {}

    gate_cfg = _load_gate_config(args.gates_config.resolve() if args.gates_config else None)
    min_rows = _safe_int(gate_cfg.get("minimum_rows"), 100)
    max_p95 = _safe_float(gate_cfg.get("max_neural_elapsed_p95_sec"), 2.0)
    min_agree = _safe_float(gate_cfg.get("min_agree_rate_overall"), 0.70)
    min_by_street = gate_cfg.get("min_agree_rate_by_street", {})
    if not isinstance(min_by_street, dict):
        min_by_street = {}
    max_surrogate_rate = _safe_float(gate_cfg.get("max_surrogate_rate"), 0.5)

    files_analyzed = _safe_int(shadow.get("files_analyzed"), len(rows))
    agree_rate = summary.get("agree_rate")
    if agree_rate is None:
        agree_rate = 0.0
    agree_rate = _safe_float(agree_rate, 0.0)
    p95 = _safe_float(summary.get("neural_elapsed_p95_sec"), 0.0)
    surrogate_count = sum(1 for r in rows if bool(r.get("neural_surrogate")))
    surrogate_rate = (surrogate_count / len(rows)) if rows else 0.0

    checks: list[dict[str, Any]] = []

    checks.append(
        {
            "name": "minimum_rows",
            "pass": files_analyzed >= min_rows,
            "actual": files_analyzed,
            "expected_min": min_rows,
        }
    )
    checks.append(
        {
            "name": "overall_agree_rate",
            "pass": agree_rate >= min_agree,
            "actual": agree_rate,
            "expected_min": min_agree,
        }
    )
    checks.append(
        {
            "name": "neural_elapsed_p95_sec",
            "pass": p95 <= max_p95,
            "actual": p95,
            "expected_max": max_p95,
        }
    )
    checks.append(
        {
            "name": "surrogate_rate",
            "pass": surrogate_rate <= max_surrogate_rate,
            "actual": surrogate_rate,
            "expected_max": max_surrogate_rate,
        }
    )
    for street, threshold in min_by_street.items():
        street_key = str(street).strip().lower()
        node = by_street.get(street_key) if isinstance(by_street, dict) else None
        actual = _safe_float(node.get("agree_rate") if isinstance(node, dict) else None, 0.0)
        checks.append(
            {
                "name": f"street_agree_rate:{street_key}",
                "pass": actual >= _safe_float(threshold, 0.0),
                "actual": actual,
                "expected_min": _safe_float(threshold, 0.0),
            }
        )

    passed = all(bool(c.get("pass")) for c in checks)
    result = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "report_path": str(report_path),
        "gates_config_path": str(args.gates_config.resolve()) if args.gates_config else "",
        "passed": passed,
        "checks": checks,
        "snapshot": {
            "files_analyzed": files_analyzed,
            "agree_rate": agree_rate,
            "neural_elapsed_p95_sec": p95,
            "surrogate_rate": surrogate_rate,
        },
    }

    out_path = args.out_json.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
