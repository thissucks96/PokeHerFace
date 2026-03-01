#!/usr/bin/env python3
"""Build local neural teacher rows from bridge payload/response artifacts.

Default behavior is analysis-only (no file writes). Use --write to materialize
JSONL rows for training.
"""

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


def _normalize_action_token(raw: Any) -> str:
    token = str(raw or "").strip().lower()
    if not token:
        return ""
    if token == "all_in":
        return "all_in"
    if token.startswith("bet:"):
        token = "raise:" + token.split(":", 1)[1]
    if token == "bet":
        return "raise"
    return token


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


def _iter_response_paths(response_dir: Path, max_files: int) -> list[Path]:
    paths = sorted(response_dir.glob("*_response_*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    if max_files > 0:
        return paths[:max_files]
    return paths


def _payload_path_for_response(path: Path) -> Path:
    return path.with_name(path.name.replace("_response_", "_payload_"))


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if isinstance(payload, dict):
        return payload
    return None


def _pick_target_action(response_payload: dict[str, Any]) -> tuple[str, float | None]:
    # Priority 1: neural shadow selected action if available
    neural = response_payload.get("neural_shadow")
    if isinstance(neural, dict):
        chosen = _normalize_action_token(neural.get("selected_action") or neural.get("neural_chosen_action"))
        if chosen:
            return chosen, None

    result = response_payload.get("result")
    if not isinstance(result, dict):
        return "", None

    # Priority 2: decision action (if present)
    decision = result.get("decision")
    if isinstance(decision, dict):
        action = _normalize_action_token(decision.get("action"))
        amount = decision.get("amount")
        if action:
            if action.startswith("raise") and amount is not None:
                return f"raise:{_safe_int(amount, 0)}", float(_safe_float(amount, 0.0))
            return action, None

    # Priority 3: top root action
    root_actions = result.get("root_actions")
    if isinstance(root_actions, list) and root_actions:
        best_action = ""
        best_freq = -1.0
        best_amount = None
        for item in root_actions:
            if not isinstance(item, dict):
                continue
            action = _normalize_action_token(item.get("action"))
            freq = _safe_float(item.get("avg_frequency", item.get("frequency", 0.0)), 0.0)
            amount = item.get("amount")
            if action and freq > best_freq:
                best_action = action
                best_freq = freq
                best_amount = amount
        if best_action:
            if best_action == "raise" and best_amount is not None:
                return f"raise:{_safe_int(best_amount, 0)}", float(_safe_float(best_amount, 0.0))
            return best_action, None

    return "", None


def _extract_target_distribution(response_payload: dict[str, Any]) -> list[dict[str, Any]]:
    result = response_payload.get("result")
    if not isinstance(result, dict):
        return []
    root_actions = result.get("root_actions")
    if not isinstance(root_actions, list):
        return []
    out: list[dict[str, Any]] = []
    for item in root_actions:
        if not isinstance(item, dict):
            continue
        action = _normalize_action_token(item.get("action"))
        if not action:
            continue
        freq = _safe_float(item.get("avg_frequency", item.get("frequency", 0.0)), 0.0)
        amount = item.get("amount")
        row: dict[str, Any] = {"action": action, "frequency": freq}
        if amount is not None:
            row["amount"] = _safe_float(amount, 0.0)
        out.append(row)
    return out


def _build_row(stage: str, payload: dict[str, Any], response: dict[str, Any], response_path: Path) -> dict[str, Any] | None:
    spot = payload.get("spot")
    if not isinstance(spot, dict):
        return None
    meta = spot.get("meta") if isinstance(spot.get("meta"), dict) else {}
    board = spot.get("board") if isinstance(spot.get("board"), list) else []
    street = _detect_street(board)
    runtime_profile = str(payload.get("runtime_profile") or "").strip().lower()
    if not runtime_profile:
        metrics = response.get("metrics") if isinstance(response.get("metrics"), dict) else {}
        runtime_profile = str(metrics.get("runtime_profile") or "unknown").strip().lower()

    chosen_action, chosen_amount = _pick_target_action(response)
    if not chosen_action:
        return None

    row = {
        "schema_version": 1,
        "source": {
            "response_path": str(response_path.resolve()),
            "stage": stage,
            "runtime_profile": runtime_profile,
            "street": street,
            "selected_strategy": str(response.get("selected_strategy") or ""),
            "selection_reason": str(response.get("selection_reason") or ""),
        },
        "features": {
            "hero_range": str(spot.get("hero_range") or ""),
            "villain_range": str(spot.get("villain_range") or ""),
            "board": board,
            "active_node_path": str(spot.get("active_node_path") or ""),
            "in_position_player": _safe_int(spot.get("in_position_player"), 2),
            "starting_stack": _safe_int(spot.get("starting_stack"), 0),
            "starting_pot": _safe_int(spot.get("starting_pot"), 0),
            "minimum_bet": _safe_int(spot.get("minimum_bet"), 0),
            "all_in_threshold": _safe_float(spot.get("all_in_threshold"), 0.67),
            "iterations": _safe_int(spot.get("iterations"), 0),
            "thread_count": _safe_int(spot.get("thread_count"), 0),
            "raise_cap": _safe_int(spot.get("raise_cap"), 0),
            "facing_bet": _safe_int(meta.get("facing_bet"), 0),
            "hero_street_commit": _safe_int(meta.get("hero_street_commit"), 0),
            "villain_street_commit": _safe_int(meta.get("villain_street_commit"), 0),
            "current_pot": _safe_int(meta.get("current_pot", spot.get("starting_pot")), 0),
            "hero_chips": _safe_int(meta.get("current_hero_chips"), 0),
            "villain_chips": _safe_int(meta.get("current_villain_chips"), 0),
            "hero_is_small_blind": bool(meta.get("hero_is_small_blind", True)),
            "hero_cards": meta.get("hero_cards") if isinstance(meta.get("hero_cards"), list) else [],
        },
        "target": {
            "selected_action": chosen_action,
            "selected_amount": chosen_amount,
            "distribution": _extract_target_distribution(response),
        },
    }
    return row


def build_rows(
    response_dir: Path,
    runtime_profiles: set[str],
    streets: set[str],
    max_files: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    scanned = 0
    matched_pairs = 0
    skipped_invalid = 0
    skipped_filter = 0

    for response_path in _iter_response_paths(response_dir, max_files=max_files):
        scanned += 1
        payload_path = _payload_path_for_response(response_path)
        payload = _load_json(payload_path)
        response = _load_json(response_path)
        if not payload or not response:
            skipped_invalid += 1
            continue
        if str(response.get("status", "")).lower() != "ok":
            skipped_invalid += 1
            continue
        matched_pairs += 1
        stage = response_path.name.split("_response_", 1)[0]
        row = _build_row(stage=stage, payload=payload, response=response, response_path=response_path)
        if row is None:
            skipped_invalid += 1
            continue
        profile = row["source"]["runtime_profile"]
        street = row["source"]["street"]
        if runtime_profiles and profile not in runtime_profiles:
            skipped_filter += 1
            continue
        if streets and street not in streets:
            skipped_filter += 1
            continue
        rows.append(row)

    summary = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "response_dir": str(response_dir.resolve()),
        "scanned_response_files": scanned,
        "matched_payload_response_pairs": matched_pairs,
        "rows_ready": len(rows),
        "skipped_invalid": skipped_invalid,
        "skipped_by_filter": skipped_filter,
    }
    return rows, summary


def _parse_csv_set(raw: str) -> set[str]:
    values = {chunk.strip().lower() for chunk in str(raw or "").split(",") if chunk.strip()}
    return {v for v in values if v}


def main() -> int:
    parser = argparse.ArgumentParser(description="Build local neural teacher rows from bridge artifacts.")
    parser.add_argument(
        "--response-dir",
        type=Path,
        default=Path("5_Vision_Extraction/out/flop_engine"),
        help="Directory containing *_response_*.json and *_payload_*.json artifacts.",
    )
    parser.add_argument(
        "--output-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl"),
        help="Output JSONL path (written only when --write is set).",
    )
    parser.add_argument(
        "--summary-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/dataset_build_summary.json"),
        help="Summary report path (written only when --write is set).",
    )
    parser.add_argument("--max-files", type=int, default=0, help="Limit newest response files scanned (0 = all).")
    parser.add_argument(
        "--runtime-profiles",
        type=str,
        default="",
        help="Optional comma-separated filter (example: fast_live,normal).",
    )
    parser.add_argument(
        "--streets",
        type=str,
        default="",
        help="Optional comma-separated street filter (preflop,flop,turn,river).",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Write dataset JSONL and summary JSON. Default is analysis-only.",
    )
    args = parser.parse_args()

    runtime_profiles = _parse_csv_set(args.runtime_profiles)
    streets = _parse_csv_set(args.streets)

    rows, summary = build_rows(
        response_dir=args.response_dir,
        runtime_profiles=runtime_profiles,
        streets=streets,
        max_files=max(0, int(args.max_files)),
    )

    print(json.dumps(summary, indent=2))
    if rows:
        preview = {
            "preview_row": {
                "source": rows[0]["source"],
                "target": rows[0]["target"],
            }
        }
        print(json.dumps(preview, indent=2))

    if args.write:
        output_jsonl = args.output_jsonl.resolve()
        summary_json = args.summary_json.resolve()
        output_jsonl.parent.mkdir(parents=True, exist_ok=True)
        summary_json.parent.mkdir(parents=True, exist_ok=True)
        with output_jsonl.open("w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row))
                f.write("\n")
        summary_enriched = dict(summary)
        summary_enriched["output_jsonl"] = str(output_jsonl)
        summary_enriched["summary_json"] = str(summary_json)
        summary_json.write_text(json.dumps(summary_enriched, indent=2), encoding="utf-8")
        print(f"wrote_jsonl={output_jsonl}")
        print(f"wrote_summary={summary_json}")
    else:
        print("analysis_only=true (no dataset files written; pass --write to materialize)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
