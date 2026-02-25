#!/usr/bin/env python
"""Tag spots into rollout classes for controlled multi-node experiments."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional


CLASS_1 = "turn_probe_punish"
CLASS_2 = "river_bigbet_overfold_punish"
CLASS_3 = "river_underbluff_defense"


def _detect_street(spot: Dict[str, Any]) -> str:
    board = spot.get("board", [])
    if isinstance(board, list):
        if len(board) == 4:
            return "turn"
        if len(board) >= 5:
            return "river"
    return "flop"


def _resolve_spots(manifest_path: Optional[Path], spot_dir: Optional[Path]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    if manifest_path:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(payload, list):
            raise SystemExit("manifest must be a JSON array.")
        for row in payload:
            if not isinstance(row, dict):
                continue
            p = row.get("spot_path")
            if not p:
                continue
            candidate = Path(str(p))
            if not candidate.is_absolute():
                candidate = (manifest_path.parent / candidate).resolve()
            rows.append({"spot_path": candidate, "manifest_row": dict(row)})
        return rows

    if not spot_dir:
        raise SystemExit("Provide either --manifest or --spot-dir.")
    for p in sorted(spot_dir.glob("*.json")):
        rows.append({"spot_path": p.resolve(), "manifest_row": {"spot_path": str(p)}})
    return rows


def _num(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _tag_spot(
    spot: Dict[str, Any],
    *,
    turn_probe_min: float,
    turn_probe_min_opp: int,
    river_bigbet_fold_min: float,
    river_bigbet_min_opp: int,
    river_bluff_rate_max: float,
    river_underbluff_min_opp: int,
) -> Dict[str, Any]:
    street = _detect_street(spot)
    meta = spot.get("meta", {})
    profile = meta.get("opponent_profile", {}) if isinstance(meta, dict) else {}
    if not isinstance(profile, dict):
        profile = {}

    fold_turn = _num(profile.get("fold_to_turn_probe"))
    turn_probe_opp = int(profile.get("turn_probe_opportunities", 0) or 0)
    fold_river_bigbet = _num(profile.get("fold_to_river_bigbet"))
    river_bigbet_opp = int(profile.get("river_bigbet_opportunities", 0) or 0)
    river_bluff_rate = _num(profile.get("river_bluff_rate"))

    c1 = (
        street == "turn"
        and fold_turn is not None
        and fold_turn >= turn_probe_min
        and turn_probe_opp >= turn_probe_min_opp
    )
    c2 = (
        street == "river"
        and fold_river_bigbet is not None
        and fold_river_bigbet >= river_bigbet_fold_min
        and river_bigbet_opp >= river_bigbet_min_opp
    )
    c3 = (
        street == "river"
        and river_bluff_rate is not None
        and river_bluff_rate <= river_bluff_rate_max
        and river_bigbet_opp >= river_underbluff_min_opp
    )

    reasons: List[str] = []
    if c1:
        reasons.append(
            f"{CLASS_1}: fold_to_turn_probe={fold_turn:.3f} >= {turn_probe_min:.3f}, opp={turn_probe_opp}"
        )
    if c2:
        reasons.append(
            f"{CLASS_2}: fold_to_river_bigbet={fold_river_bigbet:.3f} >= {river_bigbet_fold_min:.3f}, opp={river_bigbet_opp}"
        )
    if c3:
        reasons.append(
            f"{CLASS_3}: river_bluff_rate={river_bluff_rate:.3f} <= {river_bluff_rate_max:.3f}, opp={river_bigbet_opp}"
        )

    return {
        "street": street,
        "classes": {
            CLASS_1: bool(c1),
            CLASS_2: bool(c2),
            CLASS_3: bool(c3),
        },
        "metrics": {
            "fold_to_turn_probe": fold_turn,
            "turn_probe_opportunities": turn_probe_opp,
            "fold_to_river_bigbet": fold_river_bigbet,
            "river_bigbet_opportunities": river_bigbet_opp,
            "river_bluff_rate": river_bluff_rate,
        },
        "reasons": reasons,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Tag spots into rollout classes.")
    parser.add_argument("--manifest", help="Canonical manifest JSON file.")
    parser.add_argument("--spot-dir", help="Directory with spot JSON files.")
    parser.add_argument("--output-manifest", required=True, help="Path to write tagged manifest JSON.")
    parser.add_argument("--summary", required=True, help="Path to write tagging summary JSON.")
    parser.add_argument(
        "--write-spot-meta",
        action="store_true",
        help="Write class tags back into spot.meta.rollout_classes.",
    )
    parser.add_argument("--turn-probe-min", type=float, default=0.58)
    parser.add_argument("--turn-probe-min-opp", type=int, default=20)
    parser.add_argument("--river-bigbet-fold-min", type=float, default=0.55)
    parser.add_argument("--river-bigbet-min-opp", type=int, default=20)
    parser.add_argument("--river-bluff-rate-max", type=float, default=0.35)
    parser.add_argument("--river-underbluff-min-opp", type=int, default=20)
    args = parser.parse_args()

    manifest_path = Path(args.manifest).resolve() if args.manifest else None
    spot_dir = Path(args.spot_dir).resolve() if args.spot_dir else None
    entries = _resolve_spots(manifest_path, spot_dir)
    if not entries:
        raise SystemExit("No spots found to tag.")

    tagged_rows: List[Dict[str, Any]] = []
    class_counts = Counter()
    street_counts = Counter()
    profile_missing = 0
    error_count = 0

    for entry in entries:
        spot_path = Path(entry["spot_path"])
        row = dict(entry["manifest_row"])
        row["spot_path"] = str(spot_path)
        try:
            spot = json.loads(spot_path.read_text(encoding="utf-8"))
        except Exception as exc:  # pylint: disable=broad-except
            row["tagging_error"] = str(exc)
            tagged_rows.append(row)
            error_count += 1
            continue

        tags = _tag_spot(
            spot,
            turn_probe_min=args.turn_probe_min,
            turn_probe_min_opp=args.turn_probe_min_opp,
            river_bigbet_fold_min=args.river_bigbet_fold_min,
            river_bigbet_min_opp=args.river_bigbet_min_opp,
            river_bluff_rate_max=args.river_bluff_rate_max,
            river_underbluff_min_opp=args.river_underbluff_min_opp,
        )
        row.update(tags)
        tagged_rows.append(row)
        street_counts[tags["street"]] += 1

        if all(v is None or v == 0 for v in tags["metrics"].values()):
            profile_missing += 1
        for class_name, enabled in tags["classes"].items():
            if enabled:
                class_counts[class_name] += 1

        if args.write_spot_meta:
            spot.setdefault("meta", {})
            if isinstance(spot["meta"], dict):
                spot["meta"]["rollout_classes"] = tags["classes"]
                spot["meta"]["rollout_class_reasons"] = tags["reasons"]
            spot_path.write_text(json.dumps(spot, indent=2) + "\n", encoding="utf-8")

    output_manifest = Path(args.output_manifest).resolve()
    output_manifest.parent.mkdir(parents=True, exist_ok=True)
    output_manifest.write_text(json.dumps(tagged_rows, indent=2) + "\n", encoding="utf-8")

    summary = {
        "spots_total": len(tagged_rows),
        "error_count": error_count,
        "profile_missing_count": profile_missing,
        "street_counts": dict(street_counts),
        "class_counts": {
            CLASS_1: class_counts.get(CLASS_1, 0),
            CLASS_2: class_counts.get(CLASS_2, 0),
            CLASS_3: class_counts.get(CLASS_3, 0),
        },
        "thresholds": {
            "turn_probe_min": args.turn_probe_min,
            "turn_probe_min_opp": args.turn_probe_min_opp,
            "river_bigbet_fold_min": args.river_bigbet_fold_min,
            "river_bigbet_min_opp": args.river_bigbet_min_opp,
            "river_bluff_rate_max": args.river_bluff_rate_max,
            "river_underbluff_min_opp": args.river_underbluff_min_opp,
        },
        "manifest": str(manifest_path) if manifest_path else None,
        "spot_dir": str(spot_dir) if spot_dir else None,
        "output_manifest": str(output_manifest),
        "write_spot_meta": bool(args.write_spot_meta),
    }

    summary_path = Path(args.summary).resolve()
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

