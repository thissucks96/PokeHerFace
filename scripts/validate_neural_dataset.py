#!/usr/bin/env python3
"""Strict schema and class-balance validator for local neural datasets."""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CARD_RE = re.compile(r"^(?:[2-9TJQKA][shdc]|10[shdc])$", re.IGNORECASE)
ACTION_RE = re.compile(r"^(fold|check|call|all_in|raise(?::\d+)?)$", re.IGNORECASE)


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _normalize_action(action: Any) -> str:
    token = str(action or "").strip().lower()
    if token.startswith("bet:"):
        token = "raise:" + token.split(":", 1)[1]
    if token == "bet":
        token = "raise"
    return token


def _action_base(token: str) -> str:
    value = _normalize_action(token)
    return value.split(":", 1)[0]


def _is_card_token(token: Any) -> bool:
    return bool(CARD_RE.match(str(token or "").strip()))


def _iter_rows(dataset_jsonl: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not dataset_jsonl.exists():
        return rows
    with dataset_jsonl.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                rows.append(item)
    return rows


def _validate_row(row: dict[str, Any], idx: int) -> list[str]:
    errors: list[str] = []
    if row.get("schema_version") != 1:
        errors.append(f"row[{idx}]: schema_version must be 1")
    for key in ("row_id", "split_key", "source", "features", "target"):
        if key not in row:
            errors.append(f"row[{idx}]: missing key '{key}'")

    source = row.get("source")
    if not isinstance(source, dict):
        errors.append(f"row[{idx}]: source must be object")
        source = {}
    features = row.get("features")
    if not isinstance(features, dict):
        errors.append(f"row[{idx}]: features must be object")
        features = {}
    target = row.get("target")
    if not isinstance(target, dict):
        errors.append(f"row[{idx}]: target must be object")
        target = {}

    board = features.get("board")
    if not isinstance(board, list):
        errors.append(f"row[{idx}]: features.board must be list")
    else:
        for card in board:
            if not _is_card_token(card):
                errors.append(f"row[{idx}]: invalid board card '{card}'")
        if len(board) > 5:
            errors.append(f"row[{idx}]: board length > 5")

    selected_action = _normalize_action(target.get("selected_action"))
    if not selected_action or not ACTION_RE.match(selected_action):
        errors.append(f"row[{idx}]: invalid target.selected_action '{selected_action}'")

    distribution = target.get("distribution")
    if not isinstance(distribution, list) or len(distribution) == 0:
        errors.append(f"row[{idx}]: target.distribution must be non-empty list")
    else:
        freq_sum = 0.0
        for j, item in enumerate(distribution):
            if not isinstance(item, dict):
                errors.append(f"row[{idx}]: target.distribution[{j}] must be object")
                continue
            action = _normalize_action(item.get("action"))
            if not ACTION_RE.match(action):
                errors.append(f"row[{idx}]: invalid distribution action '{action}'")
            freq = _safe_float(item.get("frequency"), -1.0)
            if freq < 0 or freq > 1.0:
                errors.append(f"row[{idx}]: invalid distribution frequency {freq}")
            freq_sum += max(0.0, freq)
        if abs(freq_sum - 1.0) > 0.15:
            errors.append(f"row[{idx}]: distribution frequency sum out of tolerance ({freq_sum:.3f})")

    if source.get("street") not in {"preflop", "flop", "turn", "river", "unknown"}:
        errors.append(f"row[{idx}]: unexpected source.street '{source.get('street')}'")
    if not str(source.get("runtime_profile", "")).strip():
        errors.append(f"row[{idx}]: missing source.runtime_profile")
    if not str(source.get("selected_strategy", "")).strip():
        errors.append(f"row[{idx}]: missing source.selected_strategy")

    numeric_keys = [
        "starting_stack",
        "starting_pot",
        "minimum_bet",
        "all_in_threshold",
        "iterations",
        "thread_count",
        "raise_cap",
        "facing_bet",
        "hero_street_commit",
        "villain_street_commit",
        "current_pot",
        "hero_chips",
        "villain_chips",
    ]
    for key in numeric_keys:
        value = features.get(key)
        if isinstance(value, (int, float)):
            continue
        errors.append(f"row[{idx}]: features.{key} must be numeric")

    return errors


def _write_balance_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    totals = Counter()
    by_street: dict[str, Counter[str]] = defaultdict(Counter)
    by_profile: dict[str, Counter[str]] = defaultdict(Counter)
    for row in rows:
        source = row.get("source", {})
        target = row.get("target", {})
        action = _action_base(str(target.get("selected_action", "")))
        street = str(source.get("street", "unknown"))
        profile = str(source.get("runtime_profile", "unknown"))
        totals[action] += 1
        by_street[street][action] += 1
        by_profile[profile][action] += 1

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["group_type", "group_value", "action", "count"],
        )
        writer.writeheader()
        for action, count in sorted(totals.items()):
            writer.writerow({"group_type": "overall", "group_value": "all", "action": action, "count": count})
        for group, counter in sorted(by_street.items()):
            for action, count in sorted(counter.items()):
                writer.writerow({"group_type": "street", "group_value": group, "action": action, "count": count})
        for group, counter in sorted(by_profile.items()):
            for action, count in sorted(counter.items()):
                writer.writerow({"group_type": "runtime_profile", "group_value": group, "action": action, "count": count})


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate neural dataset schema and class balance.")
    parser.add_argument(
        "--dataset-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl"),
        help="Dataset JSONL path.",
    )
    parser.add_argument(
        "--report-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/dataset_validation_report.json"),
        help="Validation report output path.",
    )
    parser.add_argument(
        "--class-balance-csv",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/dataset_class_balance.csv"),
        help="Class balance CSV output path.",
    )
    parser.add_argument(
        "--max-errors",
        type=int,
        default=200,
        help="Maximum validation errors retained in report.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on validation errors.",
    )
    args = parser.parse_args()

    dataset_path = args.dataset_jsonl.resolve()
    rows = _iter_rows(dataset_path)
    errors: list[str] = []
    invalid_rows: set[int] = set()
    for idx, row in enumerate(rows):
        row_errors = _validate_row(row=row, idx=idx)
        if row_errors:
            invalid_rows.add(idx)
        errors.extend(row_errors)
        if len(errors) >= max(0, int(args.max_errors)):
            break

    invalid = len(errors)
    valid_rows = max(0, len(rows) - len(invalid_rows))
    _write_balance_csv(args.class_balance_csv.resolve(), rows)

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "dataset_jsonl": str(dataset_path),
        "rows_total": len(rows),
        "valid_rows_estimate": valid_rows,
        "invalid_rows_estimate": len(invalid_rows),
        "errors_found": invalid,
        "errors": errors,
        "class_balance_csv": str(args.class_balance_csv.resolve()),
    }
    report_path = args.report_json.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))

    if args.strict and invalid > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
