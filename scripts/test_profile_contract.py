#!/usr/bin/env python
"""Regression checks for runtime profile contract fidelity."""

from __future__ import annotations

import argparse
import json
import math
import sys
from typing import Any, Dict, List

import requests


EXPECTED_SHARK_CLASSIC_SIZING = {
    "flop": {"bet_sizes": [0.5, 1.0], "raise_sizes": [1.0]},
    "turn": {"bet_sizes": [0.33, 0.66, 1.0], "raise_sizes": [0.5, 1.0]},
    "river": {"bet_sizes": [0.33, 0.66, 1.0], "raise_sizes": [0.5, 1.0]},
}
EXPECTED_BET_AMOUNTS = {
    "flop": [5, 10],
    "turn": [3, 7, 10],
    "river": [3, 7, 10],
}


def _build_spot(board: List[str]) -> Dict[str, Any]:
    return {
        # Keep regression spot intentionally lightweight so contract checks validate profile wiring,
        # not brute-force runtime under huge trees.
        "hero_range": "QQ+,AKs,AKo,AQs",
        "villain_range": "JJ+,AQs+,AKo,KQs",
        "board": list(board),
        "in_position_player": 1,
        "starting_stack": 20,
        "starting_pot": 10,
        "minimum_bet": 2,
        "all_in_threshold": 0.67,
        "iterations": 40,
        "min_exploitability": -1.0,
        "thread_count": 4,
        "remove_donk_bets": True,
        "raise_cap": 3,
        "compress_strategy": True,
        "active_node_path": "",
        "bet_sizing": json.loads(json.dumps(EXPECTED_SHARK_CLASSIC_SIZING)),
    }


def _street_from_board(board: List[str]) -> str:
    count = len(board)
    if count == 3:
        return "flop"
    if count == 4:
        return "turn"
    if count == 5:
        return "river"
    raise ValueError(f"unsupported board length: {count}")


def _solve(endpoint: str, profile: str, board: List[str], timeout_sec: int) -> Dict[str, Any]:
    payload = {
        "spot": _build_spot(board),
        "timeout_sec": int(timeout_sec),
        "runtime_profile": profile,
        "quiet": True,
    }
    resp = requests.post(endpoint, json=payload, timeout=max(10, timeout_sec + 10))
    resp.raise_for_status()
    return resp.json()


def _assert_close(a: float, b: float, eps: float = 1e-6) -> None:
    if math.fabs(float(a) - float(b)) > eps:
        raise AssertionError(f"value mismatch: {a} != {b}")


def _assert_float_list_close(actual: List[Any], expected: List[float], eps: float = 1e-4) -> None:
    if len(actual) != len(expected):
        raise AssertionError(f"list length mismatch: {actual} != {expected}")
    for idx, (a, b) in enumerate(zip(actual, expected)):
        if math.fabs(float(a) - float(b)) > eps:
            raise AssertionError(f"list value mismatch at index {idx}: {a} != {b}")


def _extract_bet_amounts(allowed_root_actions: List[str]) -> List[int]:
    out: List[int] = []
    for token in allowed_root_actions:
        t = str(token or "").strip().lower()
        if t.startswith("bet:"):
            try:
                out.append(int(t.split(":", 1)[1]))
            except ValueError:
                continue
    return sorted(set(out))


def run(endpoint: str, timeout_sec: int) -> None:
    boards = {
        "flop": ["Ks", "Qh", "7d"],
        "turn": ["Ks", "Qh", "7d", "2c"],
        "river": ["Ks", "Qh", "7d", "2c", "3h"],
    }
    checks: List[str] = []

    for street, board in boards.items():
        solved = _solve(endpoint, "shark_classic", board, timeout_sec)
        result = solved.get("result") or {}
        input_spot = result.get("input") or {}
        metrics = solved.get("metrics") or {}

        if str(metrics.get("runtime_profile", "")).strip().lower() != "shark_classic":
            raise AssertionError(f"{street}: runtime profile mismatch in metrics")

        _assert_close(float(input_spot.get("all_in_threshold", -1)), 0.67)
        if int(input_spot.get("raise_cap", -1)) != 3:
            raise AssertionError(f"{street}: raise_cap != 3")
        if bool(input_spot.get("remove_donk_bets")) is not True:
            raise AssertionError(f"{street}: remove_donk_bets not true")

        sizing = (input_spot.get("bet_sizing") or {}).get(street) or {}
        exp = EXPECTED_SHARK_CLASSIC_SIZING[street]
        _assert_float_list_close(list(sizing.get("bet_sizes") or []), exp["bet_sizes"])
        _assert_float_list_close(list(sizing.get("raise_sizes") or []), exp["raise_sizes"])

        allowed = [str(x) for x in (solved.get("allowed_root_actions") or [])]
        if "check" not in [a.lower() for a in allowed]:
            raise AssertionError(f"{street}: check missing from allowed_root_actions")
        bet_amounts = _extract_bet_amounts(allowed)
        if street == "flop":
            for expected_amount in EXPECTED_BET_AMOUNTS[street]:
                if expected_amount not in bet_amounts:
                    raise AssertionError(f"{street}: expected bet:{expected_amount} missing from allowed_root_actions={allowed}")
        elif bet_amounts:
            expected_set = set(EXPECTED_BET_AMOUNTS[street])
            if any(amount not in expected_set for amount in bet_amounts):
                raise AssertionError(f"{street}: unexpected bet sizes in allowed_root_actions={allowed}")
        checks.append(f"{street}:ok")

    # Ensure explicit normal profile remains normal at bridge level.
    normal_resp = _solve(endpoint, "normal", boards["flop"], timeout_sec)
    normal_metrics = normal_resp.get("metrics") or {}
    if str(normal_metrics.get("runtime_profile", "")).strip().lower() != "normal":
        raise AssertionError("normal profile solve reported unexpected runtime_profile")
    checks.append("normal_profile_no_bridge_override:ok")

    print("profile_contract_regression: PASS")
    print("checks:", ", ".join(checks))


def main() -> int:
    parser = argparse.ArgumentParser(description="Regression checks for shark_classic contract and normal profile behavior.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000/solve")
    parser.add_argument("--timeout-sec", type=int, default=45)
    args = parser.parse_args()
    try:
        run(args.endpoint, args.timeout_sec)
        return 0
    except requests.RequestException as exc:
        print(f"profile_contract_regression: FAIL (request): {exc}")
        return 2
    except Exception as exc:
        print(f"profile_contract_regression: FAIL: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
