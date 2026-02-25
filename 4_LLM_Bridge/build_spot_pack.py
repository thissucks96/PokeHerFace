#!/usr/bin/env python
"""Build a tagged spot pack from PHH files using optional manifest metadata."""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Iterable, List

from phh_to_spot import (
    DEFAULT_HERO_RANGE,
    DEFAULT_VILLAIN_RANGE,
    build_spot_from_phh,
)


VALID_STREETS = {"flop", "turn", "river"}
VALID_TEXTURES = {"monotone", "paired", "connected", "rainbow", "two_tone", "unknown"}
VALID_DEPTHS = {"shallow_srp", "deep_3bp", "unknown"}
VALID_POSITIONS = {"ip", "oop", "unknown"}
CARD_RANKS = "23456789TJQKA"
CARD_SUITS = "cdhs"


def _slug(text: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9_]+", "_", text.strip())
    value = re.sub(r"_+", "_", value).strip("_").lower()
    return value or "unknown"


def _iter_phh_files(phh_dir: Path) -> Iterable[Path]:
    return sorted(phh_dir.rglob("*.phh"))


def _load_manifest(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(f"Manifest not found: {path}")
    if path.suffix.lower() == ".json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, list):
            raise ValueError("JSON manifest must be a list of objects.")
        return [dict(item) for item in payload if isinstance(item, dict)]
    if path.suffix.lower() == ".jsonl":
        entries = []
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line:
                continue
            obj = json.loads(line)
            if isinstance(obj, dict):
                entries.append(dict(obj))
        return entries
    if path.suffix.lower() == ".csv":
        with path.open("r", encoding="utf-8", newline="") as f:
            reader = csv.DictReader(f)
            return [dict(row) for row in reader]
    raise ValueError("Manifest format must be one of: .json, .jsonl, .csv")


def _infer_texture(board: List[str]) -> str:
    suits = [c[1].lower() for c in board if len(c) == 2]
    ranks = [c[0].upper() for c in board if len(c) == 2]
    if len(set(ranks)) < len(ranks):
        return "paired"
    if suits and len(set(suits)) == 1:
        return "monotone"
    if len(board) >= 3 and len(set(suits[:3])) == 3:
        return "rainbow"
    if len(board) >= 3 and len(set(suits[:3])) == 2:
        return "two_tone"

    rank_idx = sorted(CARD_RANKS.index(r) for r in ranks if r in CARD_RANKS)
    if rank_idx and max(rank_idx) - min(rank_idx) <= 4:
        return "connected"
    return "unknown"


def _validate_tags(texture: str, depth: str, position: str) -> List[str]:
    errors = []
    if texture not in VALID_TEXTURES:
        errors.append(f"invalid texture '{texture}'")
    if depth not in VALID_DEPTHS:
        errors.append(f"invalid depth '{depth}'")
    if position not in VALID_POSITIONS:
        errors.append(f"invalid position '{position}'")
    return errors


def _validate_spot(spot: Dict[str, Any], expected_street: str) -> List[str]:
    errors: List[str] = []
    for key in ("hero_range", "villain_range", "board"):
        if key not in spot:
            errors.append(f"missing key '{key}'")
    board = spot.get("board", [])
    if not isinstance(board, list):
        errors.append("board must be a list")
        return errors

    target_len = {"flop": 3, "turn": 4, "river": 5}[expected_street]
    if len(board) < target_len:
        errors.append(f"board has {len(board)} cards but street '{expected_street}' requires >= {target_len}")

    seen_cards = set()
    for card in board:
        if not isinstance(card, str) or len(card) != 2:
            errors.append(f"invalid card '{card}'")
            continue
        rank, suit = card[0].upper(), card[1].lower()
        if rank not in CARD_RANKS or suit not in CARD_SUITS:
            errors.append(f"invalid card '{card}'")
            continue
        if card in seen_cards:
            errors.append(f"duplicate board card '{card}'")
        seen_cards.add(card)
    return errors


def _coerce_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _build_entry_defaults(phh_file: Path, street: str) -> Dict[str, Any]:
    return {
        "id": _slug(phh_file.stem),
        "phh": str(phh_file),
        "street": street,
        "texture": "unknown",
        "depth": "unknown",
        "position": "unknown",
        "hero_range": DEFAULT_HERO_RANGE,
        "villain_range": DEFAULT_VILLAIN_RANGE,
        "iterations": 5,
        "thread_count": 14,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build tagged spot pack from PHH files.")
    parser.add_argument("--phh-dir", required=True, help="Directory containing .phh files.")
    parser.add_argument("--output-dir", required=True, help="Directory to write spot JSON outputs.")
    parser.add_argument("--manifest", help="Optional .json/.jsonl/.csv manifest with tags and per-file options.")
    parser.add_argument("--street", default="turn", choices=sorted(VALID_STREETS), help="Default target street.")
    parser.add_argument("--hero-range", default=DEFAULT_HERO_RANGE)
    parser.add_argument("--villain-range", default=DEFAULT_VILLAIN_RANGE)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--thread-count", type=int, default=14)
    parser.add_argument("--report", required=True, help="Path to write build summary JSON.")
    parser.add_argument("--output-manifest", required=True, help="Path to write result manifest .jsonl.")
    args = parser.parse_args()

    phh_dir = Path(args.phh_dir)
    output_dir = Path(args.output_dir)
    report_path = Path(args.report)
    out_manifest_path = Path(args.output_manifest)

    if not phh_dir.exists():
        raise SystemExit(f"PHH directory not found: {phh_dir}")

    if args.manifest:
        entries = _load_manifest(Path(args.manifest))
    else:
        entries = [_build_entry_defaults(path, args.street) for path in _iter_phh_files(phh_dir)]

    output_dir.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    out_manifest_path.parent.mkdir(parents=True, exist_ok=True)

    results: List[Dict[str, Any]] = []
    seen_signatures = set()
    counters = Counter()

    for entry in entries:
        rec = dict(entry)
        spot_id = _slug(str(rec.get("id") or Path(str(rec.get("phh", "spot"))).stem))
        street = str(rec.get("street") or args.street).lower()
        texture = _slug(str(rec.get("texture") or "unknown"))
        depth = _slug(str(rec.get("depth") or "unknown"))
        position = _slug(str(rec.get("position") or "unknown"))
        hero_range = str(rec.get("hero_range") or args.hero_range)
        villain_range = str(rec.get("villain_range") or args.villain_range)
        iterations = _coerce_int(rec.get("iterations"), args.iterations)
        thread_count = _coerce_int(rec.get("thread_count"), args.thread_count)

        phh_ref = Path(str(rec.get("phh", "")))
        phh_path = phh_ref if phh_ref.is_absolute() else (phh_dir / phh_ref)
        if not phh_path.exists():
            results.append(
                {
                    "id": spot_id,
                    "phh": str(phh_path),
                    "status": "error",
                    "error": "phh file not found",
                }
            )
            counters["error"] += 1
            continue

        if street not in VALID_STREETS:
            results.append({"id": spot_id, "phh": str(phh_path), "status": "error", "error": "invalid street"})
            counters["error"] += 1
            continue

        if texture == "unknown":
            inferred_texture = None
        else:
            inferred_texture = texture
        tag_errors = _validate_tags(texture if texture in VALID_TEXTURES else "unknown", depth, position)
        if tag_errors:
            results.append(
                {
                    "id": spot_id,
                    "phh": str(phh_path),
                    "status": "error",
                    "error": "; ".join(tag_errors),
                }
            )
            counters["error"] += 1
            continue

        try:
            text = phh_path.read_text(encoding="utf-8")
            spot = build_spot_from_phh(
                text,
                street=street,
                hero_range=hero_range,
                villain_range=villain_range,
                iterations=iterations,
                thread_count=thread_count,
            )
        except Exception as exc:  # pylint: disable=broad-except
            results.append({"id": spot_id, "phh": str(phh_path), "status": "error", "error": str(exc)})
            counters["error"] += 1
            continue

        if inferred_texture is None:
            texture = _infer_texture(spot.get("board", []))

        validation_errors = _validate_spot(spot, street)
        if validation_errors:
            results.append(
                {
                    "id": spot_id,
                    "phh": str(phh_path),
                    "status": "error",
                    "error": "; ".join(validation_errors),
                }
            )
            counters["error"] += 1
            continue

        signature = (
            street,
            tuple(spot.get("board", [])),
            spot.get("hero_range", ""),
            spot.get("villain_range", ""),
            depth,
            position,
        )
        if signature in seen_signatures:
            results.append(
                {
                    "id": spot_id,
                    "phh": str(phh_path),
                    "status": "skipped_duplicate",
                    "error": "duplicate spot signature",
                }
            )
            counters["skipped_duplicate"] += 1
            continue
        seen_signatures.add(signature)

        filename = f"spot.{spot_id}.{street}.{texture}.{depth}.{position}.json"
        out_path = output_dir / filename

        spot.setdefault("meta", {})
        spot["meta"].update(
            {
                "source": "phh",
                "source_phh": str(phh_path),
                "spot_id": spot_id,
                "street_target": street,
                "texture": texture,
                "depth": depth,
                "position": position,
            }
        )

        out_path.write_text(json.dumps(spot, indent=2) + "\n", encoding="utf-8")
        results.append(
            {
                "id": spot_id,
                "phh": str(phh_path),
                "spot_path": str(out_path),
                "status": "ok",
                "street": street,
                "texture": texture,
                "depth": depth,
                "position": position,
                "board": spot.get("board", []),
            }
        )
        counters["ok"] += 1

    with out_manifest_path.open("w", encoding="utf-8") as f:
        for row in results:
            f.write(json.dumps(row, ensure_ascii=True) + "\n")

    report = {
        "phh_dir": str(phh_dir),
        "output_dir": str(output_dir),
        "output_manifest": str(out_manifest_path),
        "total_entries": len(results),
        "status_counts": dict(counters),
        "street_counts": dict(Counter(r.get("street", "unknown") for r in results if r.get("status") == "ok")),
        "texture_counts": dict(Counter(r.get("texture", "unknown") for r in results if r.get("status") == "ok")),
        "depth_counts": dict(Counter(r.get("depth", "unknown") for r in results if r.get("status") == "ok")),
        "position_counts": dict(Counter(r.get("position", "unknown") for r in results if r.get("status") == "ok")),
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
