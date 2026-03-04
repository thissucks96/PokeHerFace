#!/usr/bin/env python3
"""Parity check: offline row feature encoding vs live-spot feature encoding.

This validates that the shared feature contract produces identical hashes for:
1) row[source,features]
2) reconstructed live spot -> source/features via source_features_from_spot()
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from shared_feature_contract import (
    FEATURE_CONTRACT_HASH,
    FEATURE_DEFAULT_INPUT_DIM,
    FEATURE_SCHEMA_VERSION,
    feature_contract_metadata,
    source_features_from_spot,
)


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


def _iter_rows(path: Path):
    if not path.exists():
        return
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                yield payload


def _extract_source_features(row: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    if isinstance(row.get("source"), dict) and isinstance(row.get("features"), dict):
        return row.get("source", {}), row.get("features", {})
    source_row = row.get("source_row") if isinstance(row.get("source_row"), dict) else {}
    source = source_row.get("source") if isinstance(source_row.get("source"), dict) else {}
    features = source_row.get("features") if isinstance(source_row.get("features"), dict) else {}
    return source, features


def _spot_from_features(features: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "hero_range": str(features.get("hero_range") or ""),
        "villain_range": str(features.get("villain_range") or ""),
        "board": features.get("board") if isinstance(features.get("board"), list) else [],
        "in_position_player": _safe_int(features.get("in_position_player"), 2),
        "starting_stack": _safe_int(features.get("starting_stack"), 0),
        "starting_pot": _safe_int(features.get("starting_pot"), 0),
        "minimum_bet": _safe_int(features.get("minimum_bet"), 0),
        "all_in_threshold": _safe_float(features.get("all_in_threshold"), 0.67),
        "iterations": _safe_int(features.get("iterations"), 0),
        "min_exploitability": _safe_float(features.get("min_exploitability"), -1.0),
        "thread_count": _safe_int(features.get("thread_count"), 0),
        "remove_donk_bets": bool(features.get("remove_donk_bets", True)),
        "raise_cap": _safe_int(features.get("raise_cap"), 0),
        "compress_strategy": bool(features.get("compress_strategy", True)),
        "bet_sizing": features.get("bet_sizing") if isinstance(features.get("bet_sizing"), dict) else {},
        "active_node_path": str(features.get("active_node_path") or ""),
        "facing_bet": _safe_int(features.get("facing_bet"), 0),
        "hero_street_commit": _safe_int(features.get("hero_street_commit"), 0),
        "villain_street_commit": _safe_int(features.get("villain_street_commit"), 0),
        "current_pot": _safe_int(features.get("current_pot", features.get("starting_pot")), 0),
        "hero_chips": _safe_int(features.get("hero_chips"), 0),
        "villain_chips": _safe_int(features.get("villain_chips"), 0),
        "hero_is_small_blind": bool(features.get("hero_is_small_blind", True)),
        "meta": {
            "hero_cards": features.get("hero_cards") if isinstance(features.get("hero_cards"), list) else [],
            "facing_bet": _safe_int(features.get("facing_bet"), 0),
            "hero_street_commit": _safe_int(features.get("hero_street_commit"), 0),
            "villain_street_commit": _safe_int(features.get("villain_street_commit"), 0),
            "current_pot": _safe_int(features.get("current_pot", features.get("starting_pot")), 0),
            "current_hero_chips": _safe_int(features.get("hero_chips"), 0),
            "current_villain_chips": _safe_int(features.get("villain_chips"), 0),
            "hero_is_small_blind": bool(features.get("hero_is_small_blind", True)),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate feature contract parity for offline rows.")
    parser.add_argument(
        "--input-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_teacher_rows.jsonl"),
        help="Input JSONL (teacher rows or reference-labeled rows).",
    )
    parser.add_argument("--max-rows", type=int, default=0, help="Max rows to check (0 = all).")
    parser.add_argument("--input-dim", type=int, default=FEATURE_DEFAULT_INPUT_DIM, help="Feature vector input dimension.")
    parser.add_argument(
        "--report-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/feature_contract_parity_report.json"),
        help="Output report path.",
    )
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on any mismatch.")
    args = parser.parse_args()

    rows_checked = 0
    skipped_rows = 0
    contract_rows_present = 0
    contract_rows_matching = 0
    contract_rows_mismatching = 0
    parity_key_mismatch = 0
    parity_vector_mismatch = 0
    examples: list[dict[str, Any]] = []

    for row in _iter_rows(args.input_jsonl.resolve()):
        if args.max_rows > 0 and rows_checked >= int(args.max_rows):
            break
        source, features = _extract_source_features(row)
        if not source or not features:
            skipped_rows += 1
            continue
        rows_checked += 1

        row_meta = feature_contract_metadata(source=source, features=features, input_dim=args.input_dim)
        stored = row.get("feature_contract") if isinstance(row.get("feature_contract"), dict) else None
        if stored is None and isinstance(row.get("source_row"), dict):
            sr = row.get("source_row", {})
            maybe = sr.get("feature_contract")
            if isinstance(maybe, dict):
                stored = maybe
        if isinstance(stored, dict):
            contract_rows_present += 1
            schema_ok = str(stored.get("schema_version") or "") == FEATURE_SCHEMA_VERSION
            hash_ok = str(stored.get("contract_hash") or "") == FEATURE_CONTRACT_HASH
            key_ok = str(stored.get("feature_key_hash") or "") == str(row_meta.get("feature_key_hash") or "")
            if schema_ok and hash_ok and key_ok:
                contract_rows_matching += 1
            else:
                contract_rows_mismatching += 1

        spot = _spot_from_features(features)
        runtime_profile = str(source.get("runtime_profile") or "")
        spot_source, spot_features = source_features_from_spot(spot=spot, runtime_profile=runtime_profile, stage="bridge_live")
        spot_meta = feature_contract_metadata(source=spot_source, features=spot_features, input_dim=args.input_dim)

        key_match = str(row_meta.get("feature_key_hash") or "") == str(spot_meta.get("feature_key_hash") or "")
        vec_match = str(row_meta.get("vector_hash") or "") == str(spot_meta.get("vector_hash") or "")
        if not key_match:
            parity_key_mismatch += 1
        if not vec_match:
            parity_vector_mismatch += 1
        if (not key_match or not vec_match) and len(examples) < 20:
            examples.append(
                {
                    "row_id": str(row.get("row_id") or ""),
                    "source_street": str(source.get("street") or ""),
                    "spot_street": str(spot_source.get("street") or ""),
                    "row_key_hash": row_meta.get("feature_key_hash"),
                    "spot_key_hash": spot_meta.get("feature_key_hash"),
                    "row_vector_hash": row_meta.get("vector_hash"),
                    "spot_vector_hash": spot_meta.get("vector_hash"),
                }
            )

    mismatch_total = parity_key_mismatch + parity_vector_mismatch + contract_rows_mismatching
    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "input_jsonl": str(args.input_jsonl.resolve()),
        "feature_contract_expected": {
            "schema_version": FEATURE_SCHEMA_VERSION,
            "contract_hash": FEATURE_CONTRACT_HASH,
            "input_dim": int(args.input_dim),
        },
        "rows_checked": rows_checked,
        "rows_skipped": skipped_rows,
        "stored_contract_rows_present": contract_rows_present,
        "stored_contract_rows_matching": contract_rows_matching,
        "stored_contract_rows_mismatching": contract_rows_mismatching,
        "parity_key_mismatch": parity_key_mismatch,
        "parity_vector_mismatch": parity_vector_mismatch,
        "ok": mismatch_total == 0,
        "examples": examples,
    }
    report_path = args.report_json.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    if args.strict and mismatch_total > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
