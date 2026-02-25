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

from llm_client import get_llm_intuition


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SHARK_CLI = ROOT / "1_Engine_Core" / "build_ninja_vcpkg_rel" / "shark_cli.exe"
DEFAULT_LOCAL_MODEL = os.environ.get("BRIDGE_DEFAULT_LOCAL_MODEL", "qwen3-coder:30b")
DEFAULT_LLM_CONFIG = {
    "provider": "local",
    "model": DEFAULT_LOCAL_MODEL,
    "preset": "local_qwen3_coder_30b",
}
try:
    DEFAULT_EV_KEEP_MARGIN = float(os.environ.get("EV_KEEP_MARGIN", "0.005"))
except ValueError:
    DEFAULT_EV_KEEP_MARGIN = 0.005


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
            "{'preset':'local_deepseek_coder_33b'} | "
            "{'provider':'openai','model':'gpt-5-mini'}."
        ),
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


@app.get("/health")
def health() -> Dict[str, Any]:
    shark_cli = _resolve_shark_cli()
    return {
        "status": "ok",
        "shark_cli": str(shark_cli),
        "llm_default_provider": DEFAULT_LLM_CONFIG["provider"],
        "llm_default_model": DEFAULT_LLM_CONFIG["model"],
        "ev_keep_margin": DEFAULT_EV_KEEP_MARGIN,
    }


@app.post("/solve")
def solve(request: SolveRequest) -> Dict[str, Any]:
    bridge_started = time.perf_counter()
    _validate_spot(request.spot)
    shark_cli = _resolve_shark_cli()

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

    llm_started = time.perf_counter()
    llm_error = None
    node_lock = None
    llm_config = dict(request.llm or DEFAULT_LLM_CONFIG)
    llm_config["allowed_root_actions"] = allowed_root_actions
    try:
        node_lock = get_llm_intuition(request.spot, llm_config)
    except Exception as exc:  # pylint: disable=broad-except
        llm_error = str(exc)
    llm_elapsed = time.perf_counter() - llm_started

    locked_result = None
    locked_solver_time = 0.0
    if node_lock is not None:
        locked_run = _run_shark_cli(
            shark_cli,
            spot_payload=request.spot,
            node_lock_payload=node_lock,
            timeout_sec=request.timeout_sec,
            quiet=request.quiet,
        )
        locked_result = locked_run["result"]
        locked_solver_time = locked_run["solver_wall_time_sec"]

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
            selection_reason = "locked_result_improved_exploitability"
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

    total_bridge_time = time.perf_counter() - bridge_started

    return {
        "status": "ok",
        "node_lock": node_lock,
        "node_lock_kept": node_lock_kept,
        "selected_strategy": selected_strategy,
        "selection_reason": selection_reason,
        "allowed_root_actions": allowed_root_actions,
        "result": result,
        "baseline_result": baseline_result,
        "locked_result": locked_result,
        "metrics": {
            "llm_time_sec": llm_elapsed,
            "solver_time_sec": locked_solver_time if selected_strategy == "llm_locked" else baseline_solver_time,
            "baseline_solver_time_sec": baseline_solver_time,
            "locked_solver_time_sec": locked_solver_time,
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
            "llm_error": llm_error,
        },
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("bridge_server:app", host="127.0.0.1", port=8000, reload=False)
