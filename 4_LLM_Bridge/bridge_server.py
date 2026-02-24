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


class SolveRequest(BaseModel):
    spot: Dict[str, Any] = Field(..., description="spot.json payload for shark_cli")
    timeout_sec: int = Field(default=900, ge=10, le=3600)
    quiet: bool = Field(default=True)
    compute_baseline_delta: bool = Field(
        default=False,
        description="Run a no-lock baseline solve and report exploitability delta.",
    )
    llm: Optional[Dict[str, Any]] = Field(
        default=None,
        description=(
            "LLM selector config. Examples: "
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


@app.get("/health")
def health() -> Dict[str, Any]:
    shark_cli = _resolve_shark_cli()
    return {
        "status": "ok",
        "shark_cli": str(shark_cli),
        "llm_default_preset": "mock",
    }


@app.post("/solve")
def solve(request: SolveRequest) -> Dict[str, Any]:
    bridge_started = time.perf_counter()
    _validate_spot(request.spot)
    shark_cli = _resolve_shark_cli()

    llm_started = time.perf_counter()
    try:
        node_lock = get_llm_intuition(request.spot, request.llm)
    except Exception as exc:  # pylint: disable=broad-except
        raise HTTPException(status_code=502, detail=f"LLM intuition generation failed: {exc}") from exc
    llm_elapsed = time.perf_counter() - llm_started

    solve_run = _run_shark_cli(
        shark_cli,
        spot_payload=request.spot,
        node_lock_payload=node_lock,
        timeout_sec=request.timeout_sec,
        quiet=request.quiet,
    )
    result = solve_run["result"]
    solver_time = solve_run["solver_wall_time_sec"]

    baseline = None
    baseline_solver_time = 0.0
    exploitability_delta = None
    if request.compute_baseline_delta:
        baseline_run = _run_shark_cli(
            shark_cli,
            spot_payload=request.spot,
            node_lock_payload=None,
            timeout_sec=request.timeout_sec,
            quiet=request.quiet,
        )
        baseline = baseline_run["result"]
        baseline_solver_time = baseline_run["solver_wall_time_sec"]
        locked = result.get("final_exploitability_pct")
        un_locked = baseline.get("final_exploitability_pct")
        if isinstance(locked, (int, float)) and isinstance(un_locked, (int, float)):
            exploitability_delta = float(locked) - float(un_locked)

    total_bridge_time = time.perf_counter() - bridge_started

    return {
        "status": "ok",
        "node_lock": node_lock,
        "result": result,
        "baseline_result": baseline,
        "metrics": {
            "llm_time_sec": llm_elapsed,
            "solver_time_sec": solver_time,
            "baseline_solver_time_sec": baseline_solver_time,
            "total_bridge_time_sec": total_bridge_time,
            "lock_applied": bool(result.get("node_lock", {}).get("applied", False)),
            "lock_applications": result.get("node_lock", {}).get("applications", 0),
            "final_exploitability_pct": result.get("final_exploitability_pct"),
            "baseline_exploitability_pct": baseline.get("final_exploitability_pct") if baseline else None,
            "exploitability_delta_pct": exploitability_delta,
        },
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("bridge_server:app", host="127.0.0.1", port=8000, reload=False)
