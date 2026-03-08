#!/usr/bin/env python3
"""Build local neural teacher rows from bridge payload/response artifacts.

Default behavior is analysis-only (no file writes). Use --write to materialize
JSONL rows for training.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from shared_feature_contract import (
    FEATURE_CONTRACT_HASH,
    FEATURE_DEFAULT_INPUT_DIM,
    FEATURE_SCHEMA_VERSION,
    feature_contract_metadata,
)


DEFAULT_CONFIG = {
    "input": {
        "response_dir": "5_Vision_Extraction/out/flop_engine",
        "max_files": 0,
        "runtime_profiles": ["fast_live", "normal"],
        "streets": ["flop", "turn", "river"],
        "selected_strategies": ["baseline_gto", "fallback_lookup_policy"],
        "include_neural_applied": False,
        "include_surrogate": False,
        "min_board_cards": 3,
    },
    "output": {
        "rows_jsonl": "2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl",
        "summary_json": "2_Neural_Brain/local_pipeline/reports/dataset_build_summary.json",
    },
}

ACTION_BASES = {"fold", "check", "call", "raise", "all_in"}


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
    if token.startswith("bet:"):
        token = "raise:" + token.split(":", 1)[1]
    if token == "bet":
        return "raise"
    if token in {"all in", "allin", "all_in"}:
        return "all_in"
    return token


def _action_base(token: str) -> str:
    value = _normalize_action_token(token)
    if ":" in value:
        return value.split(":", 1)[0]
    return value


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


def _extract_last_bet_amount_from_active_node_path(active_node_path: str) -> int | None:
    path_value = str(active_node_path or "").strip().lower()
    if not path_value:
        return None
    for segment in reversed(path_value.split("/")):
        token = segment.strip()
        if ":bet:" not in token and ":raise:" not in token:
            continue
        try:
            return int(float(token.rsplit(":", 1)[1]))
        except (TypeError, ValueError):
            continue
    return None


def _extract_effective_facing_bet(meta: dict[str, Any], effective_spot: dict[str, Any]) -> int:
    facing = _safe_int(meta.get("facing_bet"), 0)
    if facing > 0:
        return facing
    active = str(effective_spot.get("active_node_path") or "").strip()
    return _safe_int(_extract_last_bet_amount_from_active_node_path(active), 0)


def _effective_stack_under_pressure(features: dict[str, Any]) -> float:
    hero_chips = _safe_float(features.get("hero_chips"), 0.0)
    villain_chips = _safe_float(features.get("villain_chips"), 0.0)
    if hero_chips > 0.0 and villain_chips > 0.0:
        return min(hero_chips, villain_chips)

    starting_stack = _safe_float(features.get("starting_stack"), 0.0)
    hero_commit = _safe_float(features.get("hero_street_commit"), 0.0)
    villain_commit = _safe_float(features.get("villain_street_commit"), 0.0)
    if starting_stack > 0.0:
        return min(
            max(0.0, starting_stack - hero_commit),
            max(0.0, starting_stack - villain_commit),
        )
    return 0.0


def _pot_odds(features: dict[str, Any]) -> float:
    facing_bet = max(0.0, _safe_float(features.get("facing_bet"), 0.0))
    current_pot = max(0.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 0.0))
    denom = current_pot + facing_bet
    if facing_bet <= 0.0 or denom <= 0.0:
        return 0.0
    return facing_bet / denom


def _spr_under_pressure(features: dict[str, Any]) -> float:
    facing_bet = max(0.0, _safe_float(features.get("facing_bet"), 0.0))
    current_pot = max(0.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 0.0))
    denom = current_pot + facing_bet
    if denom <= 0.0:
        return 0.0
    return _effective_stack_under_pressure(features) / denom


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


def _action_rows_from_result(result: dict[str, Any]) -> list[dict[str, Any]]:
    active_found = bool(result.get("active_node_found"))
    active_actions = result.get("active_node_actions")
    root_actions = result.get("root_actions")
    source = active_actions if active_found and isinstance(active_actions, list) and active_actions else root_actions
    if not isinstance(source, list):
        return []
    rows: list[dict[str, Any]] = []
    for item in source:
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
        rows.append(row)
    return rows


def _pick_target_action(result: dict[str, Any]) -> tuple[str, float | None]:
    decision = result.get("decision")
    if isinstance(decision, dict):
        action = _normalize_action_token(decision.get("action"))
        amount = decision.get("amount")
        if action:
            if _action_base(action) == "raise" and amount is not None:
                return f"raise:{_safe_int(amount, 0)}", _safe_float(amount, 0.0)
            return action, None

    rows = _action_rows_from_result(result)
    if not rows:
        return "", None
    best = max(rows, key=lambda r: _safe_float(r.get("frequency"), 0.0))
    action = _normalize_action_token(best.get("action"))
    amount = best.get("amount")
    if _action_base(action) == "raise" and amount is not None:
        return f"raise:{_safe_int(amount, 0)}", _safe_float(amount, 0.0)
    return action, None


def _extract_target_distribution(result: dict[str, Any]) -> list[dict[str, Any]]:
    return _action_rows_from_result(result)


def _row_split_key(source: dict[str, Any], features: dict[str, Any], target: dict[str, Any]) -> str:
    stable = {
        "runtime_profile": source.get("runtime_profile", ""),
        "street": source.get("street", ""),
        "selected_strategy": source.get("selected_strategy", ""),
        "hero_range": features.get("hero_range", ""),
        "villain_range": features.get("villain_range", ""),
        "board": features.get("board", []),
        "active_node_path": features.get("active_node_path", ""),
        "selected_action": target.get("selected_action", ""),
        "selected_amount": target.get("selected_amount"),
    }
    blob = json.dumps(stable, sort_keys=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _row_id(split_key: str, response_path: Path) -> str:
    blob = f"{split_key}|{response_path.name}"
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _load_builder_config(config_path: Path | None) -> dict[str, Any]:
    cfg: dict[str, Any] = json.loads(json.dumps(DEFAULT_CONFIG))
    if config_path and config_path.exists():
        incoming = _load_json(config_path)
        if isinstance(incoming, dict):
            for section in ("input", "output"):
                if isinstance(incoming.get(section), dict):
                    cfg[section].update(incoming[section])
    return cfg


def _parse_csv_set(raw: str) -> set[str]:
    values = {chunk.strip().lower() for chunk in str(raw or "").split(",") if chunk.strip()}
    return {v for v in values if v}


def _parse_list_set(raw: Any) -> set[str]:
    if not isinstance(raw, list):
        return set()
    return {str(item).strip().lower() for item in raw if str(item).strip()}


def _build_row(stage: str, payload: dict[str, Any], response: dict[str, Any], response_path: Path) -> dict[str, Any] | None:
    spot = payload.get("spot")
    if not isinstance(spot, dict):
        return None
    result = response.get("result")
    if not isinstance(result, dict):
        return None
    result_input = result.get("input")
    engine_input = result_input if isinstance(result_input, dict) else {}
    effective_spot = engine_input if engine_input else spot

    meta = spot.get("meta") if isinstance(spot.get("meta"), dict) else {}
    board = effective_spot.get("board") if isinstance(effective_spot.get("board"), list) else []
    street = _detect_street(board)
    runtime_profile = str(payload.get("runtime_profile") or "").strip().lower()
    if not runtime_profile:
        metrics = response.get("metrics") if isinstance(response.get("metrics"), dict) else {}
        runtime_profile = str(metrics.get("runtime_profile") or "unknown").strip().lower()

    chosen_action, chosen_amount = _pick_target_action(result)
    if not chosen_action or _action_base(chosen_action) not in ACTION_BASES:
        return None

    source = {
        "response_path": str(response_path.resolve()),
        "stage": stage,
        "runtime_profile": runtime_profile,
        "street": street,
        "selected_strategy": str(response.get("selected_strategy") or ""),
        "selection_reason": str(response.get("selection_reason") or ""),
    }
    features = {
        "hero_range": str(effective_spot.get("hero_range") or ""),
        "villain_range": str(effective_spot.get("villain_range") or ""),
        "board": board,
        "active_node_path": str(effective_spot.get("active_node_path") or ""),
        "in_position_player": _safe_int(effective_spot.get("in_position_player"), 2),
        "starting_stack": _safe_int(effective_spot.get("starting_stack"), 0),
        "starting_pot": _safe_int(effective_spot.get("starting_pot"), 0),
        "minimum_bet": _safe_int(effective_spot.get("minimum_bet"), 0),
        "all_in_threshold": _safe_float(effective_spot.get("all_in_threshold"), 0.67),
        "iterations": _safe_int(effective_spot.get("iterations"), 0),
        "min_exploitability": _safe_float(effective_spot.get("min_exploitability"), -1.0),
        "thread_count": _safe_int(effective_spot.get("thread_count"), 0),
        "remove_donk_bets": bool(effective_spot.get("remove_donk_bets", True)),
        "raise_cap": _safe_int(effective_spot.get("raise_cap"), 0),
        "compress_strategy": bool(effective_spot.get("compress_strategy", True)),
        "bet_sizing": effective_spot.get("bet_sizing") if isinstance(effective_spot.get("bet_sizing"), dict) else {},
        "facing_bet": _extract_effective_facing_bet(meta, effective_spot),
        "hero_street_commit": _safe_int(meta.get("hero_street_commit"), 0),
        "villain_street_commit": _safe_int(meta.get("villain_street_commit"), 0),
        "current_pot": _safe_int(meta.get("current_pot", effective_spot.get("starting_pot")), 0),
        "hero_chips": _safe_int(meta.get("current_hero_chips"), 0),
        "villain_chips": _safe_int(meta.get("current_villain_chips"), 0),
        "hero_is_small_blind": bool(meta.get("hero_is_small_blind", True)),
        "hero_cards": meta.get("hero_cards") if isinstance(meta.get("hero_cards"), list) else [],
        "engine_input_applied": bool(engine_input),
    }
    features["pot_odds"] = _pot_odds(features)
    features["spr_under_pressure"] = _spr_under_pressure(features)
    target = {
        "selected_action": chosen_action,
        "selected_amount": chosen_amount,
        "distribution": _extract_target_distribution(result),
    }
    contract = feature_contract_metadata(
        source=source,
        features=features,
        input_dim=FEATURE_DEFAULT_INPUT_DIM,
    )
    split_key = _row_split_key(source=source, features=features, target=target)
    return {
        "schema_version": 1,
        "row_id": _row_id(split_key=split_key, response_path=response_path),
        "split_key": split_key,
        "source": source,
        "features": features,
        "target": target,
        "feature_contract": contract,
    }


def build_rows(
    response_dir: Path,
    runtime_profiles: set[str],
    streets: set[str],
    selected_strategies: set[str],
    include_neural_applied: bool,
    include_surrogate: bool,
    min_board_cards: int,
    max_files: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    scanned = 0
    matched_pairs = 0
    skipped_invalid = 0
    skipped_filter = 0
    action_counter: Counter[str] = Counter()
    by_street: dict[str, Counter[str]] = defaultdict(Counter)
    by_profile: dict[str, Counter[str]] = defaultdict(Counter)

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

        source = row["source"]
        features = row["features"]
        profile = str(source.get("runtime_profile", "")).lower()
        street = str(source.get("street", "")).lower()
        selected_strategy = str(source.get("selected_strategy", "")).lower()
        board = features.get("board") if isinstance(features.get("board"), list) else []

        metrics = response.get("metrics") if isinstance(response.get("metrics"), dict) else {}
        neural_shadow = response.get("neural_shadow") if isinstance(response.get("neural_shadow"), dict) else {}
        neural_applied = bool(metrics.get("neural_applied")) or bool(neural_shadow.get("applied"))
        surrogate = bool(neural_shadow.get("neural_surrogate"))

        if runtime_profiles and profile not in runtime_profiles:
            skipped_filter += 1
            continue
        if streets and street not in streets:
            skipped_filter += 1
            continue
        if selected_strategies and selected_strategy not in selected_strategies:
            skipped_filter += 1
            continue
        if len(board) < max(0, min_board_cards):
            skipped_filter += 1
            continue
        if not include_neural_applied and neural_applied:
            skipped_filter += 1
            continue
        if not include_surrogate and surrogate:
            skipped_filter += 1
            continue

        action = str(row["target"]["selected_action"])
        action_base = _action_base(action)
        action_counter[action_base] += 1
        by_street[street][action_base] += 1
        by_profile[profile][action_base] += 1
        rows.append(row)

    summary = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "response_dir": str(response_dir.resolve()),
        "feature_contract": {
            "schema_version": FEATURE_SCHEMA_VERSION,
            "contract_hash": FEATURE_CONTRACT_HASH,
            "default_input_dim": FEATURE_DEFAULT_INPUT_DIM,
        },
        "scanned_response_files": scanned,
        "matched_payload_response_pairs": matched_pairs,
        "rows_ready": len(rows),
        "skipped_invalid": skipped_invalid,
        "skipped_by_filter": skipped_filter,
        "class_balance": dict(action_counter),
        "class_balance_by_street": {k: dict(v) for k, v in by_street.items()},
        "class_balance_by_runtime_profile": {k: dict(v) for k, v in by_profile.items()},
        "filters": {
            "runtime_profiles": sorted(runtime_profiles),
            "streets": sorted(streets),
            "selected_strategies": sorted(selected_strategies),
            "include_neural_applied": include_neural_applied,
            "include_surrogate": include_surrogate,
            "min_board_cards": min_board_cards,
        },
    }
    return rows, summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Build local neural teacher rows from bridge artifacts.")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/configs/dataset_config.local.json"),
        help="Dataset config JSON (local or template).",
    )
    parser.add_argument(
        "--response-dir",
        type=Path,
        default=None,
        help="Override response artifact directory.",
    )
    parser.add_argument(
        "--output-jsonl",
        type=Path,
        default=None,
        help="Override output JSONL path.",
    )
    parser.add_argument(
        "--summary-json",
        type=Path,
        default=None,
        help="Override summary report JSON path.",
    )
    parser.add_argument("--max-files", type=int, default=-1, help="Override newest response files scanned (-1 = config).")
    parser.add_argument("--runtime-profiles", type=str, default="", help="CSV override for runtime profile filter.")
    parser.add_argument("--streets", type=str, default="", help="CSV override for street filter.")
    parser.add_argument("--selected-strategies", type=str, default="", help="CSV override for selected_strategy filter.")
    parser.add_argument("--include-neural-applied", action="store_true", help="Include rows where neural applied=true.")
    parser.add_argument("--include-surrogate", action="store_true", help="Include rows marked neural_surrogate=true.")
    parser.add_argument("--min-board-cards", type=int, default=-1, help="Override minimum board card count.")
    parser.add_argument("--write", action="store_true", help="Write dataset JSONL and summary JSON.")
    args = parser.parse_args()

    cfg = _load_builder_config(args.config.resolve() if args.config else None)
    input_cfg = cfg["input"]
    output_cfg = cfg["output"]

    response_dir = args.response_dir.resolve() if isinstance(args.response_dir, Path) else Path(str(input_cfg["response_dir"])).resolve()
    output_jsonl = args.output_jsonl.resolve() if isinstance(args.output_jsonl, Path) else Path(str(output_cfg["rows_jsonl"])).resolve()
    summary_json = args.summary_json.resolve() if isinstance(args.summary_json, Path) else Path(str(output_cfg["summary_json"])).resolve()

    runtime_profiles = _parse_csv_set(args.runtime_profiles) if args.runtime_profiles else _parse_list_set(input_cfg.get("runtime_profiles", []))
    streets = _parse_csv_set(args.streets) if args.streets else _parse_list_set(input_cfg.get("streets", []))
    selected_strategies = (
        _parse_csv_set(args.selected_strategies)
        if args.selected_strategies
        else _parse_list_set(input_cfg.get("selected_strategies", []))
    )

    max_files = int(input_cfg.get("max_files", 0)) if args.max_files < 0 else max(0, int(args.max_files))
    include_neural_applied = bool(input_cfg.get("include_neural_applied", False)) or bool(args.include_neural_applied)
    include_surrogate = bool(input_cfg.get("include_surrogate", False)) or bool(args.include_surrogate)
    min_board_cards = int(input_cfg.get("min_board_cards", 0)) if args.min_board_cards < 0 else max(0, int(args.min_board_cards))

    rows, summary = build_rows(
        response_dir=response_dir,
        runtime_profiles=runtime_profiles,
        streets=streets,
        selected_strategies=selected_strategies,
        include_neural_applied=include_neural_applied,
        include_surrogate=include_surrogate,
        min_board_cards=min_board_cards,
        max_files=max_files,
    )

    print(json.dumps(summary, indent=2))
    if rows:
        preview = {"preview_row": {"source": rows[0]["source"], "target": rows[0]["target"]}}
        print(json.dumps(preview, indent=2))

    if args.write:
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
