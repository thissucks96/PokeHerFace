#!/usr/bin/env python
"""Build a deterministic canonical turn-spot pack for acceptance benchmarking."""

from __future__ import annotations

import argparse
import json
import random
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List


TARGET_TEXTURES = ("paired", "rainbow", "two_tone", "monotone")


def _load_spot(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _detect_street(spot: Dict[str, Any]) -> str:
    board = spot.get("board", [])
    if isinstance(board, list):
        if len(board) == 4:
            return "turn"
        if len(board) >= 5:
            return "river"
    return "flop"


def _texture_of(spot: Dict[str, Any]) -> str:
    meta = spot.get("meta", {})
    if isinstance(meta, dict):
        texture = str(meta.get("texture", "")).strip().lower()
        if texture:
            return texture
    return "unknown"


def _depth_of(spot: Dict[str, Any]) -> str:
    meta = spot.get("meta", {})
    if isinstance(meta, dict):
        depth = str(meta.get("depth", "")).strip().lower()
        if depth:
            return depth
    return "unknown"


def _position_of(spot: Dict[str, Any]) -> str:
    meta = spot.get("meta", {})
    if isinstance(meta, dict):
        position = str(meta.get("position", "")).strip().lower()
        if position:
            return position
    return "unknown"


def _stack_bucket(spot: Dict[str, Any]) -> str:
    stack = spot.get("starting_stack")
    pot = spot.get("starting_pot")
    if not isinstance(stack, (int, float)) or not isinstance(pot, (int, float)) or pot <= 0:
        return "unknown"
    spr = float(stack) / float(pot)
    if spr < 8.0:
        return "shallow"
    if spr < 25.0:
        return "medium"
    return "deep"


def _allocate_targets(total: int, counts: Dict[str, int]) -> Dict[str, int]:
    targets: Dict[str, int] = {}
    eligible = [t for t in TARGET_TEXTURES if counts.get(t, 0) > 0]
    if not eligible:
        return targets

    # Ensure each eligible texture gets at least one slot, then distribute remainder proportionally.
    for texture in eligible:
        targets[texture] = 1
    remaining = max(0, total - len(eligible))
    while remaining > 0:
        ranked = sorted(eligible, key=lambda t: (targets[t] / max(1, counts[t]), targets[t], t))
        pick = ranked[0]
        if targets[pick] < counts[pick]:
            targets[pick] += 1
            remaining -= 1
        else:
            # All buckets may be saturated in tiny datasets.
            break
    return targets


def _choose_diverse(candidates: List[Dict[str, Any]], count: int, rng: random.Random) -> List[Dict[str, Any]]:
    if count <= 0 or not candidates:
        return []
    pool = list(candidates)
    rng.shuffle(pool)

    picked: List[Dict[str, Any]] = []
    depth_seen: Counter = Counter()
    pos_seen: Counter = Counter()
    stack_seen: Counter = Counter()

    while pool and len(picked) < count:
        best_idx = 0
        best_score = None
        for idx, rec in enumerate(pool):
            score = (
                depth_seen[rec["depth"]],
                pos_seen[rec["position"]],
                stack_seen[rec["stack_bucket"]],
                rec["path"].name,
            )
            if best_score is None or score < best_score:
                best_score = score
                best_idx = idx
        chosen = pool.pop(best_idx)
        picked.append(chosen)
        depth_seen[chosen["depth"]] += 1
        pos_seen[chosen["position"]] += 1
        stack_seen[chosen["stack_bucket"]] += 1
    return picked


def main() -> int:
    parser = argparse.ArgumentParser(description="Build deterministic canonical spot pack.")
    parser.add_argument("--spot-dir", required=True, help="Directory containing candidate spot JSON files.")
    parser.add_argument("--output-dir", required=True, help="Canonical pack output directory.")
    parser.add_argument("--count", type=int, default=20, help="Number of canonical spots to select.")
    parser.add_argument(
        "--streets",
        nargs="+",
        default=["turn"],
        help="Target street set, e.g. --streets turn river for a harder mixed pack.",
    )
    parser.add_argument(
        "--min-per-street",
        type=int,
        default=0,
        help="Minimum selected spots per requested street when available.",
    )
    parser.add_argument("--seed", type=int, default=4090, help="Random seed for deterministic selection.")
    parser.add_argument(
        "--benchmark-mode",
        action="store_true",
        help="Force remove_donk_bets=false on canonical output spots.",
    )
    args = parser.parse_args()

    spot_dir = Path(args.spot_dir)
    out_dir = Path(args.output_dir)
    out_spot_dir = out_dir / "spots"
    out_manifest = out_dir / "canonical_manifest.json"
    out_report = out_dir / "canonical_report.json"

    if not spot_dir.exists():
        raise SystemExit(f"spot-dir not found: {spot_dir}")

    all_paths = sorted(spot_dir.rglob("*.json"))
    records: List[Dict[str, Any]] = []
    street_filter = {s.strip().lower() for s in args.streets if s.strip()}
    if not street_filter:
        street_filter = {"turn"}

    for path in all_paths:
        try:
            spot = _load_spot(path)
        except (json.JSONDecodeError, OSError):
            continue
        spot_street = _detect_street(spot)
        if spot_street not in street_filter:
            continue
        records.append(
            {
                "path": path,
                "street": spot_street,
                "texture": _texture_of(spot),
                "depth": _depth_of(spot),
                "position": _position_of(spot),
                "stack_bucket": _stack_bucket(spot),
                "spot": spot,
            }
        )

    if len(records) < args.count:
        raise SystemExit(f"Not enough candidate spots. Needed {args.count}, found {len(records)}.")

    texture_counts = Counter(rec["texture"] for rec in records)
    targets = _allocate_targets(args.count, texture_counts)

    rng = random.Random(args.seed)
    chosen: List[Dict[str, Any]] = []
    chosen_paths = set()

    if args.min_per_street > 0 and len(street_filter) > 1:
        for street in sorted(street_filter):
            street_bucket = [rec for rec in records if rec["street"] == street and rec["path"] not in chosen_paths]
            picks = _choose_diverse(street_bucket, args.min_per_street, rng)
            for rec in picks:
                chosen.append(rec)
                chosen_paths.add(rec["path"])

    for texture, target in targets.items():
        if len(chosen) >= args.count:
            break
        remaining = max(0, target - sum(1 for rec in chosen if rec["texture"] == texture))
        if remaining <= 0:
            continue
        bucket = [rec for rec in records if rec["texture"] == texture and rec["path"] not in chosen_paths]
        picks = _choose_diverse(bucket, remaining, rng)
        for rec in picks:
            chosen.append(rec)
            chosen_paths.add(rec["path"])

    if len(chosen) < args.count:
        remaining_pool = [rec for rec in records if rec["path"] not in chosen_paths]
        extra = _choose_diverse(remaining_pool, args.count - len(chosen), rng)
        chosen.extend(extra)

    chosen = chosen[: args.count]
    chosen.sort(key=lambda rec: rec["path"].name)

    out_spot_dir.mkdir(parents=True, exist_ok=True)
    manifest_rows: List[Dict[str, Any]] = []

    for i, rec in enumerate(chosen, start=1):
        src_path = rec["path"]
        spot = dict(rec["spot"])
        if args.benchmark_mode:
            spot["remove_donk_bets"] = False
        spot.setdefault("meta", {})
        if isinstance(spot["meta"], dict):
            spot["meta"]["canonical_pack"] = True
            spot["meta"]["canonical_seed"] = args.seed
            spot["meta"]["canonical_index"] = i
            spot["meta"]["benchmark_mode"] = bool(args.benchmark_mode)

        out_name = f"spot_{i:02d}.{src_path.name}"
        out_path = out_spot_dir / out_name
        out_path.write_text(json.dumps(spot, indent=2) + "\n", encoding="utf-8")

        manifest_rows.append(
            {
                "index": i,
                "spot_path": str(out_path.relative_to(out_dir)).replace("\\", "/"),
                "source_path": str(src_path).replace("\\", "/"),
                "street": rec["street"],
                "texture": rec["texture"],
                "depth": rec["depth"],
                "position": rec["position"],
                "stack_bucket": rec["stack_bucket"],
            }
        )

    report = {
        "streets": sorted(street_filter),
        "count": len(manifest_rows),
        "seed": args.seed,
        "benchmark_mode": bool(args.benchmark_mode),
        "input_total": len(records),
        "street_counts": dict(Counter(row["street"] for row in manifest_rows)),
        "texture_counts": dict(Counter(row["texture"] for row in manifest_rows)),
        "depth_counts": dict(Counter(row["depth"] for row in manifest_rows)),
        "position_counts": dict(Counter(row["position"] for row in manifest_rows)),
        "stack_bucket_counts": dict(Counter(row["stack_bucket"] for row in manifest_rows)),
        "target_texture_alloc": targets,
    }

    out_manifest.write_text(json.dumps(manifest_rows, indent=2) + "\n", encoding="utf-8")
    out_report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(json.dumps({"output_dir": str(out_dir), "report": report}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
