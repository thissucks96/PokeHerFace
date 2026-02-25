#!/usr/bin/env python
"""Bridge server: receives spot JSON, generates node-lock, runs shark_cli, returns result."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from llm_client import get_llm_intuition, get_llm_intuition_candidates


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SHARK_CLI = ROOT / "1_Engine_Core" / "build_ninja_vcpkg_rel" / "shark_cli.exe"
DEFAULT_LOCAL_MODEL = os.environ.get("BRIDGE_DEFAULT_LOCAL_MODEL", "qwen3-coder:30b")
DEFAULT_LLM_CONFIG = {
    "provider": "local",
    "model": DEFAULT_LOCAL_MODEL,
    "preset": "local_qwen3_coder_30b",
}
ENFORCE_PRIMARY_LOCAL_ONLY = os.environ.get("ENFORCE_PRIMARY_LOCAL_ONLY", "1").strip() not in {"0", "false", "False"}
PROD_CLASS1_MULTI_NODE_LIVE = os.environ.get("PROD_CLASS1_MULTI_NODE_LIVE", "1").strip() not in {"0", "false", "False"}
PROD_RIVER_MULTI_NODE_SHADOW = os.environ.get("PROD_RIVER_MULTI_NODE_SHADOW", "1").strip() not in {"0", "false", "False"}
BENCHMARK_MODE_BYPASS_ROUTING = os.environ.get("BENCHMARK_MODE_BYPASS_ROUTING", "1").strip() not in {
    "0",
    "false",
    "False",
}
try:
    DEFAULT_EV_KEEP_MARGIN = float(os.environ.get("EV_KEEP_MARGIN", "0.001"))
except ValueError:
    DEFAULT_EV_KEEP_MARGIN = 0.001
try:
    TURN_CANDIDATE_COUNT = int(os.environ.get("TURN_CANDIDATE_COUNT", "3"))
except ValueError:
    TURN_CANDIDATE_COUNT = 3


class SolveRequest(BaseModel):
    spot: Dict[str, Any] = Field(..., description="spot.json payload for shark_cli")
    timeout_sec: int = Field(default=900, ge=10, le=3600)
    quiet: bool = Field(default=True)
    compute_baseline_delta: bool = Field(
        default=False,
        description="Deprecated compatibility flag; baseline-vs-locked scoring now runs automatically.",
    )
    auto_select_best: bool = Field(
        default=True,
        description="If true, run baseline+locked and return whichever has lower exploitability.",
    )
    ev_keep_margin: float = Field(
        default=DEFAULT_EV_KEEP_MARGIN,
        ge=0.0,
        le=1.0,
        description="Keep lock only if locked_exploitability + margin < baseline_exploitability.",
    )
    llm: Optional[Dict[str, Any]] = Field(
        default=None,
        description=(
            "LLM selector config. Defaults to local qwen3-coder:30b when omitted. Examples: "
            "{'preset':'mock'} | {'preset':'openai_fast'} | {'preset':'openai_52'} | "
            "{'preset':'local_gpt_oss_20b'} | {'preset':'local_qwen3_coder_30b'} | "
            "{'preset':'local_deepseek_coder_33b'} | {'preset':'local_llama3_8b'} | "
            "{'provider':'openai','model':'gpt-5-mini'}."
        ),
    )
    opponent_profile: Optional[Dict[str, Any]] = Field(
        default=None,
        description="Optional opponent profile context for prompt shaping (vpip/pfr/agg/etc).",
    )
    enable_multi_node_locks: bool = Field(
        default=False,
        description="Enable multi-node lock generation/validation. Default keeps root-only lock behavior.",
    )


app = FastAPI(title="PokerBot Bridge", version="0.1.0")


def _validate_spot(spot: Dict[str, Any]) -> None:
    required = ("hero_range", "villain_range", "board")
    missing = [k for k in required if k not in spot]
    if missing:
        raise HTTPException(status_code=400, detail=f"spot payload missing required keys: {missing}")


def _resolve_shark_cli() -> Path:
    env_path = os.environ.get("SHARK_CLI_PATH")
    if env_path:
        candidate = Path(env_path)
        if candidate.exists():
            return candidate
        raise HTTPException(status_code=500, detail=f"SHARK_CLI_PATH does not exist: {candidate}")

    if DEFAULT_SHARK_CLI.exists():
        return DEFAULT_SHARK_CLI

    raise HTTPException(
        status_code=500,
        detail=(
            "shark_cli.exe not found. Build it first or set SHARK_CLI_PATH. "
            f"Checked: {DEFAULT_SHARK_CLI}"
        ),
    )


def _run_shark_cli(
    shark_cli: Path,
    *,
    spot_payload: Dict[str, Any],
    node_lock_payload: Optional[Dict[str, Any]],
    timeout_sec: int,
    quiet: bool,
) -> Dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="pokebot_solve_") as tmp:
        tmp_dir = Path(tmp)
        spot_path = tmp_dir / "spot.json"
        lock_path = tmp_dir / "node_lock.json"
        result_path = tmp_dir / "result.json"

        spot_path.write_text(json.dumps(spot_payload, indent=2) + "\n", encoding="utf-8")
        if node_lock_payload is not None:
            lock_path.write_text(json.dumps(node_lock_payload, indent=2) + "\n", encoding="utf-8")

        cmd = [
            str(shark_cli),
            "--input",
            str(spot_path),
            "--output",
            str(result_path),
        ]
        if node_lock_payload is not None:
            cmd.extend(["--node-lock", str(lock_path)])
        if quiet:
            cmd.append("--quiet")

        start = time.perf_counter()
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout_sec,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise HTTPException(status_code=504, detail=f"shark_cli timed out after {timeout_sec}s") from exc
        elapsed = time.perf_counter() - start

        if proc.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail={
                    "error": "shark_cli failed",
                    "returncode": proc.returncode,
                    "stdout": proc.stdout[-4000:],
                    "stderr": proc.stderr[-4000:],
                },
            )

        if not result_path.exists():
            raise HTTPException(status_code=500, detail="shark_cli did not produce result.json")

        try:
            result = json.loads(result_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=500, detail=f"invalid result.json from shark_cli: {exc}") from exc

        return {
            "result": result,
            "solver_wall_time_sec": elapsed,
        }


def _to_float_or_none(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _extract_allowed_root_actions(result_payload: Dict[str, Any]) -> list[str]:
    allowed: list[str] = []
    root_actions = result_payload.get("root_actions", [])
    if not isinstance(root_actions, list):
        return allowed
    for item in root_actions:
        if not isinstance(item, dict):
            continue
        action = str(item.get("action", "")).strip().lower()
        if not action:
            continue
        if action in {"bet", "raise"}:
            amount = item.get("amount")
            if isinstance(amount, (int, float)):
                allowed.append(f"{action}:{int(amount)}")
            else:
                allowed.append(action)
        else:
            allowed.append(action)
    # Preserve order but dedupe.
    unique: list[str] = []
    seen = set()
    for action in allowed:
        if action in seen:
            continue
        seen.add(action)
        unique.append(action)
    return unique


def _extract_node_lock_catalog(result_payload: Dict[str, Any]) -> list[Dict[str, Any]]:
    catalog = result_payload.get("node_lock_catalog", [])
    if not isinstance(catalog, list):
        return []
    out: list[Dict[str, Any]] = []
    for item in catalog:
        if not isinstance(item, dict):
            continue
        node_id = str(item.get("node_id", "")).strip()
        street = str(item.get("street", "")).strip().lower()
        actions = item.get("actions", [])
        if not node_id or not isinstance(actions, list):
            continue
        out.append({"node_id": node_id, "street": street, "actions": actions})
    return out


def _detect_spot_street(spot: Dict[str, Any]) -> str:
    board = spot.get("board", [])
    if isinstance(board, list):
        if len(board) >= 5:
            return "river"
        if len(board) == 4:
            return "turn"
    return "flop"


def _avg_lock_confidence(node_lock: Optional[Dict[str, Any]]) -> Optional[float]:
    if not isinstance(node_lock, dict):
        return None
    targets = node_lock.get("node_locks", [])
    if not isinstance(targets, list) or not targets:
        return None
    values = []
    for target in targets:
        if not isinstance(target, dict):
            continue
        confidence = target.get("confidence")
        if isinstance(confidence, (int, float)):
            values.append(float(confidence))
    if not values:
        return None
    return sum(values) / float(len(values))


def _confidence_tag(confidence: Optional[float]) -> str:
    if confidence is None:
        return "unknown"
    if confidence >= 0.75:
        return "high"
    if confidence >= 0.4:
        return "medium"
    return "low"


def _is_local_request(llm_config: Dict[str, Any]) -> bool:
    provider = str(llm_config.get("provider", "")).strip().lower()
    preset = str(llm_config.get("preset", "")).strip().lower()
    return provider == "local" or preset.startswith("local_")


def _enforce_local_production_policy(llm_config: Dict[str, Any]) -> None:
    if not ENFORCE_PRIMARY_LOCAL_ONLY or not _is_local_request(llm_config):
        return
    mode = str(llm_config.get("mode", "")).strip().lower()
    requested_model = str(llm_config.get("model", "")).strip()
    requested_preset = str(llm_config.get("preset", "")).strip()
    if mode == "benchmark":
        return
    if requested_model and requested_model != DEFAULT_LOCAL_MODEL:
        raise HTTPException(
            status_code=400,
            detail=f"Local production policy enforces model={DEFAULT_LOCAL_MODEL}; use mode=benchmark for challengers.",
        )
    if requested_preset and requested_preset != "local_qwen3_coder_30b":
        raise HTTPException(
            status_code=400,
            detail="Local production policy only allows preset local_qwen3_coder_30b unless mode=benchmark.",
        )


def _extract_rollout_classes(spot: Dict[str, Any]) -> Dict[str, bool]:
    meta = spot.get("meta")
    if not isinstance(meta, dict):
        return {}
    classes = meta.get("rollout_classes")
    if not isinstance(classes, dict):
        return {}
    out: Dict[str, bool] = {}
    for key, value in classes.items():
        out[str(key)] = bool(value)
    return out


def _resolve_multi_node_policy(request: SolveRequest, llm_config: Dict[str, Any]) -> tuple[bool, str, Dict[str, bool]]:
    requested = bool(request.enable_multi_node_locks)
    classes = _extract_rollout_classes(request.spot)
    is_class1 = bool(classes.get("turn_probe_punish", False))
    is_class23 = bool(classes.get("river_bigbet_overfold_punish", False) or classes.get("river_underbluff_defense", False))
    mode = str(llm_config.get("mode", "")).strip().lower()

    if BENCHMARK_MODE_BYPASS_ROUTING and mode == "benchmark":
        return requested, "benchmark_mode_bypass", classes
    if PROD_RIVER_MULTI_NODE_SHADOW and is_class23:
        return False, "forced_off_class23_shadow", classes
    if PROD_CLASS1_MULTI_NODE_LIVE and is_class1:
        return True, "forced_on_class1_live", classes
    return requested, "request_flag", classes


@app.get("/health")
def health() -> Dict[str, Any]:
    shark_cli = _resolve_shark_cli()
    return {
        "status": "ok",
        "shark_cli": str(shark_cli),
        "llm_default_provider": DEFAULT_LLM_CONFIG["provider"],
        "llm_default_model": DEFAULT_LLM_CONFIG["model"],
        "ev_keep_margin": DEFAULT_EV_KEEP_MARGIN,
        "enforce_primary_local_only": ENFORCE_PRIMARY_LOCAL_ONLY,
        "prod_class1_multi_node_live": PROD_CLASS1_MULTI_NODE_LIVE,
        "prod_river_multi_node_shadow": PROD_RIVER_MULTI_NODE_SHADOW,
        "benchmark_mode_bypass_routing": BENCHMARK_MODE_BYPASS_ROUTING,
        "turn_candidate_count": TURN_CANDIDATE_COUNT,
    }


@app.post("/solve")
def solve(request: SolveRequest) -> Dict[str, Any]:
    bridge_started = time.perf_counter()
    _validate_spot(request.spot)
    shark_cli = _resolve_shark_cli()
    llm_config = dict(request.llm or DEFAULT_LLM_CONFIG)
    _enforce_local_production_policy(llm_config)

    # Pass 1: baseline (no lock) is always computed first.
    baseline_run = _run_shark_cli(
        shark_cli,
        spot_payload=request.spot,
        node_lock_payload=None,
        timeout_sec=request.timeout_sec,
        quiet=request.quiet,
    )
    baseline_result = baseline_run["result"]
    baseline_solver_time = baseline_run["solver_wall_time_sec"]
    allowed_root_actions = _extract_allowed_root_actions(baseline_result)
    node_lock_catalog = _extract_node_lock_catalog(baseline_result)

    llm_started = time.perf_counter()
    llm_error = None
    node_lock = None
    multi_node_enabled, multi_node_policy_reason, rollout_classes = _resolve_multi_node_policy(request, llm_config)
    spot_street = _detect_spot_street(request.spot)
    candidate_mode_enabled = (
        multi_node_enabled
        and spot_street == "turn"
        and _is_local_request(llm_config)
        and TURN_CANDIDATE_COUNT > 1
    )
    llm_config["allowed_root_actions"] = allowed_root_actions
    llm_config["node_lock_catalog"] = node_lock_catalog
    llm_config["opponent_profile"] = dict(request.opponent_profile or {})
    llm_config["enable_multi_node_locks"] = multi_node_enabled
    llm_candidates: list[Dict[str, Any]] = []
    try:
        if candidate_mode_enabled:
            llm_candidates = get_llm_intuition_candidates(
                request.spot,
                llm_config,
                candidate_count=TURN_CANDIDATE_COUNT,
            )
        else:
            node_lock = get_llm_intuition(request.spot, llm_config)
            if node_lock is not None:
                llm_candidates = [node_lock]
    except Exception as exc:  # pylint: disable=broad-except
        llm_error = str(exc)
    llm_elapsed = time.perf_counter() - llm_started

    locked_result = None
    locked_solver_time = 0.0
    locked_solver_time_total = 0.0
    locked_candidate_solve_count = 0
    candidate_errors: list[str] = []
    if llm_candidates:
        candidate_runs: list[Dict[str, Any]] = []
        for idx, candidate in enumerate(llm_candidates):
            try:
                locked_run = _run_shark_cli(
                    shark_cli,
                    spot_payload=request.spot,
                    node_lock_payload=candidate,
                    timeout_sec=request.timeout_sec,
                    quiet=request.quiet,
                )
            except HTTPException as exc:
                if len(candidate_errors) < 5:
                    candidate_errors.append(f"candidate_{idx}:{exc.detail}")
                continue

            candidate_result = locked_run["result"]
            candidate_time = locked_run["solver_wall_time_sec"]
            candidate_exp = _to_float_or_none(candidate_result.get("final_exploitability_pct"))
            locked_solver_time_total += candidate_time
            locked_candidate_solve_count += 1
            candidate_runs.append(
                {
                    "node_lock": candidate,
                    "result": candidate_result,
                    "solver_time": candidate_time,
                    "exploitability": candidate_exp,
                }
            )

        if candidate_runs:
            best = min(
                candidate_runs,
                key=lambda row: row["exploitability"] if row["exploitability"] is not None else float("inf"),
            )
            node_lock = best["node_lock"]
            locked_result = best["result"]
            locked_solver_time = float(best["solver_time"])
        elif llm_error is None:
            llm_error = "all_locked_candidate_solves_failed"
    elif node_lock is not None:
        # Back-compat path: if a direct node_lock exists and candidates list is empty, still solve once.
        locked_run = _run_shark_cli(
            shark_cli,
            spot_payload=request.spot,
            node_lock_payload=node_lock,
            timeout_sec=request.timeout_sec,
            quiet=request.quiet,
        )
        locked_result = locked_run["result"]
        locked_solver_time = locked_run["solver_wall_time_sec"]
        locked_solver_time_total = locked_solver_time
        locked_candidate_solve_count = 1

    baseline_exp = _to_float_or_none(baseline_result.get("final_exploitability_pct"))
    locked_exp = _to_float_or_none(locked_result.get("final_exploitability_pct")) if locked_result else None
    exploitability_delta = (locked_exp - baseline_exp) if (locked_exp is not None and baseline_exp is not None) else None

    selected_strategy = "baseline_gto"
    selection_reason = "baseline_only"
    result = baseline_result
    node_lock_kept = False
    if request.auto_select_best and locked_result is not None and baseline_exp is not None and locked_exp is not None:
        keep_threshold = baseline_exp - request.ev_keep_margin
        if locked_exp < keep_threshold:
            selected_strategy = "llm_locked"
            selection_reason = (
                "locked_result_improved_exploitability_best_of_n"
                if candidate_mode_enabled
                else "locked_result_improved_exploitability"
            )
            result = locked_result
            node_lock_kept = True
        else:
            selected_strategy = "baseline_gto"
            selection_reason = "locked_result_not_better_than_baseline_with_margin"
            result = baseline_result
            node_lock_kept = False
    elif locked_result is not None and not request.auto_select_best:
        selected_strategy = "llm_locked"
        selection_reason = "auto_select_best_disabled"
        result = locked_result
        node_lock_kept = True
    elif locked_result is not None and baseline_exp is None and locked_exp is not None:
        selected_strategy = "llm_locked"
        selection_reason = "baseline_missing_metric"
        result = locked_result
        node_lock_kept = True
    elif llm_error:
        selection_reason = "llm_generation_failed_using_baseline"
    elif node_lock is None:
        selection_reason = "no_llm_lock_available_using_baseline"
    else:
        selection_reason = "locked_result_missing_metric_using_baseline"

    lock_confidence = _avg_lock_confidence(node_lock)
    lock_quality_score = (
        (0.5 if node_lock_kept else 0.0)
        + (0.3 if bool(result.get("node_lock", {}).get("applied", False)) else 0.0)
        + (0.2 if exploitability_delta is not None and exploitability_delta < 0.0 else 0.0)
    )

    total_bridge_time = time.perf_counter() - bridge_started

    return {
        "status": "ok",
        "node_lock": node_lock,
        "node_lock_kept": node_lock_kept,
        "selected_strategy": selected_strategy,
        "selection_reason": selection_reason,
        "allowed_root_actions": allowed_root_actions,
        "multi_node_policy": {
            "requested": bool(request.enable_multi_node_locks),
            "enabled": multi_node_enabled,
            "reason": multi_node_policy_reason,
            "rollout_classes": rollout_classes,
        },
        "result": result,
        "baseline_result": baseline_result,
        "locked_result": locked_result,
        "metrics": {
            "llm_time_sec": llm_elapsed,
            "solver_time_sec": locked_solver_time if selected_strategy == "llm_locked" else baseline_solver_time,
            "baseline_solver_time_sec": baseline_solver_time,
            "locked_solver_time_sec": locked_solver_time,
            "locked_solver_time_total_sec": locked_solver_time_total,
            "total_bridge_time_sec": total_bridge_time,
            "lock_applied": bool(result.get("node_lock", {}).get("applied", False)),
            "lock_applications": result.get("node_lock", {}).get("applications", 0),
            "final_exploitability_pct": result.get("final_exploitability_pct"),
            "baseline_exploitability_pct": baseline_result.get("final_exploitability_pct"),
            "locked_exploitability_pct": locked_result.get("final_exploitability_pct") if locked_result else None,
            "exploitability_delta_pct": exploitability_delta,
            "ev_keep_margin": request.ev_keep_margin,
            "locked_beats_margin_gate": (
                (locked_exp is not None and baseline_exp is not None and locked_exp < (baseline_exp - request.ev_keep_margin))
                if request.auto_select_best
                else None
            ),
            "lock_confidence": lock_confidence,
            "lock_confidence_tag": _confidence_tag(lock_confidence),
            "lock_quality_score": lock_quality_score,
            "node_lock_target_count": (
                len(node_lock.get("node_locks", []))
                if isinstance(node_lock, dict) and isinstance(node_lock.get("node_locks"), list)
                else 0
            ),
            "llm_candidate_mode_enabled": candidate_mode_enabled,
            "llm_candidate_target_count": TURN_CANDIDATE_COUNT if candidate_mode_enabled else 1,
            "llm_candidate_generated_count": len(llm_candidates),
            "llm_candidate_solve_count": locked_candidate_solve_count,
            "llm_candidate_errors": candidate_errors,
            "multi_node_requested": bool(request.enable_multi_node_locks),
            "multi_node_enabled": multi_node_enabled,
            "multi_node_policy_reason": multi_node_policy_reason,
            "llm_error": llm_error,
        },
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("bridge_server:app", host="127.0.0.1", port=8000, reload=False)
