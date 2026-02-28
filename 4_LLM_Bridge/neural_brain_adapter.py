"""Neural brain adapter for bridge_server.

Reads a JSON payload from stdin:
{
  "spot": {...},
  "allowed_actions": ["check", "call", "raise:12", ...]
}

Returns a JSON object on stdout:
{
  "ok": true,
  "chosen_action": "call",
  "root_actions": [{"action":"call","frequency":0.7}, ...],
  "meta": {...}
}
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import torch


ROOT = Path(__file__).resolve().parents[1]
NEURAL_SRC = ROOT / "2_Neural_Brain" / "src"
if str(NEURAL_SRC) not in sys.path:
    sys.path.insert(0, str(NEURAL_SRC))
os.chdir(NEURAL_SRC)


def _normalize_card_token(raw: Any) -> str:
    token = str(raw or "").strip()
    if len(token) < 2:
        return ""
    if token[:2] == "10":
        rank = "T"
        suit = token[2:3].lower()
    else:
        rank = token[:1].upper()
        suit = token[-1:].lower()
    if rank not in {"A", "K", "Q", "J", "T", "9", "8", "7", "6", "5", "4", "3", "2"}:
        return ""
    if suit not in {"s", "h", "d", "c"}:
        return ""
    return f"{rank}{suit}"


def _street_from_board_len(board_len: int) -> int:
    if board_len >= 5:
        return 4
    if board_len == 4:
        return 3
    if board_len == 3:
        return 2
    return 1


def _parse_sizes(cfg: Any, fallback: List[float]) -> List[float]:
    if not isinstance(cfg, list):
        return list(fallback)
    out: List[float] = []
    for value in cfg:
        try:
            fval = float(value)
        except (TypeError, ValueError):
            continue
        if fval > 0:
            out.append(fval)
    return out or list(fallback)


def _normalize_allowed_tokens(tokens: Any) -> List[str]:
    out: List[str] = []
    seen = set()
    if not isinstance(tokens, list):
        return out
    for raw in tokens:
        token = str(raw or "").strip().lower()
        if not token:
            continue
        if token.startswith("bet:"):
            token = "raise:" + token.split(":", 1)[1]
        if token == "bet":
            token = "raise"
        if token == "all_in":
            token = "raise"
        if token not in seen:
            seen.add(token)
            out.append(token)
    return out


def _token_allowed(token: str, allowed: List[str]) -> bool:
    if not allowed:
        return True
    if token in allowed:
        return True
    base = token.split(":", 1)[0]
    if base in allowed:
        return True
    if base == "raise":
        for item in allowed:
            if item == "raise" or item.startswith("raise:"):
                return True
    return False


def _action_token_from_bet_value(bet_value: int, facing_amount: int) -> str:
    if bet_value == -2:
        return "fold"
    if bet_value == -1:
        return "call" if facing_amount > 0 else "check"
    return f"raise:{int(bet_value)}"


def _row_from_token(token: str, frequency: float) -> Dict[str, Any]:
    base = token.split(":", 1)[0].lower()
    item: Dict[str, Any] = {"action": base, "frequency": float(max(0.0, frequency))}
    if base == "raise" and ":" in token:
        try:
            item["amount"] = int(float(token.split(":", 1)[1]))
        except (TypeError, ValueError):
            pass
    return item


def _build_node_from_spot(spot: Dict[str, Any]) -> Tuple[Any, int, List[str], int]:
    import settings.arguments as arguments
    import settings.constants as constants
    import settings.game_settings as game_settings
    import game.card_to_string_conversion as card_to_string
    from tree.tree_node import TreeNode

    meta = spot.get("meta", {}) if isinstance(spot.get("meta"), dict) else {}
    board_tokens = [_normalize_card_token(card) for card in list(spot.get("board", []))]
    board_tokens = [token for token in board_tokens if token]
    board_string = "".join(board_tokens)
    street = _street_from_board_len(len(board_tokens))

    sb = max(1, int(meta.get("small_blind", 1)))
    bb = max(sb, int(meta.get("big_blind", max(2, sb))))
    buy_in = max(bb, int(meta.get("buy_in", max(100, bb * 50))))
    hero_chips = max(0, int(meta.get("current_hero_chips", buy_in)))
    villain_chips = max(0, int(meta.get("current_villain_chips", buy_in)))
    hero_commit = max(0, int(meta.get("hero_street_commit", 0)))
    villain_commit = max(0, int(meta.get("villain_street_commit", 0)))
    facing_bet = max(0, int(meta.get("facing_bet", 0)))
    hero_is_small_blind = bool(meta.get("hero_is_small_blind", True))

    # Seed preflop commitments when not provided.
    if street == 1 and hero_commit == 0 and villain_commit == 0:
        if hero_is_small_blind:
            hero_commit, villain_commit = sb, bb
        else:
            hero_commit, villain_commit = bb, sb

    # If hero is marked to act but commitments are inverted with no facing bet, normalize to "checkable" state.
    if facing_bet <= 0 and hero_commit > villain_commit:
        villain_commit = hero_commit

    stack_candidates = [
        buy_in,
        hero_chips + hero_commit,
        villain_chips + villain_commit,
        bb * 20,
    ]
    game_settings.small_blind = int(sb)
    game_settings.big_blind = int(bb)
    game_settings.ante = int(max(1, sb))
    game_settings.stack = int(max(stack_candidates))

    sizing = spot.get("bet_sizing", {}) if isinstance(spot.get("bet_sizing"), dict) else {}
    street_key = {1: "flop", 2: "flop", 3: "turn", 4: "river"}.get(street, "flop")
    street_cfg = sizing.get(street_key, {}) if isinstance(sizing.get(street_key), dict) else {}
    bet_sizes = _parse_sizes(street_cfg.get("bet_sizes"), [0.5])
    raise_sizes = _parse_sizes(street_cfg.get("raise_sizes"), [1.0])
    game_settings.bet_sizing = [bet_sizes, raise_sizes, raise_sizes]

    node = TreeNode()
    node.street = int(street)
    node.board = card_to_string.string_to_board(board_string) if board_string else arguments.Tensor()

    if hero_is_small_blind:
        node.current_player = constants.Players.P1
        bet1, bet2 = hero_commit, villain_commit
    else:
        node.current_player = constants.Players.P2
        bet1, bet2 = villain_commit, hero_commit

    if node.current_player == constants.Players.P1 and bet1 > bet2:
        bet2 = bet1
    if node.current_player == constants.Players.P2 and bet2 > bet1:
        bet1 = bet2

    node.bets = arguments.Tensor([float(bet1), float(bet2)])
    node.num_bets = 1 if abs(float(bet1) - float(bet2)) > 1e-9 else 0

    hero_cards = meta.get("hero_cards", [])
    hero_tokens = [_normalize_card_token(card) for card in hero_cards]
    hero_tokens = [token for token in hero_tokens if token]
    facing_amount = int(max(0, (bet2 - bet1) if hero_is_small_blind else (bet1 - bet2)))
    return node, game_settings.stack, hero_tokens, facing_amount


def main() -> int:
    started = time.perf_counter()
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as exc:
        print(json.dumps({"ok": False, "error": f"invalid_json:{exc}"}))
        return 0

    try:
        import settings.arguments as arguments
        import settings.constants as constants
        import settings.game_settings as game_settings
        import game.card_tools as card_tools
        import game.card_to_string_conversion as card_to_string
        from terminal_equity.terminal_equity import TerminalEquity
        from lookahead.resolving import Resolving
    except Exception as exc:  # pylint: disable=broad-except
        print(json.dumps({"ok": False, "error": f"import_failure:{exc}"}))
        return 0

    spot = payload.get("spot", {})
    if not isinstance(spot, dict):
        print(json.dumps({"ok": False, "error": "missing_spot"}))
        return 0
    allowed_actions = _normalize_allowed_tokens(payload.get("allowed_actions", []))

    try:
        node, effective_stack, hero_tokens, facing_amount = _build_node_from_spot(spot)
        if len(hero_tokens) != 2:
            raise RuntimeError("hero_cards_missing_or_invalid")
        hero_hand_string = "".join(hero_tokens)
        hero_hand_idx = int(card_tools.string_to_hole_index(hero_hand_string))

        hero_range = arguments.Tensor(game_settings.hand_count).fill_(0)
        hero_range[hero_hand_idx] = 1.0

        hero_board = card_to_string.string_to_board(hero_hand_string)
        if node.board.dim() == 1 and node.board.size(0) > 0:
            opp_board = torch.cat([node.board, hero_board], dim=0)
        else:
            opp_board = hero_board
        opponent_range = card_tools.get_uniform_range(opp_board)

        te = TerminalEquity()
        te.set_board(node.board)
        resolving = Resolving(te)
        resolving.resolve_first_node(node, hero_range, opponent_range)

        possible_actions = resolving.get_possible_actions()
        weighted: List[Tuple[str, float]] = []
        for idx in range(int(possible_actions.size(0))):
            action_value = int(possible_actions[idx].item())
            prob = float(resolving.get_action_strategy(possible_actions[idx])[hero_hand_idx].item())
            token = _action_token_from_bet_value(action_value, facing_amount=facing_amount)
            if token.startswith("raise:"):
                try:
                    amount = int(float(token.split(":", 1)[1]))
                except (TypeError, ValueError):
                    amount = 0
                if amount >= int(effective_stack):
                    token = f"raise:{int(effective_stack)}"
            weighted.append((token, max(0.0, prob)))

        if not weighted:
            fallback = "call" if facing_amount > 0 else "check"
            weighted = [(fallback, 1.0)]

        weighted.sort(key=lambda row: row[1], reverse=True)
        filtered = [(token, freq) for token, freq in weighted if _token_allowed(token, allowed_actions)]
        selected_pool = filtered if filtered else weighted

        chosen_action = selected_pool[0][0]
        total_freq = sum(freq for _, freq in selected_pool)
        if total_freq <= 0:
            total_freq = 1.0
        root_actions = [_row_from_token(token, freq / total_freq) for token, freq in selected_pool]

        elapsed = time.perf_counter() - started
        print(
            json.dumps(
                {
                    "ok": True,
                    "chosen_action": chosen_action,
                    "root_actions": root_actions,
                    "meta": {
                        "elapsed_sec": elapsed,
                        "adapter": "dyypholdem_resolving",
                        "allowed_actions_in": allowed_actions,
                    },
                }
            )
        )
        return 0
    except Exception as exc:  # pylint: disable=broad-except
        elapsed = time.perf_counter() - started
        print(json.dumps({"ok": False, "error": f"adapter_runtime_error:{exc}", "elapsed_sec": elapsed}))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
