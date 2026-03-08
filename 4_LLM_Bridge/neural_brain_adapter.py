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
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def _resolve_neural_root() -> Path:
    env_root = str(os.environ.get("NEURAL_BRAIN_ROOT", "")).strip()
    default_root = ROOT / "2_Neural_Brain"
    if not env_root:
        return default_root
    candidate = Path(env_root)
    if not candidate.is_absolute():
        candidate = (ROOT / candidate).resolve()
    src_dir = candidate / "src"
    if (src_dir / "settings" / "arguments.py").exists():
        return candidate
    return default_root


NEURAL_ROOT = _resolve_neural_root()
NEURAL_SRC = (NEURAL_ROOT / "src").resolve()
if str(NEURAL_SRC) not in sys.path:
    sys.path.insert(0, str(NEURAL_SRC))
os.chdir(NEURAL_SRC)

from shared_feature_contract import FEATURE_DEFAULT_INPUT_DIM, detect_street, feature_vector


def _env_flag(name: str, default: str = "1") -> bool:
    return str(os.environ.get(name, default)).strip().lower() not in {"0", "false", "no", "off"}


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


def _resolve_local_policy_checkpoint() -> Path:
    raw = str(
        os.environ.get(
            "NEURAL_BRAIN_POLICY_CHECKPOINT_PATH",
            str(ROOT / "2_Neural_Brain" / "local_pipeline" / "artifacts" / "checkpoints" / "neural_policy_shadow_v1.pt"),
        )
    ).strip()
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = (ROOT / candidate).resolve()
    return candidate


LOCAL_POLICY_ENABLED = _env_flag("NEURAL_BRAIN_LOCAL_POLICY_ENABLED", "1")
LOCAL_POLICY_CHECKPOINT = _resolve_local_policy_checkpoint()
_LOCAL_POLICY_BUNDLE: dict[str, Any] | None = None


def _hero_range_from_cards(hero_cards: list[str]) -> str:
    tokens = [_normalize_card_token(card) for card in hero_cards]
    tokens = [token for token in tokens if token]
    if len(tokens) != 2:
        return ""
    rank_value = {r: idx for idx, r in enumerate("23456789TJQKA", start=2)}
    ranks = sorted((token[0] for token in tokens), key=lambda r: rank_value.get(r, 0), reverse=True)
    if ranks[0] == ranks[1]:
        return f"{ranks[0]}{ranks[1]}"
    suited = "s" if tokens[0][1] == tokens[1][1] else "o"
    return f"{ranks[0]}{ranks[1]}{suited}"


def _build_policy_feature_inputs(spot: Dict[str, Any], runtime_profile: str) -> tuple[dict[str, Any], dict[str, Any]]:
    meta = spot.get("meta") if isinstance(spot.get("meta"), dict) else {}
    board = spot.get("board") if isinstance(spot.get("board"), list) else []
    hero_cards = meta.get("hero_cards") if isinstance(meta.get("hero_cards"), list) else []
    hero_range = str(spot.get("hero_range") or "").strip()
    if not hero_range:
        hero_range = _hero_range_from_cards(hero_cards)
    source = {
        "runtime_profile": str(runtime_profile or "unknown").strip().lower(),
        "street": detect_street(board),
    }
    features = {
        "hero_range": hero_range,
        "villain_range": str(spot.get("villain_range") or "").strip(),
        "board": board,
        "active_node_path": str(spot.get("active_node_path") or "").strip(),
        "in_position_player": int(float(spot.get("in_position_player", 2) or 2)),
        "starting_stack": int(float(spot.get("starting_stack", 0) or 0)),
        "starting_pot": int(float(spot.get("starting_pot", 0) or 0)),
        "minimum_bet": int(float(spot.get("minimum_bet", 0) or 0)),
        "all_in_threshold": float(spot.get("all_in_threshold", 0.67) or 0.67),
        "iterations": int(float(spot.get("iterations", 0) or 0)),
        "min_exploitability": float(spot.get("min_exploitability", -1.0) or -1.0),
        "thread_count": int(float(spot.get("thread_count", 0) or 0)),
        "remove_donk_bets": bool(spot.get("remove_donk_bets", True)),
        "raise_cap": int(float(spot.get("raise_cap", 0) or 0)),
        "compress_strategy": bool(spot.get("compress_strategy", True)),
        "bet_sizing": spot.get("bet_sizing") if isinstance(spot.get("bet_sizing"), dict) else {},
        "facing_bet": _safe_int(meta.get("facing_bet"), 0) or _extract_last_bet_from_node_path(spot.get("active_node_path", "")),
        "hero_street_commit": _safe_int(meta.get("hero_street_commit"), 0),
        "villain_street_commit": _safe_int(meta.get("villain_street_commit"), 0),
        "current_pot": _safe_int(meta.get("current_pot", spot.get("starting_pot")), 0),
        "hero_chips": _safe_int(meta.get("current_hero_chips"), 0),
        "villain_chips": _safe_int(meta.get("current_villain_chips"), 0),
        "hero_is_small_blind": bool(meta.get("hero_is_small_blind", True)),
        "hero_cards": hero_cards,
    }
    return source, features


def _load_local_policy_bundle() -> tuple[dict[str, Any] | None, str | None]:
    global _LOCAL_POLICY_BUNDLE
    if not LOCAL_POLICY_ENABLED:
        return None, "local_policy_disabled"
    if _LOCAL_POLICY_BUNDLE is not None:
        return _LOCAL_POLICY_BUNDLE, None
    if not LOCAL_POLICY_CHECKPOINT.exists():
        return None, f"local_policy_checkpoint_missing:{LOCAL_POLICY_CHECKPOINT}"
    try:
        from scripts.train_local_neural import PolicyMLP, _predict_logits
    except Exception as exc:  # pylint: disable=broad-except
        return None, f"local_policy_import_failure:{exc}"
    try:
        checkpoint = torch.load(LOCAL_POLICY_CHECKPOINT, map_location="cpu")
        action_space = checkpoint.get("action_space")
        if not isinstance(action_space, list) or not action_space:
            return None, "local_policy_missing_action_space"
        architecture = str(checkpoint.get("architecture") or "flat").strip().lower()
        input_dim = int(checkpoint.get("input_dim") or FEATURE_DEFAULT_INPUT_DIM)
        model = PolicyMLP(
            input_dim=input_dim,
            hidden_dim=256,
            num_layers=3,
            dropout=0.1,
            output_dim=len(action_space),
            architecture=architecture,
        )
        model.load_state_dict(checkpoint["model_state_dict"])
        model.eval()
        _LOCAL_POLICY_BUNDLE = {
            "model": model,
            "action_space": [str(a) for a in action_space],
            "action_to_index": {str(a): i for i, a in enumerate(action_space)},
            "input_dim": input_dim,
            "architecture": architecture,
            "feature_schema_version": str(checkpoint.get("feature_schema_version") or ""),
            "feature_contract_hash": str(checkpoint.get("feature_contract_hash") or ""),
            "predict_logits": _predict_logits,
        }
        return _LOCAL_POLICY_BUNDLE, None
    except Exception as exc:  # pylint: disable=broad-except
        return None, f"local_policy_load_failure:{exc}"


def _build_legal_mask_from_allowed(allowed_actions: list[str], action_to_index: dict[str, int]) -> torch.Tensor:
    legal = [False for _ in action_to_index]
    raise_count = 0
    for token in allowed_actions:
        normalized = _normalize_action_token(token)
        if normalized == "fold" and "fold" in action_to_index:
            legal[action_to_index["fold"]] = True
        elif normalized == "check" and "check" in action_to_index:
            legal[action_to_index["check"]] = True
        elif normalized == "call" and "call" in action_to_index:
            legal[action_to_index["call"]] = True
        elif normalized == "raise" or normalized.startswith("raise:"):
            raise_count += 1
    if raise_count > 0:
        for name in ("raise_small", "raise_big", "all_in"):
            if name in action_to_index:
                legal[action_to_index[name]] = True
    if not any(legal):
        legal = [True for _ in action_to_index]
    return torch.tensor([legal], dtype=torch.bool)


def _sorted_raise_tokens(allowed_actions: list[str]) -> list[str]:
    rows: list[tuple[str, int]] = []
    for token in allowed_actions:
        normalized = _normalize_action_token(token)
        if not normalized.startswith("raise:"):
            continue
        try:
            rows.append((normalized, int(float(normalized.split(":", 1)[1]))))
        except (TypeError, ValueError):
            continue
    rows.sort(key=lambda item: item[1])
    return [token for token, _amount in rows]


def _map_model_action_to_token(action: str, allowed_actions: list[str]) -> str:
    action = str(action or "").strip().lower()
    if action in {"fold", "check", "call"}:
        if _token_allowed(action, allowed_actions):
            return action
        return "call" if action == "check" and _token_allowed("call", allowed_actions) else action
    raise_tokens = _sorted_raise_tokens(allowed_actions)
    if action == "raise_small":
        return raise_tokens[0] if raise_tokens else ("raise" if _token_allowed("raise", allowed_actions) else "")
    if action == "raise_big":
        if len(raise_tokens) >= 2:
            return raise_tokens[-2]
        return raise_tokens[-1] if raise_tokens else ("raise" if _token_allowed("raise", allowed_actions) else "")
    if action == "all_in":
        return raise_tokens[-1] if raise_tokens else ("raise" if _token_allowed("raise", allowed_actions) else "")
    return ""


def _run_local_policy(spot: Dict[str, Any], allowed_actions: list[str], runtime_profile: str) -> tuple[dict[str, Any] | None, str | None]:
    bundle, error = _load_local_policy_bundle()
    if bundle is None:
        return None, error
    started = time.perf_counter()
    try:
        source, features = _build_policy_feature_inputs(spot, runtime_profile)
        x = torch.tensor(
            [feature_vector(source=source, features=features, input_dim=int(bundle["input_dim"]))],
            dtype=torch.float32,
        )
        legal_mask = _build_legal_mask_from_allowed(allowed_actions, bundle["action_to_index"])
        logits, _aux = bundle["predict_logits"](
            bundle["model"],
            x,
            legal_mask,
            bundle["action_space"],
            bundle["action_to_index"],
            bundle["architecture"],
        )
        probs = torch.softmax(logits, dim=1)[0].tolist()
        weighted_tokens: dict[str, float] = {}
        for action_name, prob in zip(bundle["action_space"], probs):
            token = _map_model_action_to_token(action_name, allowed_actions)
            if not token or prob <= 0.0:
                continue
            weighted_tokens[token] = weighted_tokens.get(token, 0.0) + float(prob)
        if not weighted_tokens:
            return None, "local_policy_no_allowed_projection"
        ordered = sorted(weighted_tokens.items(), key=lambda row: row[1], reverse=True)
        total = sum(freq for _token, freq in ordered) or 1.0
        root_actions = [_row_from_token(token, freq / total) for token, freq in ordered]
        elapsed = time.perf_counter() - started
        return {
            "ok": True,
            "chosen_action": ordered[0][0],
            "root_actions": root_actions,
            "meta": {
                "elapsed_sec": elapsed,
                "adapter": "local_policy_checkpoint",
                "surrogate": False,
                "checkpoint_path": str(LOCAL_POLICY_CHECKPOINT),
                "architecture": str(bundle["architecture"]),
                "feature_schema_version": str(bundle["feature_schema_version"]),
                "allowed_actions_in": allowed_actions,
            },
        }, None
    except Exception as exc:  # pylint: disable=broad-except
        return None, f"local_policy_runtime_failure:{exc}"


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


def _extract_last_bet_from_node_path(path_value: Any) -> int:
    text = str(path_value or "").strip().lower()
    if not text:
        return 0
    segments = [seg.strip() for seg in text.split("/") if seg.strip()]
    for segment in reversed(segments):
        if ":bet:" in segment:
            tail = segment.split(":bet:", 1)[1]
        elif ":raise:" in segment:
            tail = segment.split(":raise:", 1)[1]
        else:
            continue
        try:
            return max(0, int(float(tail)))
        except (TypeError, ValueError):
            continue
    return 0


def _choose_smallest_raise_token(tokens: List[str]) -> str:
    raise_tokens: List[Tuple[str, int]] = []
    for token in tokens:
        if token.startswith("raise:"):
            try:
                raise_tokens.append((token, int(float(token.split(":", 1)[1]))))
            except (TypeError, ValueError):
                continue
    if raise_tokens:
        raise_tokens.sort(key=lambda row: row[1])
        return raise_tokens[0][0]
    if "raise" in tokens:
        return "raise"
    return ""


def _simple_hand_strength(spot: Dict[str, Any]) -> float:
    meta = spot.get("meta", {}) if isinstance(spot.get("meta"), dict) else {}
    hero_cards = meta.get("hero_cards", [])
    if not isinstance(hero_cards, list) or len(hero_cards) != 2:
        return 0.25
    hero_tokens = [_normalize_card_token(card) for card in hero_cards]
    hero_tokens = [token for token in hero_tokens if token]
    if len(hero_tokens) != 2:
        return 0.25

    board_raw = spot.get("board", [])
    board_tokens = [_normalize_card_token(card) for card in board_raw] if isinstance(board_raw, list) else []
    board_tokens = [token for token in board_tokens if token]

    rank_value = {r: idx + 2 for idx, r in enumerate("23456789TJQKA")}
    hero_ranks = [rank_value[token[0]] for token in hero_tokens]
    hero_suits = [token[1] for token in hero_tokens]
    board_ranks = [rank_value[token[0]] for token in board_tokens]
    board_suits = [token[1] for token in board_tokens]

    score = 0.2
    if hero_ranks[0] == hero_ranks[1]:
        score += 0.2
        if hero_ranks[0] >= 11:
            score += 0.15
    if hero_suits[0] == hero_suits[1]:
        score += 0.08
    if max(hero_ranks) >= 13:
        score += 0.08
    if abs(hero_ranks[0] - hero_ranks[1]) <= 2:
        score += 0.05

    if board_ranks:
        board_max = max(board_ranks)
        if max(hero_ranks) >= board_max:
            score += 0.05
        shared_pairs = 0
        for hr in hero_ranks:
            if hr in board_ranks:
                shared_pairs += 1
        if shared_pairs >= 1:
            score += 0.18
        if shared_pairs >= 2:
            score += 0.25
        hero_flush_count = max(
            board_suits.count(hero_suits[0]) + 1,
            board_suits.count(hero_suits[1]) + 1,
        )
        if hero_flush_count >= 4:
            score += 0.1
        unique_ranks = sorted(set(hero_ranks + board_ranks))
        straight_draw = False
        for i in range(len(unique_ranks) - 3):
            if unique_ranks[i + 3] - unique_ranks[i] <= 4:
                straight_draw = True
                break
        if straight_draw:
            score += 0.06

    return max(0.05, min(0.95, score))


def _surrogate_neural_policy(spot: Dict[str, Any], allowed_actions: List[str], reason: str) -> Dict[str, Any]:
    allowed = _normalize_allowed_tokens(allowed_actions)
    if not allowed:
        allowed = ["check"]

    meta = spot.get("meta", {}) if isinstance(spot.get("meta"), dict) else {}
    facing_bet = 0
    try:
        facing_bet = max(0, int(float(meta.get("facing_bet", 0))))
    except (TypeError, ValueError):
        facing_bet = 0
    if facing_bet <= 0:
        facing_bet = _extract_last_bet_from_node_path(spot.get("active_node_path", ""))
    pot = 0.0
    try:
        pot = float(meta.get("current_pot", spot.get("starting_pot", 0)))
    except (TypeError, ValueError):
        pot = 0.0
    pot = max(1.0, pot)

    strength = _simple_hand_strength(spot)
    raise_token = _choose_smallest_raise_token(allowed)

    weights: List[Tuple[str, float]] = []
    if facing_bet > 0:
        call_pressure = min(1.0, facing_bet / (pot + facing_bet))
        fold_w = max(0.05, min(0.85, 0.55 - (0.7 * strength) + (0.35 * call_pressure)))
        call_w = max(0.05, min(0.90, 0.35 + (0.5 * strength) - (0.15 * call_pressure)))
        raise_w = max(0.0, 1.0 - fold_w - call_w)
        if "fold" in allowed:
            weights.append(("fold", fold_w))
        if "call" in allowed:
            weights.append(("call", call_w))
        elif "check" in allowed:
            weights.append(("check", call_w))
        if raise_token:
            weights.append((raise_token, raise_w))
    else:
        check_w = max(0.1, min(0.9, 0.65 - (0.45 * strength)))
        raise_w = max(0.1, 1.0 - check_w)
        if "check" in allowed:
            weights.append(("check", check_w))
        elif "call" in allowed:
            weights.append(("call", check_w))
        if raise_token:
            weights.append((raise_token, raise_w))
        elif "call" in allowed and not any(token == "call" for token, _ in weights):
            weights.append(("call", raise_w))

    if not weights:
        token = "call" if "call" in allowed else ("check" if "check" in allowed else allowed[0])
        weights = [(token, 1.0)]

    total = sum(max(0.0, freq) for _, freq in weights)
    if total <= 0:
        total = 1.0
    normalized = [(token, max(0.0, freq) / total) for token, freq in weights]
    normalized.sort(key=lambda row: row[1], reverse=True)
    chosen_action = normalized[0][0]
    root_actions = [_row_from_token(token, freq) for token, freq in normalized]
    return {
        "ok": True,
        "chosen_action": chosen_action,
        "root_actions": root_actions,
        "meta": {
            "elapsed_sec": 0.0,
            "adapter": "surrogate_neural_policy",
            "surrogate": True,
            "reason": reason,
            "allowed_actions_in": allowed,
        },
    }


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
    spot = payload.get("spot", {})
    if not isinstance(spot, dict):
        print(json.dumps({"ok": False, "error": "missing_spot"}))
        return 0
    allowed_actions = _normalize_allowed_tokens(payload.get("allowed_actions", []))
    runtime_profile = str(payload.get("runtime_profile") or "unknown").strip().lower()

    local_payload, local_error = _run_local_policy(spot, allowed_actions, runtime_profile)
    if isinstance(local_payload, dict):
        print(json.dumps(local_payload))
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
        reason = local_error or f"import_failure:{exc}"
        fallback = _surrogate_neural_policy(spot, allowed_actions, reason=reason)
        print(json.dumps(fallback))
        return 0

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
        reason = local_error or f"runtime_failure:{exc}"
        fallback = _surrogate_neural_policy(spot, allowed_actions, reason=reason)
        if isinstance(fallback.get("meta"), dict):
            fallback["meta"]["elapsed_sec"] = elapsed
        print(json.dumps(fallback))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
