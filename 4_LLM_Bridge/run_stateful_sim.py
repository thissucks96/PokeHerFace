#!/usr/bin/env python
"""Run a stateful passive-villain poker simulation against the bridge /solve endpoint."""

from __future__ import annotations

import argparse
import itertools
import json
import random
import statistics
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from requests import RequestException

# Simple hand evaluator to find showdown winners
# Ranks: High Card=0, Pair=1, Two Pair=2, Three of a Kind=3, Straight=4, Flush=5, Full House=6, Quads=7, Straight Flush=8
RANK_CHARS = "23456789TJQKA"
SUIT_CHARS = "shdc"
RANK_VALS = {c: i for i, c in enumerate(RANK_CHARS)}
DEFAULT_VILLAIN_RANGE = "22+,A2s+,K2s+,Q2s+,J2s+,T2s+,92s+,82s+,72s+,62s+,52s+,42s+,32s+,A2o+,K2o+,Q2o+,J2o+,T2o+,92o+,82o+,72o+,62o+,52o+,42o+,32o+"
DEFAULT_BET_SIZING = {
    "flop": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
    "turn": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
    "river": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
}
FAST_BET_SIZING = {
    "flop": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
    "turn": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
    "river": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
}
FAST_LIVE_BET_SIZING = {
    "flop": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
    "turn": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
    "river": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0, 2.0]},
}
DEFAULT_LEGAL_ACTIONS = ["check", "bet_33", "bet_75", "all_in"]
PASSIVE_VILLAIN_POLICY = {
    "checked_to": "check",
    "facing_hero_bet": "auto_call",
    "facing_hero_all_in": "auto_call",
    "raises": "disabled",
    "folds": "disabled",
}
AGGRESSIVE_VILLAIN_POLICY = {
    "checked_to": "bet_75",
    "facing_hero_bet": "auto_call",
    "facing_hero_all_in": "auto_call",
    "raises": "disabled",
    "folds": "disabled",
}
AGGRESSIVE_LEGAL_ACTIONS = ["fold", "call", "raise_75", "all_in"]
VILLAIN_MODE_CHOICES = ["scripted_tight", "scripted_aggressive", "engine_random"]

def _get_card_val(card_str: str) -> tuple[int, str]:
    if len(card_str) == 3 and card_str.startswith("10"):
        return (RANK_VALS["T"], card_str[2].lower())
    return (RANK_VALS[card_str[0].upper()], card_str[1].lower())

def _combo_range_from_hole_cards(cards: List[str]) -> str:
    if len(cards) != 2:
        raise ValueError(f"Expected exactly 2 hole cards, got {cards!r}")
    ordered = sorted(cards, key=lambda c: _get_card_val(c)[0], reverse=True)
    card1, card2 = ordered[0], ordered[1]

    rank1, rank2 = card1[0].upper(), card2[0].upper()
    suit1, suit2 = card1[1].lower(), card2[1].lower()

    if rank1 == rank2:
        return f"{rank1}{rank2}"
    if suit1 == suit2:
        return f"{rank1}{rank2}s"
    return f"{rank1}{rank2}o"

def _eval_7_cards(cards: List[str]) -> tuple[int, List[int]]:
    best_score = (-1, [])
    for combo in itertools.combinations(cards, 5):
        score = _eval_5_cards(list(combo))
        if score > best_score:
            best_score = score
    return best_score

def _eval_5_cards(cards: List[str]) -> tuple[int, List[int]]:
    parsed = sorted([_get_card_val(c) for c in cards], key=lambda x: x[0], reverse=True)
    ranks = [r for r, s in parsed]
    suits = [s for r, s in parsed]
    
    is_flush = len(set(suits)) == 1
    
    # Check straight
    is_straight = False
    if len(set(ranks)) == 5 and ranks[0] - ranks[4] == 4:
        is_straight = True
    elif ranks == [12, 3, 2, 1, 0]: # A, 5, 4, 3, 2
        is_straight = True
        ranks = [3, 2, 1, 0, -1] # effectively A plays as 1

    rank_counts = {r: ranks.count(r) for r in set(ranks)}
    counts = sorted([(count, r) for r, count in rank_counts.items()], reverse=True)
    
    if is_straight and is_flush:
        return (8, ranks)
    if counts[0][0] == 4:
        return (7, [counts[0][1], counts[1][1]])
    if counts[0][0] == 3 and counts[1][0] == 2:
        return (6, [counts[0][1], counts[1][1]])
    if is_flush:
        return (5, ranks)
    if is_straight:
        return (4, ranks)
    if counts[0][0] == 3:
        kickers = sorted([r for r in ranks if r != counts[0][1]], reverse=True)
        return (3, [counts[0][1]] + kickers)
    if counts[0][0] == 2 and counts[1][0] == 2:
        kicker = [r for r in ranks if r not in (counts[0][1], counts[1][1])][0]
        return (2, [max(counts[0][1], counts[1][1]), min(counts[0][1], counts[1][1]), kicker])
    if counts[0][0] == 2:
        kickers = sorted([r for r in ranks if r != counts[0][1]], reverse=True)
        return (1, [counts[0][1]] + kickers)
    
    return (0, ranks)


def _generate_deck() -> List[str]:
    return [f"{r}{s}" for r in RANK_CHARS for s in SUIT_CHARS]

def _deal_hand(deck: List[str]) -> tuple[List[str], List[str], List[str]]:
    random.shuffle(deck)
    hero = [deck[0], deck[1]]
    villain = [deck[2], deck[3]]
    board = [deck[4], deck[5], deck[6], deck[7], deck[8]]
    return hero, villain, board

def _build_engine_spot(
    hero_cards: List[str],
    board_cards: List[str],
    pot: int,
    hero_stack: int,
    scenario: Dict[str, Any],
    active_node_path: str = "",
) -> Dict[str, Any]:
    hero_exact_combo = _combo_range_from_hole_cards(hero_cards)

    return {
        "hero_range": hero_exact_combo,
        "villain_range": str(scenario["villain_range"]),
        "board": board_cards,
        "in_position_player": int(scenario["in_position_player"]),
        "starting_stack": hero_stack,
        "starting_pot": pot,
        "minimum_bet": int(scenario["minimum_bet"]),
        "all_in_threshold": float(scenario["all_in_threshold"]),
        "iterations": int(scenario["iterations"]),
        "min_exploitability": -1.0,
        "thread_count": int(scenario["thread_count"]),
        "remove_donk_bets": bool(scenario["remove_donk_bets"]),
        "raise_cap": int(scenario["raise_cap"]),
        "compress_strategy": bool(scenario["compress_strategy"]),
        "bet_sizing": scenario["bet_sizing"],
        "active_node_path": active_node_path,
    }


def _map_solver_action_to_harness_action(
    action_base: str,
    amount: Optional[Any],
    *,
    aggressive: bool,
    reference_pot: int,
) -> str:
    base = str(action_base or "check").strip().lower()
    if aggressive:
        if base == "fold":
            return "fold"
        if base == "all_in":
            return "all_in"
        if base in {"check", "call"}:
            return "call"
        if base in {"bet", "raise"}:
            return "raise_75"
        return "call"

    if base == "all_in":
        return "all_in"
    if base == "raise":
        return "bet_75"
    if base == "bet":
        f_amount = 0.0
        try:
            if amount is not None:
                f_amount = float(amount)
        except (TypeError, ValueError):
            f_amount = 0.0
        if reference_pot > 0 and f_amount > (0.6 * float(reference_pot)):
            return "bet_75"
        return "bet_33"
    return base


def _scenario_bet_sizing(runtime_profile: str) -> Dict[str, Dict[str, List[float]]]:
    profile = str(runtime_profile or "").strip().lower()
    if profile == "fast":
        return json.loads(json.dumps(FAST_BET_SIZING))
    if profile == "fast_live":
        return json.loads(json.dumps(FAST_LIVE_BET_SIZING))
    return json.loads(json.dumps(DEFAULT_BET_SIZING))


def _aggressive_bet_sizing(runtime_profile: str) -> Dict[str, Dict[str, List[float]]]:
    profile = str(runtime_profile or "").strip().lower()
    if profile in {"fast", "fast_live"}:
        return json.loads(json.dumps(FAST_BET_SIZING))
    return json.loads(json.dumps(DEFAULT_BET_SIZING))


def _extract_action_map_and_result(resp_json: Dict[str, Any]) -> tuple[list[Dict[str, Any]], Dict[str, Any]]:
    result_block = resp_json.get("result", {}) or {}
    action_map = result_block.get("root_actions", [])
    if bool(result_block.get("active_node_found")) and isinstance(result_block.get("active_node_actions"), list):
        action_map = result_block.get("active_node_actions", [])
    if not isinstance(action_map, list):
        action_map = []
    filtered: list[Dict[str, Any]] = [a for a in action_map if isinstance(a, dict)]
    return filtered, result_block


def _sample_action_from_solver_map(
    action_map: List[Dict[str, Any]],
    *,
    reference_pot: int,
    aggressive: bool,
    weighted_sample: bool,
    default_action: str,
) -> tuple[str, list[Dict[str, Any]], str]:
    if not action_map:
        return default_action, [], "fallback_decision"

    action_map_log: List[Dict[str, Any]] = []
    best_freq = -1.0
    chosen_action = default_action
    weighted_candidates: Dict[str, float] = {}

    for a in action_map:
        freq = float(a.get("avg_frequency", a.get("frequency", 0)))
        action_base = a.get("action", "check")
        amount = a.get("amount")
        mapped_action = _map_solver_action_to_harness_action(
            str(action_base),
            amount,
            aggressive=aggressive,
            reference_pot=reference_pot,
        )
        action_map_log.append(
            {
                "solver_action": str(action_base),
                "amount": amount,
                "avg_frequency": freq,
                "mapped_action": mapped_action,
            }
        )
        if weighted_sample and freq > 0.0:
            weighted_candidates[mapped_action] = weighted_candidates.get(mapped_action, 0.0) + freq
        if freq > best_freq:
            best_freq = freq
            chosen_action = mapped_action

    if weighted_sample and weighted_candidates:
        population = list(weighted_candidates.keys())
        weights = [max(0.0, float(weighted_candidates[key])) for key in population]
        if sum(weights) > 0.0:
            return random.choices(population, weights=weights, k=1)[0], action_map_log, "weighted_sample"
    return chosen_action, action_map_log, "argmax"


def _artifact_write(artifact_dir: Optional[Path], stage: str, payload: Dict[str, Any], response: Dict[str, Any]) -> None:
    if artifact_dir is None:
        return
    artifact_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")
    token = uuid.uuid4().hex[:6]
    payload_path = artifact_dir / f"{stage}_payload_{stamp}_{token}.json"
    response_path = artifact_dir / f"{stage}_response_{stamp}_{token}.json"
    payload_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    response_path.write_text(json.dumps(response, indent=2), encoding="utf-8")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hands", type=int, default=20, help="Number of full hands to simulate")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000/solve", help="Bridge /solve endpoint")
    parser.add_argument("--preset", default="local_qwen3_coder_30b")
    parser.add_argument("--runtime-profile", default="fast")
    parser.add_argument("--timeout", type=int, default=60, help="Bridge request timeout sec")
    parser.add_argument("--starting-stack-bb", type=int, default=100, help="Starting effective stack in big blinds")
    parser.add_argument("--starting-pot-bb", type=int, default=6, help="Starting pot size in big blinds at flop")
    parser.add_argument("--minimum-bet-bb", type=int, default=2, help="Minimum bet size in big blinds")
    parser.add_argument("--all-in-threshold", type=float, default=0.58, help="All-in threshold ratio passed to shark")
    parser.add_argument("--iterations", type=int, default=5, help="CFR iterations for each solve")
    parser.add_argument("--thread-count", type=int, default=14, help="Thread count for each solve")
    parser.add_argument("--raise-cap", type=int, default=3, help="Raise cap for the simulated solve tree")
    parser.add_argument("--oop", action="store_true", help="Run the hero out of position instead of in position")
    parser.add_argument("--aggressive", action="store_true", help="Legacy shortcut: same as --villain-mode scripted_aggressive")
    parser.add_argument(
        "--villain-mode",
        choices=VILLAIN_MODE_CHOICES,
        default="",
        help="Villain policy mode: scripted_tight, scripted_aggressive, or engine_random.",
    )
    parser.add_argument("--allow-donk-bets", action="store_true", help="Disable the default remove_donk_bets simplification")
    parser.add_argument("--disable-compress-strategy", action="store_true", help="Disable compress_strategy in spot payloads")
    parser.add_argument(
        "--artifact-dir",
        default="",
        help="Optional directory to write payload/response artifacts for dataset building.",
    )
    parser.add_argument("--output", required=True, help="Output JSON map")
    args = parser.parse_args()

    villain_mode = str(args.villain_mode or "").strip().lower()
    if not villain_mode:
        villain_mode = "scripted_aggressive" if args.aggressive else "scripted_tight"
    aggressive_mode = villain_mode in {"scripted_aggressive", "engine_random"}
    active_policy = AGGRESSIVE_VILLAIN_POLICY if aggressive_mode else PASSIVE_VILLAIN_POLICY
    active_mode = f"stateful_{villain_mode}_heads_up"
    active_legal_actions = AGGRESSIVE_LEGAL_ACTIONS if aggressive_mode else DEFAULT_LEGAL_ACTIONS
    facing_action_value = "facing_bet_75" if aggressive_mode else "checked_to_hero"
    artifact_dir: Optional[Path] = None
    if str(args.artifact_dir or "").strip():
        artifact_dir = Path(str(args.artifact_dir)).resolve()

    scenario: Dict[str, Any] = {
        "mode": active_mode,
        "hero_seat": "btn",
        "villain_seat": "bb",
        "villain_policy": active_policy,
        "legal_actions": active_legal_actions,
        "villain_range": DEFAULT_VILLAIN_RANGE,
        "in_position_player": 2 if aggressive_mode else (2 if args.oop else 1),
        "starting_stack_bb": args.starting_stack_bb,
        "starting_pot_bb": args.starting_pot_bb,
        "minimum_bet": args.minimum_bet_bb,
        "all_in_threshold": args.all_in_threshold,
        "iterations": args.iterations,
        "thread_count": args.thread_count,
        "remove_donk_bets": False if aggressive_mode else not args.allow_donk_bets,
        "raise_cap": args.raise_cap,
        "compress_strategy": not args.disable_compress_strategy,
        "bet_sizing": _aggressive_bet_sizing(args.runtime_profile) if aggressive_mode else _scenario_bet_sizing(args.runtime_profile),
    }

    results = []
    
    mode_label = villain_mode
    print(f"Starting {mode_label} state harness (Hands: {args.hands})")
    
    total_latency_by_street = {"flop": [], "turn": [], "river": []}
    action_counts_by_street = {"flop": {}, "turn": {}, "river": {}}
    strategy_source_counts = {}
    all_in_count = 0
    all_in_streets = []
    win_loss = {"win": 0, "loss": 0, "tie": 0}
    net_bb_won = 0.0

    for h_idx in range(args.hands):
        deck = _generate_deck()
        hero_hole, villain_hole, full_board = _deal_hand(deck)
        
        # State: Postflop start (hero/villain already reached flop in a simplified heads-up pot)
        pot = int(args.starting_pot_bb)
        hero_stack = int(args.starting_stack_bb)

        hand_record: Dict[str, Any] = {
            "hand_index": h_idx + 1,
            "hero_cards": hero_hole,
            "hero_range": _combo_range_from_hole_cards(hero_hole),
            "villain_cards": villain_hole,
            "villain_range": str(scenario["villain_range"]),
            "full_board": full_board,
            "scenario": {
                "street_order": ["flop", "turn", "river"],
                "facing_action": facing_action_value,
                "legal_actions": scenario["legal_actions"],
                "hero_in_position": scenario["in_position_player"] == 1,
                "starting_stack_bb": scenario["starting_stack_bb"],
                "starting_pot_bb": scenario["starting_pot_bb"],
            },
            "streets": [],
            "showdown": {},
            "all_in": False,
            "all_in_street": None,
            "folded": False,
            "fold_street": None,
        }
        
        active = True
        
        for street_idx, street_name, board_count in [(0, "flop", 3), (1, "turn", 4), (2, "river", 5)]:
            if not active:
                break
                
            current_board = full_board[:board_count]
            base_pot = pot
            villain_bet = 0
            villain_action = "check"
            villain_action_map_log: List[Dict[str, Any]] = []
            villain_selection_mode = "scripted"
            lead_sizes = scenario["bet_sizing"].get(street_name, {}).get("bet_sizes", [0.75])
            lead_ratio = float(lead_sizes[0]) if lead_sizes else 0.75
            if villain_mode == "scripted_aggressive":
                villain_bet = max(int(scenario["minimum_bet"]), int(round(base_pot * lead_ratio)))
                villain_bet = min(hero_stack, villain_bet)
                villain_action = "bet_75" if villain_bet > 0 else "check"
            elif villain_mode == "engine_random":
                villain_spot = _build_engine_spot(
                    villain_hole,
                    current_board,
                    base_pot,
                    hero_stack,
                    scenario,
                    active_node_path="",
                )
                villain_payload = {
                    "spot": villain_spot,
                    "timeout_sec": args.timeout,
                    "quiet": True,
                    "auto_select_best": True,
                    "ev_keep_margin": 0.001,
                    "llm": {"preset": args.preset},
                    "enable_multi_node_locks": False,
                    "runtime_profile": args.runtime_profile,
                }
                try:
                    r_v = requests.post(args.endpoint, json=villain_payload, timeout=args.timeout + 10)
                    r_v.raise_for_status()
                    villain_resp = r_v.json()
                    _artifact_write(
                        artifact_dir=artifact_dir,
                        stage=f"stateful_sim_villain_h{h_idx+1}_{street_name}",
                        payload=villain_payload,
                        response=villain_resp,
                    )
                    villain_action_map, _ = _extract_action_map_and_result(villain_resp)
                    villain_action, villain_action_map_log, villain_selection_mode = _sample_action_from_solver_map(
                        villain_action_map,
                        reference_pot=base_pot,
                        aggressive=False,
                        weighted_sample=True,
                        default_action="check",
                    )
                except Exception:
                    villain_action = "check"
                    villain_selection_mode = "engine_fallback_check"

                if villain_action in {"bet_33", "bet_75", "raise_75", "all_in"}:
                    if villain_action == "bet_33":
                        villain_bet = max(int(scenario["minimum_bet"]), int(round(base_pot * 0.33)))
                    elif villain_action in {"bet_75", "raise_75"}:
                        villain_bet = max(int(scenario["minimum_bet"]), int(round(base_pot * 0.75)))
                    else:
                        villain_bet = hero_stack
                    villain_bet = min(hero_stack, villain_bet)
            decision_pot = pot + villain_bet
            decision_stack = hero_stack
            street_facing_action = "facing_bet_75" if villain_bet > 0 else "checked_to_hero"
            active_node_path = ""
            if villain_bet > 0:
                active_node_path = f"root/p1:check/p2:bet:{villain_bet}"
            solve_pot = base_pot if active_node_path else decision_pot
            spot = _build_engine_spot(
                hero_hole,
                current_board,
                solve_pot,
                decision_stack,
                scenario,
                active_node_path=active_node_path,
            )
            
            payload = {
                "spot": spot,
                "timeout_sec": args.timeout,
                "quiet": True,
                "auto_select_best": True,
                "ev_keep_margin": 0.001,
                "llm": {"preset": args.preset},
                "enable_multi_node_locks": False,
                "runtime_profile": args.runtime_profile
            }
            
            t_start = time.perf_counter()
            resp_json: Dict[str, Any] = {}
            try:
                r = requests.post(args.endpoint, json=payload, timeout=args.timeout + 10)
                r.raise_for_status()
                resp_json = r.json()
                _artifact_write(
                    artifact_dir=artifact_dir,
                    stage=f"stateful_sim_hero_h{h_idx+1}_{street_name}",
                    payload=payload,
                    response=resp_json,
                )
            except Exception as e:
                error_msg = str(e)
                if isinstance(e, RequestException) and e.response is not None:
                    error_msg += f" | Body: {e.response.text}"
                hand_record["streets"].append({"street": street_name, "error": error_msg}) # type: ignore
                active = False
                break
            t_elapsed = time.perf_counter() - t_start
            
            metrics = resp_json.get("metrics", {})
            action_map, result_block = _extract_action_map_and_result(resp_json)
            strat_source = str(resp_json.get("selected_strategy") or result_block.get("selected_strategy") or "unknown")
            strategy_source_counts[strat_source] = strategy_source_counts.get(strat_source, 0) + 1
            total_latency_by_street[street_name].append(t_elapsed)
            # Map choice to exact sizes
            chosen_action = "call" if villain_bet > 0 else "check"
            action_map_log: List[Dict[str, Any]] = []
            selection_mode = "fallback_decision"
            if not action_map and result_block.get("decision"):
                 raw_action = str(result_block["decision"].get("action", "check")).strip().lower()
                 if villain_bet > 0:
                     if raw_action == "fold":
                         chosen_action = "fold"
                     elif raw_action == "all_in":
                         chosen_action = "all_in"
                     elif "bet" in raw_action or "raise" in raw_action:
                         chosen_action = "raise_75"
                     else:
                         chosen_action = "call"
                 elif "bet" in raw_action:
                      chosen_action = "bet_33" # Fallback heuristic assumption
            else:
                 chosen_action, action_map_log, selection_mode = _sample_action_from_solver_map(
                     action_map,
                     reference_pot=base_pot,
                     aggressive=(villain_bet > 0),
                     weighted_sample=(villain_bet > 0),
                     default_action=chosen_action,
                 )

            action_counts_by_street[street_name][chosen_action] = action_counts_by_street[street_name].get(chosen_action, 0) + 1

            # Math application
            invested = 0
            min_bet = int(spot["minimum_bet"])
            if villain_bet > 0:
                raise_extra = max(min_bet, int(round(base_pot * 0.75)))
                if chosen_action == "fold":
                    pot = decision_pot
                    active = False
                    hand_record["folded"] = True
                    hand_record["fold_street"] = street_name
                elif chosen_action == "call":
                    invested = min(hero_stack, villain_bet)
                    pot = decision_pot + invested
                    hero_stack -= invested
                elif chosen_action == "raise_75":
                    invested = min(hero_stack, villain_bet + raise_extra)
                    villain_raise_call = max(0, invested - villain_bet)
                    pot = decision_pot + invested + villain_raise_call
                    hero_stack -= invested
                elif chosen_action == "all_in":
                    invested = hero_stack
                    villain_match = max(0, invested - villain_bet)
                    pot = decision_pot + invested + villain_match
                    hero_stack = 0
            else:
                if chosen_action == "bet_33":
                    invested = max(min_bet, int(round(pot * 0.33)))
                elif chosen_action == "bet_75":
                    invested = max(min_bet, int(round(pot * 0.75)))
                elif chosen_action == "all_in":
                    invested = hero_stack
                invested = min(hero_stack, invested)
                pot += (invested * 2)
                hero_stack -= invested
            
            if hero_stack <= 0 and chosen_action != "fold":
                chosen_action = "all_in"
                active = False
                hand_record["all_in"] = True
                hand_record["all_in_street"] = street_name
                all_in_count += 1
                all_in_streets.append(street_name)
            
            hand_record["streets"].append({ # type: ignore
                "street": street_name,
                "facing_action": street_facing_action,
                "legal_actions": scenario["legal_actions"],
                "villain_action": villain_action,
                "villain_action_selection_mode": villain_selection_mode,
                "villain_action_map": villain_action_map_log,
                "solve_spot": {
                    "hero_range": spot["hero_range"],
                    "villain_range": spot["villain_range"],
                    "board": list(current_board),
                    "in_position_player": spot["in_position_player"],
                    "starting_stack": decision_stack,
                    "starting_pot": decision_pot,
                    "minimum_bet": spot["minimum_bet"],
                    "all_in_threshold": spot["all_in_threshold"],
                    "iterations": spot["iterations"],
                    "thread_count": spot["thread_count"],
                    "remove_donk_bets": spot["remove_donk_bets"],
                    "raise_cap": spot["raise_cap"],
                    "compress_strategy": spot["compress_strategy"],
                    "active_node_path": spot["active_node_path"],
                },
                "villain_bet": villain_bet,
                "pot": pot,
                "stack": hero_stack,
                "action": chosen_action,
                "action_selection_mode": selection_mode,
                "action_map": action_map_log,
                "latency_sec": t_elapsed,
                "strategy_source": strat_source
            })

        starting_stack_bb = float(args.starting_stack_bb)
        if bool(hand_record["folded"]):
            res = "loss"
            win_loss[res] += 1
            final_hero_stack = float(hero_stack)
            hand_record["showdown"] = {"result": res, "final_pot": pot, "net_bb": final_hero_stack - starting_stack_bb}
        else:
            hero_score = _eval_7_cards(hero_hole + full_board)
            villain_score = _eval_7_cards(villain_hole + full_board)
            is_win = hero_score > villain_score
            is_tie = hero_score == villain_score
            res = "tie" if is_tie else ("win" if is_win else "loss")
            win_loss[res] += 1
            if is_win:
                final_hero_stack = float(hero_stack + pot)
            elif is_tie:
                final_hero_stack = float(hero_stack + (pot / 2.0))
            else:
                final_hero_stack = float(hero_stack)
            hand_record["showdown"] = {"result": res, "final_pot": pot, "net_bb": final_hero_stack - starting_stack_bb}
        net_bb = final_hero_stack - starting_stack_bb
        net_bb_won += net_bb
        results.append(hand_record)
        print(f"Hand {h_idx+1}/{args.hands} | Pot: {pot} | Res: {res} | All-In: {hand_record['all_in']}")

    # Aggregates
    aggs = {
        "total_hands": args.hands,
        "win_loss": win_loss,
        "net_bb_won": net_bb_won,
        "bb_100": (net_bb_won / args.hands) * 100,
        "all_in_count": all_in_count,
        "all_in_distribution": {s: all_in_streets.count(s) for s in set(all_in_streets)},
        "strategy_sources": strategy_source_counts,
        "avg_latency": {s: (statistics.mean(times) if times else 0.0) for s, times in total_latency_by_street.items()},
        "actions_by_street": action_counts_by_street
    }

    out_path = Path(args.output).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({
        "schema_version": "stateful_sim_report.v2",
        "scenario": scenario,
        "aggregate": aggs,
        "hands": results,
    }, indent=2))
    print(f"Done. Wrote to {out_path}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
