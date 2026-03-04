#!/usr/bin/env python3
"""Post-pass report for offline reference labeling.

Produces:
1) Normalized bucket failure rates (failed / attempted).
2) Streaming integrity checks on label distributions.
"""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


@dataclass
class IntegrityStats:
    rows_checked: int = 0
    bad_json_lines: int = 0
    missing_row_id: int = 0
    missing_reference: int = 0
    missing_root_actions: int = 0
    invalid_action_item: int = 0
    invalid_frequency: int = 0
    frequency_sum_mismatch: int = 0
    selected_action_missing_in_distribution: int = 0
    selected_action_not_present: int = 0

    def failure_count(self) -> int:
        return (
            self.bad_json_lines
            + self.missing_row_id
            + self.missing_reference
            + self.missing_root_actions
            + self.invalid_action_item
            + self.invalid_frequency
            + self.frequency_sum_mismatch
            + self.selected_action_missing_in_distribution
            + self.selected_action_not_present
        )


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _format_amount(value: float) -> str:
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return f"{value:.6f}".rstrip("0").rstrip(".")


def _normalize_action_token(action: Any, amount: Any | None = None) -> str:
    token = str(action or "").strip().lower()
    if token.startswith("bet:"):
        token = "raise:" + token.split(":", 1)[1]
    if token == "bet":
        token = "raise"

    if token in {"raise", "all_in"} and amount is not None:
        amount_f = _safe_float(amount, default=math.nan)
        if not math.isnan(amount_f):
            return f"raise:{_format_amount(max(0.0, amount_f))}"
    return token


def _possible_action_tokens(action: Any, amount: Any | None = None) -> set[str]:
    base = _normalize_action_token(action, amount=None)
    out = {base}
    with_amount = _normalize_action_token(action, amount=amount)
    out.add(with_amount)
    return out


def _street_from_board(board: Any) -> str:
    if not isinstance(board, list):
        return "unknown"
    n = len(board)
    if n <= 0:
        return "preflop"
    if n == 3:
        return "flop"
    if n == 4:
        return "turn"
    if n >= 5:
        return "river"
    return "unknown"


def _bucket_id(row: dict[str, Any]) -> str:
    source = row.get("source") if isinstance(row.get("source"), dict) else {}
    features = row.get("features") if isinstance(row.get("features"), dict) else {}

    street = str(source.get("street") or _street_from_board(features.get("board")) or "unknown")
    mb = max(1e-9, _safe_float(features.get("minimum_bet"), 1.0))
    current_pot = max(0.0, _safe_float(features.get("current_pot"), _safe_float(features.get("starting_pot"), 0.0)))
    facing_bet = max(0.0, _safe_float(features.get("facing_bet"), 0.0))
    starting_stack = max(0.0, _safe_float(features.get("starting_stack"), 0.0))
    starting_pot = max(1e-9, _safe_float(features.get("starting_pot"), current_pot if current_pot > 0 else 1.0))

    pot_bb = current_pot / mb if mb > 0 else 0.0
    if pot_bb < 10:
        pot_bucket = "p_lt10"
    elif pot_bb < 20:
        pot_bucket = "p_10_20"
    elif pot_bb < 40:
        pot_bucket = "p_20_40"
    else:
        pot_bucket = "p_40p"

    if current_pot <= 0:
        facing_ratio = 0.0 if facing_bet <= 0 else 9.0
    else:
        facing_ratio = facing_bet / current_pot
    if facing_ratio <= 1e-12:
        face_bucket = "f_0"
    elif facing_ratio <= 0.33:
        face_bucket = "f_0_033"
    elif facing_ratio <= 1.0:
        face_bucket = "f_033_1"
    else:
        face_bucket = "f_gt1"

    spr = starting_stack / max(starting_pot, 1e-9)
    if spr < 4:
        spr_bucket = "spr_lt4"
    elif spr < 8:
        spr_bucket = "spr_4_8"
    elif spr < 16:
        spr_bucket = "spr_8_16"
    else:
        spr_bucket = "spr_16p"

    return f"{street}|{pot_bucket}|{face_bucket}|{spr_bucket}"


_RANK_VALUE_MAP = {
    "2": 2,
    "3": 3,
    "4": 4,
    "5": 5,
    "6": 6,
    "7": 7,
    "8": 8,
    "9": 9,
    "T": 10,
    "J": 11,
    "Q": 12,
    "K": 13,
    "A": 14,
}


def _extract_rank_suit(token: str) -> tuple[int | None, str]:
    card = str(token or "").strip()
    if len(card) < 2:
        return None, ""
    if card[:2] == "10":
        rank_token = "T"
        suit_token = card[2:3].lower()
    else:
        rank_token = card[:1].upper()
        suit_token = card[-1:].lower()
    return _RANK_VALUE_MAP.get(rank_token), suit_token if suit_token in {"s", "h", "d", "c"} else ""


def _classify_flop_board_bucket(board: Any) -> str:
    if not isinstance(board, list):
        return "unknown"
    cards = [str(card or "").strip() for card in board[:3] if str(card or "").strip()]
    if len(cards) < 3:
        return "unknown"
    ranks: list[int] = []
    suits: list[str] = []
    for card in cards:
        rank_val, suit_val = _extract_rank_suit(card)
        if rank_val is None:
            continue
        ranks.append(rank_val)
        suits.append(suit_val)
    if len(ranks) < 3:
        return "unknown"
    unique_suits = len(set(suits))
    if unique_suits == 3:
        suit_class = "rainbow"
    elif unique_suits == 2:
        suit_class = "two-tone"
    elif unique_suits == 1:
        suit_class = "monotone"
    else:
        suit_class = "unknown"
    unique_ranks = sorted(set(ranks))
    connected = len(unique_ranks) >= 2 and (max(unique_ranks) - min(unique_ranks) <= 4)
    conn_class = "connected" if connected else "disconnected"
    return f"{suit_class}|{conn_class}"


def _classify_postflop_board_bucket(board: Any) -> str:
    if not isinstance(board, list) or not board:
        return "unknown"
    ranks: list[int] = []
    suits: list[str] = []
    for card in board[:5]:
        rank_val, suit_val = _extract_rank_suit(str(card or "").strip())
        if rank_val is None:
            continue
        ranks.append(rank_val)
        suits.append(suit_val)
    if len(ranks) < 3:
        return "unknown"
    unique_suits = len(set(suits))
    if unique_suits >= 3:
        suit_class = "rainbow"
    elif unique_suits == 2:
        suit_class = "two-tone"
    elif unique_suits == 1:
        suit_class = "monotone"
    else:
        suit_class = "unknown"
    paired = len(set(ranks)) < len(ranks)
    unique_ranks = sorted(set(ranks))
    connected = len(unique_ranks) >= 2 and (max(unique_ranks) - min(unique_ranks) <= (len(unique_ranks) + 1))
    return f"{suit_class}|{'paired' if paired else 'unpaired'}|{'connected' if connected else 'disconnected'}"


def _normalize_card(token: Any) -> str:
    raw = str(token or "").strip()
    if len(raw) < 2:
        return ""
    if raw[:2] == "10":
        rank = "T"
        suit = raw[2:3].lower()
    else:
        rank = raw[:1].upper()
        suit = raw[-1:].lower()
    if rank not in _RANK_VALUE_MAP:
        return ""
    if suit not in {"s", "h", "d", "c"}:
        return ""
    return f"{rank}{suit}"


def _unresolved_gate_id_from_row(row: dict[str, Any]) -> str:
    source = row.get("source") if isinstance(row.get("source"), dict) else {}
    features = row.get("features") if isinstance(row.get("features"), dict) else {}
    street = str(source.get("street") or _street_from_board(features.get("board")) or "unknown").strip().lower()
    board = features.get("board")
    board_tokens = [_normalize_card(card) for card in (board if isinstance(board, list) else [])]
    board_tokens = [token for token in board_tokens if token]
    board_class = (
        _classify_flop_board_bucket(board_tokens)
        if street == "flop"
        else _classify_postflop_board_bucket(board_tokens)
    )
    board_key = "-".join(board_tokens[:5]) if board_tokens else "none"

    stack = int(max(0.0, round(_safe_float(features.get("starting_stack"), 0.0))))
    pot = int(max(0.0, round(_safe_float(features.get("starting_pot"), 0.0))))
    min_bet = int(max(1.0, round(_safe_float(features.get("minimum_bet"), 1.0))))
    facing = int(max(0.0, round(_safe_float(features.get("facing_bet"), 0.0))))
    # Bridge contract: hero is player 1, so treat in-position as a strict (player == 1) boolean.
    try:
        in_position_player = int(round(_safe_float(features.get("in_position_player"), 0.0)))
    except (TypeError, ValueError):
        in_position_player = 0
    in_pos = 1 if in_position_player == 1 else 0
    villain_range_width = len([t.strip() for t in str(features.get("villain_range", "")).split(",") if t.strip()])
    return (
        f"{street}|stack:{stack}|pot:{pot}|minbet:{min_bet}|facing:{facing}|"
        f"vrw:{villain_range_width}|pos:{in_pos}|board:{board_class}|cards:{board_key}"
    )


def _load_row_ids(path: Path) -> set[str]:
    out: set[str] = set()
    if not path.exists():
        return out
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(payload, dict):
                continue
            row_id = str(payload.get("row_id") or "").strip()
            if row_id:
                out.add(row_id)
    return out


def _integrity_check(
    labels_jsonl: Path,
    tol: float,
    max_examples: int,
) -> tuple[IntegrityStats, list[str]]:
    stats = IntegrityStats()
    examples: list[str] = []

    if not labels_jsonl.exists():
        examples.append("labels_jsonl_missing")
        return stats, examples

    with labels_jsonl.open("r", encoding="utf-8") as f:
        for i, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            stats.rows_checked += 1
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                stats.bad_json_lines += 1
                if len(examples) < max_examples:
                    examples.append(f"line {i}: invalid json")
                continue
            if not isinstance(row, dict):
                stats.bad_json_lines += 1
                if len(examples) < max_examples:
                    examples.append(f"line {i}: row is not object")
                continue

            row_id = str(row.get("row_id") or "").strip()
            if not row_id:
                stats.missing_row_id += 1
                if len(examples) < max_examples:
                    examples.append(f"line {i}: missing row_id")

            ref = row.get("reference")
            if not isinstance(ref, dict):
                stats.missing_reference += 1
                if len(examples) < max_examples:
                    examples.append(f"line {i}: missing reference block")
                continue

            root_actions = ref.get("root_actions")
            if not isinstance(root_actions, list) or len(root_actions) == 0:
                stats.missing_root_actions += 1
                if len(examples) < max_examples:
                    examples.append(f"line {i}: missing root_actions")
                continue

            freq_sum = 0.0
            dist_tokens: set[str] = set()
            valid_items = 0
            for j, item in enumerate(root_actions):
                if not isinstance(item, dict):
                    stats.invalid_action_item += 1
                    if len(examples) < max_examples:
                        examples.append(f"line {i}: root_actions[{j}] not object")
                    continue
                action = item.get("action")
                amount = item.get("amount")
                freq = item.get("avg_frequency", item.get("frequency"))
                freq_f = _safe_float(freq, default=math.nan)
                if math.isnan(freq_f) or not math.isfinite(freq_f) or freq_f < 0.0 or freq_f > 1.0:
                    stats.invalid_frequency += 1
                    if len(examples) < max_examples:
                        examples.append(f"line {i}: invalid frequency={freq!r}")
                    continue
                freq_sum += freq_f
                valid_items += 1
                dist_tokens.update(_possible_action_tokens(action, amount))

            if valid_items == 0:
                stats.invalid_action_item += 1
                if len(examples) < max_examples:
                    examples.append(f"line {i}: no valid root_actions")
                continue

            if abs(freq_sum - 1.0) > tol:
                stats.frequency_sum_mismatch += 1
                if len(examples) < max_examples:
                    examples.append(f"line {i}: root_actions sum={freq_sum:.8f} (tol={tol})")

            decision = ref.get("decision")
            selected_token = ""
            if isinstance(decision, dict):
                selected_token = _normalize_action_token(decision.get("action"), decision.get("amount"))
                if not selected_token:
                    stats.selected_action_missing_in_distribution += 1
                    if len(examples) < max_examples:
                        examples.append(f"line {i}: decision present but action missing")
                elif selected_token not in dist_tokens and selected_token.split(":", 1)[0] not in dist_tokens:
                    stats.selected_action_not_present += 1
                    if len(examples) < max_examples:
                        examples.append(
                            f"line {i}: decision action '{selected_token}' not in root_actions tokens={sorted(dist_tokens)}"
                        )

    return stats, examples


def main() -> int:
    parser = argparse.ArgumentParser(description="Post-pass report for offline reference label runs.")
    parser.add_argument(
        "--input-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl"),
        help="Teacher/source rows JSONL.",
    )
    parser.add_argument(
        "--labels-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"),
        help="Reference labels JSONL output.",
    )
    parser.add_argument(
        "--errors-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/offline_label_errors.jsonl"),
        help="Offline labeler errors JSONL.",
    )
    parser.add_argument(
        "--report-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/reference_label_postpass_report.json"),
        help="Report output path.",
    )
    parser.add_argument(
        "--manifest-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/offline_label_manifest.json"),
        help="Offline labeler manifest used for count sync checks.",
    )
    parser.add_argument("--integrity-tol", type=float, default=1e-5, help="Tolerance for distribution sum checks.")
    parser.add_argument("--min-bucket-samples", type=int, default=20, help="Minimum attempted samples per bucket.")
    parser.add_argument("--watch-fail-rate", type=float, default=0.02, help="Watchlist threshold.")
    parser.add_argument("--systemic-fail-rate", type=float, default=0.10, help="Systemic failure threshold.")
    parser.add_argument("--max-example-errors", type=int, default=30, help="Max integrity examples captured.")
    parser.add_argument(
        "--unresolved-gate-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/unresolved_gate_ids.json"),
        help="Export path for unresolved gate IDs derived from failed rows.",
    )
    parser.add_argument("--strict", action="store_true", help="Exit non-zero when report is not freeze-ready.")
    args = parser.parse_args()

    input_jsonl = args.input_jsonl.resolve()
    labels_jsonl = args.labels_jsonl.resolve()
    errors_jsonl = args.errors_jsonl.resolve()
    report_json = args.report_json.resolve()
    manifest_json = args.manifest_json.resolve()
    unresolved_gate_json = args.unresolved_gate_json.resolve()

    success_ids = _load_row_ids(labels_jsonl)
    error_ids = _load_row_ids(errors_jsonl)
    overlap_ids = success_ids & error_ids
    manifest_data: dict[str, Any] | None = None
    manifest_stats: dict[str, Any] = {}
    if manifest_json.exists():
        try:
            payload = json.loads(manifest_json.read_text(encoding="utf-8"))
            if isinstance(payload, dict):
                manifest_data = payload
                if isinstance(payload.get("stats"), dict):
                    manifest_stats = payload.get("stats", {})
        except (OSError, json.JSONDecodeError):
            manifest_data = None

    bucket_counts: dict[str, dict[str, int]] = defaultdict(lambda: {"total": 0, "attempted": 0, "succeeded": 0, "failed": 0, "missing": 0})
    total_input_rows = 0
    missing_rows = 0

    if input_jsonl.exists():
        with input_jsonl.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                row_id = str(row.get("row_id") or "").strip()
                if not row_id:
                    continue
                total_input_rows += 1
                bucket = _bucket_id(row)
                stats = bucket_counts[bucket]
                stats["total"] += 1
                if row_id in success_ids:
                    stats["attempted"] += 1
                    stats["succeeded"] += 1
                elif row_id in error_ids:
                    stats["attempted"] += 1
                    stats["failed"] += 1
                else:
                    stats["missing"] += 1
                    missing_rows += 1

    bucket_summary: list[dict[str, Any]] = []
    systemic_buckets: list[str] = []
    watch_buckets: list[str] = []
    min_samples = max(1, int(args.min_bucket_samples))
    for bucket, stats in sorted(bucket_counts.items(), key=lambda kv: kv[1]["attempted"], reverse=True):
        attempted = stats["attempted"]
        failed = stats["failed"]
        fail_rate = (failed / attempted) if attempted > 0 else 0.0
        severity = "ignore_low_n"
        if attempted >= min_samples:
            if fail_rate >= float(args.systemic_fail_rate):
                severity = "systemic"
                systemic_buckets.append(bucket)
            elif fail_rate >= float(args.watch_fail_rate):
                severity = "watch"
                watch_buckets.append(bucket)
            else:
                severity = "ok"
        row = {
            "bucket_id": bucket,
            "total_rows": stats["total"],
            "attempted": attempted,
            "succeeded": stats["succeeded"],
            "failed": failed,
            "missing": stats["missing"],
            "fail_rate_attempted": round(fail_rate, 6),
            "severity": severity,
        }
        bucket_summary.append(row)

    integrity_stats, integrity_examples = _integrity_check(
        labels_jsonl=labels_jsonl,
        tol=float(args.integrity_tol),
        max_examples=max(1, int(args.max_example_errors)),
    )

    freeze_ready = (
        total_input_rows > 0
        and missing_rows == 0
        and len(overlap_ids) == 0
        and len(systemic_buckets) == 0
        and integrity_stats.failure_count() == 0
    )

    manifest_mismatch_reasons: list[str] = []
    if manifest_data is not None:
        m_total = int(manifest_stats.get("total_input_rows", 0) or 0)
        m_attempted = int(manifest_stats.get("attempted", 0) or 0)
        m_succeeded = int(manifest_stats.get("succeeded", 0) or 0)
        m_failed = int(manifest_stats.get("failed", 0) or 0)
        if m_total and m_total != total_input_rows:
            manifest_mismatch_reasons.append(f"manifest_total_mismatch={m_total}!={total_input_rows}")
        if m_succeeded != len(success_ids):
            manifest_mismatch_reasons.append(f"manifest_succeeded_mismatch={m_succeeded}!={len(success_ids)}")
        if m_failed != len(error_ids):
            manifest_mismatch_reasons.append(f"manifest_failed_mismatch={m_failed}!={len(error_ids)}")
        if m_attempted != (len(success_ids) + len(error_ids)):
            manifest_mismatch_reasons.append(
                f"manifest_attempted_mismatch={m_attempted}!={len(success_ids) + len(error_ids)}"
            )
    if manifest_mismatch_reasons:
        freeze_ready = False

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "inputs": {
            "input_jsonl": str(input_jsonl),
            "labels_jsonl": str(labels_jsonl),
            "errors_jsonl": str(errors_jsonl),
            "total_input_rows": total_input_rows,
            "labeled_rows_unique": len(success_ids),
            "error_rows_unique": len(error_ids),
            "overlap_rows": len(overlap_ids),
            "missing_rows": missing_rows,
        },
        "thresholds": {
            "integrity_tol": float(args.integrity_tol),
            "min_bucket_samples": min_samples,
            "watch_fail_rate": float(args.watch_fail_rate),
            "systemic_fail_rate": float(args.systemic_fail_rate),
        },
        "manifest_sync": {
            "manifest_json": str(manifest_json),
            "manifest_present": manifest_data is not None,
            "manifest_stats": manifest_stats if manifest_data is not None else {},
            "mismatch_reasons": manifest_mismatch_reasons,
        },
        "bucket_summary": bucket_summary,
        "bucket_totals": {
            "bucket_count": len(bucket_summary),
            "systemic_bucket_count": len(systemic_buckets),
            "watch_bucket_count": len(watch_buckets),
        },
        "integrity": {
            "rows_checked": integrity_stats.rows_checked,
            "bad_json_lines": integrity_stats.bad_json_lines,
            "missing_row_id": integrity_stats.missing_row_id,
            "missing_reference": integrity_stats.missing_reference,
            "missing_root_actions": integrity_stats.missing_root_actions,
            "invalid_action_item": integrity_stats.invalid_action_item,
            "invalid_frequency": integrity_stats.invalid_frequency,
            "frequency_sum_mismatch": integrity_stats.frequency_sum_mismatch,
            "selected_action_missing_in_distribution": integrity_stats.selected_action_missing_in_distribution,
            "selected_action_not_present": integrity_stats.selected_action_not_present,
            "failure_count": integrity_stats.failure_count(),
            "examples": integrity_examples,
        },
        "verdict": {
            "freeze_ready": freeze_ready,
            "reasons": [
                *([] if missing_rows == 0 else [f"missing_rows={missing_rows}"]),
                *([] if len(overlap_ids) == 0 else [f"overlap_rows={len(overlap_ids)}"]),
                *([] if len(systemic_buckets) == 0 else [f"systemic_buckets={len(systemic_buckets)}"]),
                *([] if integrity_stats.failure_count() == 0 else [f"integrity_failures={integrity_stats.failure_count()}"]),
                *manifest_mismatch_reasons,
            ],
        },
    }

    unresolved_counter: dict[str, int] = {}
    if input_jsonl.exists() and error_ids:
        with input_jsonl.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                row_id = str(row.get("row_id") or "").strip()
                if not row_id or row_id not in error_ids:
                    continue
                gate_id = _unresolved_gate_id_from_row(row)
                if gate_id:
                    unresolved_counter[gate_id] = int(unresolved_counter.get(gate_id, 0)) + 1

    unresolved_payload = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_report": str(report_json),
        "inputs": {
            "input_jsonl": str(input_jsonl),
            "labels_jsonl": str(labels_jsonl),
            "errors_jsonl": str(errors_jsonl),
            "error_row_count": len(error_ids),
        },
        "unresolved_gate_ids": sorted(unresolved_counter.keys()),
        "counts_by_gate_id": dict(sorted(unresolved_counter.items(), key=lambda kv: kv[1], reverse=True)),
    }
    unresolved_gate_json.parent.mkdir(parents=True, exist_ok=True)
    unresolved_gate_json.write_text(json.dumps(unresolved_payload, indent=2), encoding="utf-8")
    report["unresolved_export"] = {
        "path": str(unresolved_gate_json),
        "gate_id_count": len(unresolved_counter),
        "top_gate_ids": [
            {"gate_id": gate_id, "count": count}
            for gate_id, count in list(sorted(unresolved_counter.items(), key=lambda kv: kv[1], reverse=True))[:10]
        ],
    }

    report_json.parent.mkdir(parents=True, exist_ok=True)
    report_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))

    if args.strict and not freeze_ready:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
