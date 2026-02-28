#!/usr/bin/env python
"""Run a stateful passive-villain poker simulation against the bridge /solve endpoint."""

from __future__ import annotations

import argparse
import itertools
import json
import random
import statistics
import time
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
    "flop": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0]},
    "turn": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0]},
    "river": {"bet_sizes": [0.33, 0.75], "raise_sizes": [1.0]},
}
DEFAULT_LEGAL_ACTIONS = ["check", "bet_33", "bet_75", "all_in"]
PASSIVE_VILLAIN_POLICY = {
    "checked_to": "check",
    "facing_hero_bet": "auto_call",
    "facing_hero_all_in": "auto_call",
    "raises": "disabled",
    "folds": "disabled",
}

def _get_card_val(card_str: str) -> tuple[int, str]:
    if len(card_str) == 3 and card_str.startswith("10"):
        return (RANK_VALS["T"], card_str[2].lower())
    return (RANK_VALS[card_str[0].upper()], card_str[1].lower())

def _combo_range_from_hole_cards(cards: List[str]) -> str:
    if len(cards) != 2:
        raise ValueError(f"Expected exactly 2 hole cards, got {cards!r}")
    ordered = sorted(cards, key=lambda c: (_get_card_val(c)[0], c[1].lower()), reverse=True)
    return "".join(f"{card[0].upper()}{card[1].lower()}" for card in ordered)

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
    }

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
    parser.add_argument("--all-in-threshold", type=float, default=0.67, help="All-in threshold ratio passed to shark")
    parser.add_argument("--iterations", type=int, default=5, help="CFR iterations for each solve")
    parser.add_argument("--thread-count", type=int, default=14, help="Thread count for each solve")
    parser.add_argument("--raise-cap", type=int, default=2, help="Raise cap for the simulated solve tree")
    parser.add_argument("--oop", action="store_true", help="Run the hero out of position instead of in position")
    parser.add_argument("--allow-donk-bets", action="store_true", help="Disable the default remove_donk_bets simplification")
    parser.add_argument("--disable-compress-strategy", action="store_true", help="Disable compress_strategy in spot payloads")
    parser.add_argument("--output", required=True, help="Output JSON map")
    args = parser.parse_args()

    scenario: Dict[str, Any] = {
        "mode": "stateful_passive_villain_heads_up",
        "hero_seat": "btn",
        "villain_seat": "bb",
        "villain_policy": PASSIVE_VILLAIN_POLICY,
        "legal_actions": DEFAULT_LEGAL_ACTIONS,
        "villain_range": DEFAULT_VILLAIN_RANGE,
        "in_position_player": 2 if args.oop else 1,
        "starting_stack_bb": args.starting_stack_bb,
        "starting_pot_bb": args.starting_pot_bb,
        "minimum_bet": args.minimum_bet_bb,
        "all_in_threshold": args.all_in_threshold,
        "iterations": args.iterations,
        "thread_count": args.thread_count,
        "remove_donk_bets": not args.allow_donk_bets,
        "raise_cap": args.raise_cap,
        "compress_strategy": not args.disable_compress_strategy,
        "bet_sizing": DEFAULT_BET_SIZING,
    }

    results = []
    
    print(f"Starting passive-villain state harness (Hands: {args.hands})")
    
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
                "facing_action": "checked_to_hero",
                "legal_actions": scenario["legal_actions"],
                "hero_in_position": scenario["in_position_player"] == 1,
                "starting_stack_bb": scenario["starting_stack_bb"],
                "starting_pot_bb": scenario["starting_pot_bb"],
            },
            "streets": [],
            "showdown": {},
            "all_in": False,
            "all_in_street": None
        }
        
        active = True
        
        for street_idx, street_name, board_count in [(0, "flop", 3), (1, "turn", 4), (2, "river", 5)]:
            if not active:
                break
                
            current_board = full_board[:board_count]
            decision_pot = pot
            decision_stack = hero_stack
            spot = _build_engine_spot(hero_hole, current_board, decision_pot, decision_stack, scenario)
            
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
            resp_json = {}
            try:
                r = requests.post(args.endpoint, json=payload, timeout=args.timeout + 10)
                r.raise_for_status()
                resp_json = r.json()
            except Exception as e:
                hand_record["streets"].append({"street": street_name, "error": str(e)}) # type: ignore
                active = False
                break
            t_elapsed = time.perf_counter() - t_start
            
            metrics = resp_json.get("metrics", {})
            action_map = resp_json.get("result", {}).get("root_actions", [])
            strat_source = str(metrics.get("runtime_profile", "unknown"))
            strategy_source_counts[strat_source] = strategy_source_counts.get(strat_source, 0) + 1
            total_latency_by_street[street_name].append(t_elapsed)
            
            # Map choice to exact sizes
            chosen_action = "check"
            if not action_map and resp_json.get("result", {}).get("decision"):
                 raw_action = resp_json["result"]["decision"].get("action", "check")
                 if "bet" in raw_action:
                      chosen_action = "bet_33" # Fallback heuristic assumption
            else:
                 best_freq = -1.0
                 for a in action_map:
                     freq = float(a.get("frequency", 0))
                     if freq > best_freq:
                         best_freq = freq
                         action_base = a.get("action", "check")
                         amount = a.get("amount")
                         if action_base == "bet" and amount:
                             pct = amount / float(pot)
                             if pct > 0.6: chosen_action = "bet_75"
                             else: chosen_action = "bet_33"
                         elif action_base == "all_in":
                             chosen_action = "all_in"
                         else:
                             chosen_action = action_base

            action_counts_by_street[street_name][chosen_action] = action_counts_by_street[street_name].get(chosen_action, 0) + 1

            # Math application
            invested = 0
            if chosen_action == "bet_33":
                invested = int(pot * 0.33)
            elif chosen_action == "bet_75":
                invested = int(pot * 0.75)
            elif chosen_action == "all_in":
                invested = hero_stack
                
            invested = min(hero_stack, invested)
            pot += (invested * 2) 
            hero_stack -= invested
            
            if hero_stack <= 0:
                chosen_action = "all_in"
                active = False
                hand_record["all_in"] = True
                hand_record["all_in_street"] = street_name
                all_in_count += 1
                all_in_streets.append(street_name)
            
            hand_record["streets"].append({ # type: ignore
                "street": street_name,
                "facing_action": "checked_to_hero",
                "legal_actions": scenario["legal_actions"],
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
                },
                "pot": pot,
                "stack": hero_stack,
                "action": chosen_action,
                "latency_sec": t_elapsed,
                "strategy_source": strat_source
            })

        # Eval
        hero_score = _eval_7_cards(hero_hole + full_board)
        villain_score = _eval_7_cards(villain_hole + full_board)
        is_win = hero_score > villain_score
        is_tie = hero_score == villain_score
        is_loss = not (is_win or is_tie)
        
        res = "tie" if is_tie else ("win" if is_win else "loss")
        win_loss[res] += 1
        
        starting_stack_bb = float(args.starting_stack_bb)
        if is_win:
            final_hero_stack = float(hero_stack + pot)
        elif is_tie:
            final_hero_stack = float(hero_stack + (pot / 2.0))
        else:
            final_hero_stack = float(hero_stack)
        net_bb = final_hero_stack - starting_stack_bb
        net_bb_won += net_bb
        
        hand_record["showdown"] = {"result": res, "final_pot": pot, "net_bb": net_bb}
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
