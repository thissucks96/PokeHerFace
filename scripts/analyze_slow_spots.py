#!/usr/bin/env python3
"""Build a slow-spot dataset from UI session logs and engine payload artifacts."""

from __future__ import annotations

import argparse
import csv
import json
import math
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


RANK_TO_INT = {
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


@dataclass
class StartedJob:
    session_id: str
    ts_utc: str
    stage: str
    payload_path: str
    response_path: str
    state_hash: str
    state_version: int | None
    runtime_profile: str


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
        return int(value)
    except (TypeError, ValueError):
        return default


def _street_from_board(board: list[str]) -> str:
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


def _facing_bet_bucket(facing_bet: float, big_blind: float) -> str:
    if facing_bet <= 0:
        return "no_bet"
    bb = big_blind if big_blind > 0 else 2.0
    ratio = facing_bet / bb
    if ratio <= 1:
        return "facing_<=1bb"
    if ratio <= 3:
        return "facing_1-3bb"
    if ratio <= 6:
        return "facing_3-6bb"
    return "facing_>6bb"


def _raise_depth_from_path(active_node_path: str) -> int:
    if not active_node_path:
        return 0
    count = 0
    for token in active_node_path.lower().split("/"):
        if ":raise:" in token or ":bet:" in token:
            count += 1
    return count


def _raise_depth_bucket(depth: int) -> str:
    if depth <= 0:
        return "raise_depth_0"
    if depth == 1:
        return "raise_depth_1"
    if depth == 2:
        return "raise_depth_2"
    return "raise_depth_3p"


def _parse_board_cards(board: list[str]) -> tuple[list[int], list[str]]:
    ranks: list[int] = []
    suits: list[str] = []
    for card in board:
        card_text = str(card).strip()
        if len(card_text) < 2:
            continue
        rank = card_text[0].upper()
        suit = card_text[1].lower()
        rank_value = RANK_TO_INT.get(rank)
        if rank_value is None:
            continue
        ranks.append(rank_value)
        suits.append(suit)
    return ranks, suits


def _board_texture(board: list[str]) -> str:
    if not board:
        return "preflop"
    ranks, suits = _parse_board_cards(board)
    if not ranks:
        return "unknown"

    rank_counter = Counter(ranks)
    top_rank_count = max(rank_counter.values())
    if top_rank_count >= 3:
        pair_class = "trips_plus"
    elif top_rank_count == 2:
        pair_class = "paired"
    else:
        pair_class = "unpaired"

    suit_counter = Counter(suits)
    max_suit = max(suit_counter.values()) if suit_counter else 0
    board_size = len(ranks)
    if board_size == 3:
        if max_suit == 3:
            suit_class = "monotone"
        elif max_suit == 2:
            suit_class = "two_tone"
        else:
            suit_class = "rainbow"
    elif board_size == 4:
        if max_suit >= 4:
            suit_class = "four_flush"
        elif max_suit == 3:
            suit_class = "three_flush"
        else:
            suit_class = "mixed"
    else:
        if max_suit >= 5:
            suit_class = "five_flush"
        elif max_suit == 4:
            suit_class = "four_flush"
        elif max_suit == 3:
            suit_class = "three_flush"
        else:
            suit_class = "mixed"

    span = max(ranks) - min(ranks)
    if span <= 4:
        connectivity = "connected"
    elif span <= 8:
        connectivity = "semi_connected"
    else:
        connectivity = "disconnected"

    return f"{pair_class}/{suit_class}/{connectivity}"


def _quantile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    sorted_values = sorted(values)
    pos = (len(sorted_values) - 1) * q
    low = int(math.floor(pos))
    high = int(math.ceil(pos))
    if low == high:
        return sorted_values[low]
    weight = pos - low
    return sorted_values[low] * (1 - weight) + sorted_values[high] * weight


def _load_payload(payload_path: str, cache: dict[str, dict[str, Any] | None]) -> dict[str, Any] | None:
    if payload_path in cache:
        return cache[payload_path]
    try:
        with Path(payload_path).open("r", encoding="utf-8") as f:
            parsed = json.load(f)
    except (OSError, json.JSONDecodeError):
        parsed = None
    cache[payload_path] = parsed
    return parsed


def _iter_session_paths(sessions_dir: Path, max_sessions: int | None) -> list[Path]:
    paths = sorted(sessions_dir.glob("session_*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    if max_sessions is not None and max_sessions > 0:
        return paths[:max_sessions]
    return paths


def build_report(
    sessions_dir: Path,
    output_dir: Path,
    top_n: int,
    min_elapsed_sec: float,
    max_sessions: int | None,
) -> tuple[Path, Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload_cache: dict[str, dict[str, Any] | None] = {}
    all_rows: list[dict[str, Any]] = []

    session_paths = _iter_session_paths(sessions_dir, max_sessions=max_sessions)
    for session_path in session_paths:
        started_jobs: dict[int, StartedJob] = {}
        session_runtime_profile = "unknown"
        session_id_fallback = session_path.stem.replace("session_", "")
        with session_path.open("r", encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                event_type = str(event.get("type") or "")
                event_data = event.get("data") or {}
                if event_type == "session_start":
                    session_runtime_profile = str(event_data.get("runtime_profile") or "unknown")
                    continue

                if event_type == "engine_job_started":
                    job_id = _safe_int(event_data.get("job_id"), default=-1)
                    if job_id < 0:
                        continue
                    started_jobs[job_id] = StartedJob(
                        session_id=str(event.get("session_id") or session_id_fallback),
                        ts_utc=str(event.get("ts_utc") or ""),
                        stage=str(event_data.get("stage") or "unknown"),
                        payload_path=str(event_data.get("payload_path") or ""),
                        response_path=str(event_data.get("response_path") or ""),
                        state_hash=str(event_data.get("state_hash") or ""),
                        state_version=event_data.get("state_version"),
                        runtime_profile=session_runtime_profile,
                    )
                    continue

                if event_type != "engine_job_completed":
                    continue

                job_id = _safe_int(event_data.get("job_id"), default=-1)
                started = started_jobs.get(job_id)
                if started is None:
                    continue

                elapsed = _safe_float(event_data.get("elapsed_sec"))
                if elapsed < min_elapsed_sec:
                    continue

                payload = _load_payload(started.payload_path, payload_cache) or {}
                spot = payload.get("spot") if isinstance(payload, dict) else {}
                if not isinstance(spot, dict):
                    spot = {}
                meta = spot.get("meta") if isinstance(spot.get("meta"), dict) else {}
                board = spot.get("board") if isinstance(spot.get("board"), list) else []
                board_tokens = [str(card).upper() for card in board]
                street = _street_from_board(board_tokens)
                big_blind = _safe_float(meta.get("big_blind"), default=2.0)
                facing_bet = _safe_float(meta.get("facing_bet"), default=0.0)
                active_node_path = str(spot.get("active_node_path") or "")
                raise_depth = _safe_int(meta.get("street_raise_count"), default=-1)
                if raise_depth < 0:
                    raise_depth = _raise_depth_from_path(active_node_path)

                row = {
                    "elapsed_sec": round(elapsed, 6),
                    "session_id": started.session_id,
                    "job_id": job_id,
                    "job_started_ts_utc": started.ts_utc,
                    "job_completed_ts_utc": str(event.get("ts_utc") or ""),
                    "stage": started.stage,
                    "strategy": str(event_data.get("strategy") or ""),
                    "kept": bool(event_data.get("kept")),
                    "runtime_profile": str(payload.get("runtime_profile") or started.runtime_profile or "unknown"),
                    "street": street,
                    "board": board_tokens,
                    "board_texture": _board_texture(board_tokens),
                    "facing_bet": facing_bet,
                    "big_blind": big_blind,
                    "facing_bet_bucket": _facing_bet_bucket(facing_bet, big_blind),
                    "raise_depth": raise_depth,
                    "raise_depth_bucket": _raise_depth_bucket(raise_depth),
                    "hero_street_commit": _safe_float(meta.get("hero_street_commit"), default=0.0),
                    "villain_street_commit": _safe_float(meta.get("villain_street_commit"), default=0.0),
                    "starting_pot": _safe_float(spot.get("starting_pot"), default=0.0),
                    "starting_stack": _safe_float(spot.get("starting_stack"), default=0.0),
                    "hero_range": str(spot.get("hero_range") or ""),
                    "active_node_path": active_node_path,
                    "payload_path": started.payload_path,
                    "response_path": started.response_path,
                    "cluster_key": "|".join(
                        [
                            street,
                            _facing_bet_bucket(facing_bet, big_blind),
                            _raise_depth_bucket(raise_depth),
                            _board_texture(board_tokens),
                            started.stage,
                        ]
                    ),
                }
                all_rows.append(row)

    all_rows.sort(key=lambda r: r["elapsed_sec"], reverse=True)
    top_rows = all_rows[:top_n]

    cluster_map: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in top_rows:
        cluster_map[row["cluster_key"]].append(row)

    clusters: list[dict[str, Any]] = []
    for cluster_key, rows in cluster_map.items():
        latencies = [float(r["elapsed_sec"]) for r in rows]
        street_counts = Counter(r["street"] for r in rows)
        clusters.append(
            {
                "cluster_key": cluster_key,
                "count": len(rows),
                "mean_elapsed_sec": round(sum(latencies) / len(latencies), 6),
                "p95_elapsed_sec": round(_quantile(latencies, 0.95), 6),
                "max_elapsed_sec": round(max(latencies), 6),
                "street_counts": dict(street_counts),
                "examples": [
                    {
                        "elapsed_sec": r["elapsed_sec"],
                        "strategy": r["strategy"],
                        "runtime_profile": r["runtime_profile"],
                        "board": r["board"],
                        "facing_bet": r["facing_bet"],
                        "raise_depth": r["raise_depth"],
                        "payload_path": r["payload_path"],
                    }
                    for r in rows[:3]
                ],
            }
        )

    clusters.sort(key=lambda c: (c["count"], c["mean_elapsed_sec"]), reverse=True)
    by_street = Counter(row["street"] for row in top_rows)
    by_profile = Counter(row["runtime_profile"] for row in top_rows)
    by_strategy = Counter(row["strategy"] for row in top_rows)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    json_path = output_dir / f"slow_spots_report_{timestamp}.json"
    csv_path = output_dir / f"slow_spots_top_{top_n}_{timestamp}.csv"
    txt_path = output_dir / f"slow_spots_summary_{timestamp}.txt"

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "sessions_dir": str(sessions_dir.resolve()),
        "session_files_analyzed": [str(p.resolve()) for p in session_paths],
        "session_count": len(session_paths),
        "rows_total": len(all_rows),
        "top_n": top_n,
        "min_elapsed_sec": min_elapsed_sec,
        "summary": {
            "top_max_elapsed_sec": top_rows[0]["elapsed_sec"] if top_rows else 0.0,
            "top_median_elapsed_sec": round(_quantile([r["elapsed_sec"] for r in top_rows], 0.5), 6)
            if top_rows
            else 0.0,
            "top_p95_elapsed_sec": round(_quantile([r["elapsed_sec"] for r in top_rows], 0.95), 6)
            if top_rows
            else 0.0,
            "top_by_street": dict(by_street),
            "top_by_runtime_profile": dict(by_profile),
            "top_by_strategy": dict(by_strategy),
        },
        "clusters": clusters,
        "top_slow_spots": top_rows,
    }

    with json_path.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    csv_fields = [
        "elapsed_sec",
        "runtime_profile",
        "strategy",
        "street",
        "stage",
        "facing_bet",
        "facing_bet_bucket",
        "raise_depth",
        "raise_depth_bucket",
        "board_texture",
        "board",
        "hero_range",
        "active_node_path",
        "payload_path",
    ]
    with csv_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=csv_fields)
        writer.writeheader()
        for row in top_rows:
            write_row = dict(row)
            write_row["board"] = " ".join(row["board"])
            writer.writerow({k: write_row.get(k, "") for k in csv_fields})

    with txt_path.open("w", encoding="utf-8") as f:
        f.write("Top slow spots summary\n")
        f.write("======================\n")
        f.write(f"Sessions analyzed: {len(session_paths)}\n")
        f.write(f"Jobs analyzed: {len(all_rows)}\n")
        f.write(f"Top N: {top_n}\n")
        if top_rows:
            f.write(f"Top max latency: {top_rows[0]['elapsed_sec']:.3f}s\n")
            f.write(f"Top p95 latency: {_quantile([r['elapsed_sec'] for r in top_rows], 0.95):.3f}s\n")
            f.write("\nTop streets:\n")
            for street, count in by_street.most_common():
                f.write(f"- {street}: {count}\n")
            f.write("\nTop clusters:\n")
            for cluster in clusters[:10]:
                f.write(
                    f"- {cluster['cluster_key']} | count={cluster['count']} "
                    f"mean={cluster['mean_elapsed_sec']:.3f}s p95={cluster['p95_elapsed_sec']:.3f}s\n"
                )
        else:
            f.write("No jobs matched filters.\n")

    return json_path, csv_path, txt_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect and cluster the top slowest engine spots.")
    parser.add_argument(
        "--sessions-dir",
        type=Path,
        default=Path("5_Vision_Extraction/out/ui_session_logs"),
        help="Directory containing session_*.jsonl logs.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("5_Vision_Extraction/out/slow_spot_reports"),
        help="Directory to write the report artifacts.",
    )
    parser.add_argument("--top-n", type=int, default=50, help="How many slowest spots to keep in report.")
    parser.add_argument(
        "--min-elapsed-sec",
        type=float,
        default=0.0,
        help="Discard jobs below this latency threshold.",
    )
    parser.add_argument(
        "--max-sessions",
        type=int,
        default=None,
        help="Analyze only the most recent N session files.",
    )
    args = parser.parse_args()

    if not args.sessions_dir.exists():
        raise SystemExit(f"Sessions directory not found: {args.sessions_dir}")

    json_path, csv_path, txt_path = build_report(
        sessions_dir=args.sessions_dir,
        output_dir=args.output_dir,
        top_n=max(1, args.top_n),
        min_elapsed_sec=max(0.0, args.min_elapsed_sec),
        max_sessions=args.max_sessions,
    )
    print(f"Wrote JSON report: {json_path}")
    print(f"Wrote CSV report:  {csv_path}")
    print(f"Wrote text summary:{txt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
