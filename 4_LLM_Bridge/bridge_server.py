#!/usr/bin/env python
"""Bridge server: receives spot JSON, generates node-lock, runs shark_cli, returns result."""

from __future__ import annotations

from collections import deque
from datetime import datetime, timezone
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from llm_client import get_llm_intuition, get_llm_intuition_candidates


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SHARK_CLI = ROOT / "1_Engine_Core" / "build_ninja_vcpkg_rel" / "shark_cli.exe"
VISION_ROOT = ROOT / "5_Vision_Extraction"
VISION_INCOMING_DIR = VISION_ROOT / "incoming"
VISION_OUT_DIR = VISION_ROOT / "out"
DEFAULT_LOCAL_MODEL = os.environ.get("BRIDGE_DEFAULT_LOCAL_MODEL", "qwen3-coder:30b")
DEFAULT_LLM_CONFIG = {
    "provider": "local",
    "model": DEFAULT_LOCAL_MODEL,
    "preset": "local_qwen3_coder_30b",
}
RUNTIME_PROFILE_DEFAULT = str(os.environ.get("RUNTIME_PROFILE_DEFAULT", "normal")).strip().lower()
if RUNTIME_PROFILE_DEFAULT not in {"fast", "fast_live", "normal"}:
    RUNTIME_PROFILE_DEFAULT = "normal"
ENFORCE_PRIMARY_LOCAL_ONLY = os.environ.get("ENFORCE_PRIMARY_LOCAL_ONLY", "1").strip() not in {"0", "false", "False"}
PROD_CLASS1_MULTI_NODE_LIVE = os.environ.get("PROD_CLASS1_MULTI_NODE_LIVE", "1").strip() not in {"0", "false", "False"}
PROD_RIVER_MULTI_NODE_SHADOW = os.environ.get("PROD_RIVER_MULTI_NODE_SHADOW", "0").strip() not in {"0", "false", "False"}
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
try:
    RIVER_CANDIDATE_COUNT = int(os.environ.get("RIVER_CANDIDATE_COUNT", "1"))
except ValueError:
    RIVER_CANDIDATE_COUNT = 1
try:
    FAST_BASELINE_TIMEOUT_SEC = int(os.environ.get("FAST_BASELINE_TIMEOUT_SEC", "60"))
except ValueError:
    FAST_BASELINE_TIMEOUT_SEC = 60
try:
    FAST_BASELINE_TIMEOUT_FLOP_SEC = int(os.environ.get("FAST_BASELINE_TIMEOUT_FLOP_SEC", "15"))
except ValueError:
    FAST_BASELINE_TIMEOUT_FLOP_SEC = 15
try:
    FAST_BASELINE_TIMEOUT_TURN_SEC = int(os.environ.get("FAST_BASELINE_TIMEOUT_TURN_SEC", "25"))
except ValueError:
    FAST_BASELINE_TIMEOUT_TURN_SEC = 25
try:
    FAST_BASELINE_TIMEOUT_RIVER_SEC = int(os.environ.get("FAST_BASELINE_TIMEOUT_RIVER_SEC", "25"))
except ValueError:
    FAST_BASELINE_TIMEOUT_RIVER_SEC = 25
try:
    FAST_LLM_TIMEOUT_SEC = int(os.environ.get("FAST_LLM_TIMEOUT_SEC", "25"))
except ValueError:
    FAST_LLM_TIMEOUT_SEC = 25
try:
    FAST_LOCKED_TIMEOUT_SEC = int(os.environ.get("FAST_LOCKED_TIMEOUT_SEC", "60"))
except ValueError:
    FAST_LOCKED_TIMEOUT_SEC = 60
try:
    FAST_LOCKED_STAGE_TOTAL_SEC = int(os.environ.get("FAST_LOCKED_STAGE_TOTAL_SEC", "90"))
except ValueError:
    FAST_LOCKED_STAGE_TOTAL_SEC = 90
try:
    FAST_MAX_TOKENS = int(os.environ.get("FAST_MAX_TOKENS", "280"))
except ValueError:
    FAST_MAX_TOKENS = 280
try:
    FAST_SPOT_MAX_ITERATIONS = int(os.environ.get("FAST_SPOT_MAX_ITERATIONS", "2"))
except ValueError:
    FAST_SPOT_MAX_ITERATIONS = 2
try:
    FAST_SPOT_MAX_THREADS = int(os.environ.get("FAST_SPOT_MAX_THREADS", "8"))
except ValueError:
    FAST_SPOT_MAX_THREADS = 8
try:
    FAST_SPOT_MAX_RAISE_CAP = int(os.environ.get("FAST_SPOT_MAX_RAISE_CAP", "2"))
except ValueError:
    FAST_SPOT_MAX_RAISE_CAP = 2
try:
    FAST_SPOT_MIN_ALL_IN_THRESHOLD = float(os.environ.get("FAST_SPOT_MIN_ALL_IN_THRESHOLD", "0.58"))
except ValueError:
    FAST_SPOT_MIN_ALL_IN_THRESHOLD = 0.58
FAST_SPOT_FORCE_COMPRESS_STRATEGY = os.environ.get("FAST_SPOT_FORCE_COMPRESS_STRATEGY", "1").strip() not in {
    "0",
    "false",
    "False",
}
FAST_SPOT_FORCE_REMOVE_DONK_BETS = os.environ.get("FAST_SPOT_FORCE_REMOVE_DONK_BETS", "1").strip() not in {
    "0",
    "false",
    "False",
}
FAST_SPOT_BET_SIZES_RAW = os.environ.get("FAST_SPOT_BET_SIZES", "0.33,0.75")
FAST_SPOT_RAISE_SIZES_RAW = os.environ.get("FAST_SPOT_RAISE_SIZES", "1.0,2.0")
FAST_FAILOVER_ON_BASELINE_ERROR = os.environ.get("FAST_FAILOVER_ON_BASELINE_ERROR", "1").strip() not in {
    "0",
    "false",
    "False",
}
FAST_FLOP_LOOKUP_ONLY = os.environ.get("FAST_FLOP_LOOKUP_ONLY", "1").strip() not in {
    "0",
    "false",
    "False",
}
FAST_TURN_LOOKUP_ONLY = os.environ.get("FAST_TURN_LOOKUP_ONLY", "0").strip() not in {
    "0",
    "false",
    "False",
}
FAST_FAILOVER_DEFAULT_FLOP_ACTION = str(os.environ.get("FAST_FAILOVER_DEFAULT_FLOP_ACTION", "check")).strip().lower()
FAST_FAILOVER_DEFAULT_TURN_ACTION = str(os.environ.get("FAST_FAILOVER_DEFAULT_TURN_ACTION", "check")).strip().lower()
FAST_FAILOVER_DEFAULT_RIVER_ACTION = str(os.environ.get("FAST_FAILOVER_DEFAULT_RIVER_ACTION", "check")).strip().lower()
FAST_FORCE_ROOT_ONLY = os.environ.get("FAST_FORCE_ROOT_ONLY", "1").strip() not in {"0", "false", "False"}
FAST_SKIP_LLM_STAGE = os.environ.get("FAST_SKIP_LLM_STAGE", "1").strip() not in {"0", "false", "False"}
try:
    FAST_LIVE_BASELINE_TIMEOUT_SEC = int(os.environ.get("FAST_LIVE_BASELINE_TIMEOUT_SEC", "3"))
except ValueError:
    FAST_LIVE_BASELINE_TIMEOUT_SEC = 3
try:
    FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC = int(os.environ.get("FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC", "3"))
except ValueError:
    FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC = 3
try:
    FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC = int(os.environ.get("FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC", "2"))
except ValueError:
    FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC = 2
try:
    FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC = int(os.environ.get("FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC", "1"))
except ValueError:
    FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC = 1
try:
    FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC = int(os.environ.get("FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC", "4"))
except ValueError:
    FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC = 4
try:
    FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC = int(os.environ.get("FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC", "6"))
except ValueError:
    FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC = 6
FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY = os.environ.get("FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY", "1").strip() not in {
    "0",
    "false",
    "False",
}
try:
    FAST_LIVE_LLM_TIMEOUT_SEC = int(os.environ.get("FAST_LIVE_LLM_TIMEOUT_SEC", "1"))
except ValueError:
    FAST_LIVE_LLM_TIMEOUT_SEC = 1
try:
    FAST_LIVE_LOCKED_TIMEOUT_SEC = int(os.environ.get("FAST_LIVE_LOCKED_TIMEOUT_SEC", "2"))
except ValueError:
    FAST_LIVE_LOCKED_TIMEOUT_SEC = 2
try:
    FAST_LIVE_LOCKED_STAGE_TOTAL_SEC = int(os.environ.get("FAST_LIVE_LOCKED_STAGE_TOTAL_SEC", "5"))
except ValueError:
    FAST_LIVE_LOCKED_STAGE_TOTAL_SEC = 5
try:
    FAST_LIVE_MAX_TOKENS = int(os.environ.get("FAST_LIVE_MAX_TOKENS", "160"))
except ValueError:
    FAST_LIVE_MAX_TOKENS = 160
try:
    FAST_LIVE_SPOT_MAX_ITERATIONS = int(os.environ.get("FAST_LIVE_SPOT_MAX_ITERATIONS", "1"))
except ValueError:
    FAST_LIVE_SPOT_MAX_ITERATIONS = 1
try:
    FAST_LIVE_SPOT_MAX_THREADS = int(os.environ.get("FAST_LIVE_SPOT_MAX_THREADS", "2"))
except ValueError:
    FAST_LIVE_SPOT_MAX_THREADS = 2
try:
    FAST_LIVE_SPOT_MAX_RAISE_CAP = int(os.environ.get("FAST_LIVE_SPOT_MAX_RAISE_CAP", "2"))
except ValueError:
    FAST_LIVE_SPOT_MAX_RAISE_CAP = 2
try:
    FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD = float(os.environ.get("FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD", "0.58"))
except ValueError:
    FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD = 0.58
FAST_LIVE_SPOT_FORCE_COMPRESS_STRATEGY = os.environ.get("FAST_LIVE_SPOT_FORCE_COMPRESS_STRATEGY", "1").strip() not in {
    "0",
    "false",
    "False",
}
FAST_LIVE_SPOT_FORCE_REMOVE_DONK_BETS = os.environ.get("FAST_LIVE_SPOT_FORCE_REMOVE_DONK_BETS", "1").strip() not in {
    "0",
    "false",
    "False",
}
FAST_LIVE_SPOT_BET_SIZES_RAW = os.environ.get("FAST_LIVE_SPOT_BET_SIZES", "0.33,0.75")
FAST_LIVE_SPOT_RAISE_SIZES_RAW = os.environ.get("FAST_LIVE_SPOT_RAISE_SIZES", "1.0,2.0")
SPOT_DYNAMIC_ALL_IN_THRESHOLD_ENABLED = os.environ.get("SPOT_DYNAMIC_ALL_IN_THRESHOLD_ENABLED", "1").strip() not in {
    "0",
    "false",
    "False",
}
try:
    SPOT_DYNAMIC_ALL_IN_THRESHOLD_MIN = float(os.environ.get("SPOT_DYNAMIC_ALL_IN_THRESHOLD_MIN", "0.50"))
except ValueError:
    SPOT_DYNAMIC_ALL_IN_THRESHOLD_MIN = 0.50
try:
    SPOT_DYNAMIC_ALL_IN_THRESHOLD_MAX = float(os.environ.get("SPOT_DYNAMIC_ALL_IN_THRESHOLD_MAX", "0.92"))
except ValueError:
    SPOT_DYNAMIC_ALL_IN_THRESHOLD_MAX = 0.92
try:
    SPOT_NORMAL_MIN_ALL_IN_THRESHOLD = float(os.environ.get("SPOT_NORMAL_MIN_ALL_IN_THRESHOLD", "0.58"))
except ValueError:
    SPOT_NORMAL_MIN_ALL_IN_THRESHOLD = 0.58
FAST_LIVE_FAILOVER_ON_BASELINE_ERROR = os.environ.get("FAST_LIVE_FAILOVER_ON_BASELINE_ERROR", "1").strip() not in {
    "0",
    "false",
    "False",
}
FAST_LIVE_FORCE_ROOT_ONLY = os.environ.get("FAST_LIVE_FORCE_ROOT_ONLY", "1").strip() not in {"0", "false", "False"}
FAST_LIVE_SKIP_LLM_STAGE = os.environ.get("FAST_LIVE_SKIP_LLM_STAGE", "1").strip() not in {"0", "false", "False"}
try:
    NORMAL_BASELINE_TIMEOUT_SEC = int(os.environ.get("NORMAL_BASELINE_TIMEOUT_SEC", "900"))
except ValueError:
    NORMAL_BASELINE_TIMEOUT_SEC = 900
try:
    NORMAL_LLM_TIMEOUT_SEC = int(os.environ.get("NORMAL_LLM_TIMEOUT_SEC", "60"))
except ValueError:
    NORMAL_LLM_TIMEOUT_SEC = 60
try:
    NORMAL_LOCKED_TIMEOUT_SEC = int(os.environ.get("NORMAL_LOCKED_TIMEOUT_SEC", "900"))
except ValueError:
    NORMAL_LOCKED_TIMEOUT_SEC = 900
try:
    NORMAL_LOCKED_STAGE_TOTAL_SEC = int(os.environ.get("NORMAL_LOCKED_STAGE_TOTAL_SEC", "900"))
except ValueError:
    NORMAL_LOCKED_STAGE_TOTAL_SEC = 900
ENABLE_CLOUD_CANDIDATE_SEARCH = os.environ.get("ENABLE_CLOUD_CANDIDATE_SEARCH", "0").strip() not in {
    "0",
    "false",
    "False",
}
try:
    CLOUD_CANDIDATE_COUNT_CAP = int(os.environ.get("CLOUD_CANDIDATE_COUNT_CAP", "2"))
except ValueError:
    CLOUD_CANDIDATE_COUNT_CAP = 2
CANARY_GUARDRAILS_ENABLED = os.environ.get("CANARY_GUARDRAILS_ENABLED", "0").strip() not in {"0", "false", "False"}
try:
    CANARY_WINDOW_CALLS = int(os.environ.get("CANARY_WINDOW_CALLS", "50"))
except ValueError:
    CANARY_WINDOW_CALLS = 50
if CANARY_WINDOW_CALLS < 5:
    CANARY_WINDOW_CALLS = 5
try:
    CANARY_MIN_CALLS_BEFORE_TRIP = int(os.environ.get("CANARY_MIN_CALLS_BEFORE_TRIP", "20"))
except ValueError:
    CANARY_MIN_CALLS_BEFORE_TRIP = 20
if CANARY_MIN_CALLS_BEFORE_TRIP < 1:
    CANARY_MIN_CALLS_BEFORE_TRIP = 1
try:
    CANARY_MAX_FALLBACK_RATE = float(os.environ.get("CANARY_MAX_FALLBACK_RATE", "0.0"))
except ValueError:
    CANARY_MAX_FALLBACK_RATE = 0.0
try:
    CANARY_MIN_KEEP_RATE = float(os.environ.get("CANARY_MIN_KEEP_RATE", "0.90"))
except ValueError:
    CANARY_MIN_KEEP_RATE = 0.90
try:
    CANARY_MAX_P95_LATENCY_SEC = float(os.environ.get("CANARY_MAX_P95_LATENCY_SEC", "20.0"))
except ValueError:
    CANARY_MAX_P95_LATENCY_SEC = 20.0
CANARY_KILL_SWITCH_MODE = str(os.environ.get("CANARY_KILL_SWITCH_MODE", "baseline_only")).strip().lower()
if CANARY_KILL_SWITCH_MODE not in {"baseline_only", "reject"}:
    CANARY_KILL_SWITCH_MODE = "baseline_only"
CANARY_AUTO_EXIT_ON_TRIP = os.environ.get("CANARY_AUTO_EXIT_ON_TRIP", "0").strip() not in {"0", "false", "False"}
NEURAL_BRAIN_ENABLED = os.environ.get("NEURAL_BRAIN_ENABLED", "0").strip() not in {"0", "false", "False"}
NEURAL_BRAIN_MODE = str(os.environ.get("NEURAL_BRAIN_MODE", "shadow")).strip().lower()
if NEURAL_BRAIN_MODE not in {"shadow", "prefer", "prefer_on_fast_failover"}:
    NEURAL_BRAIN_MODE = "shadow"
NEURAL_BRAIN_ADAPTER_PATH = Path(
    os.environ.get("NEURAL_BRAIN_ADAPTER_PATH", str(ROOT / "4_LLM_Bridge" / "neural_brain_adapter.py"))
).expanduser()
NEURAL_BRAIN_PYTHON = str(os.environ.get("NEURAL_BRAIN_PYTHON", "")).strip()
try:
    NEURAL_BRAIN_TIMEOUT_SEC = int(os.environ.get("NEURAL_BRAIN_TIMEOUT_SEC", "3"))
except ValueError:
    NEURAL_BRAIN_TIMEOUT_SEC = 3
NEURAL_BRAIN_TIMEOUT_SEC = max(1, NEURAL_BRAIN_TIMEOUT_SEC)
try:
    NEURAL_BRAIN_CFR_ITERS = int(os.environ.get("NEURAL_BRAIN_CFR_ITERS", "120"))
except ValueError:
    NEURAL_BRAIN_CFR_ITERS = 120
NEURAL_BRAIN_CFR_ITERS = max(1, NEURAL_BRAIN_CFR_ITERS)
try:
    NEURAL_BRAIN_CFR_SKIP_ITERS = int(os.environ.get("NEURAL_BRAIN_CFR_SKIP_ITERS", "60"))
except ValueError:
    NEURAL_BRAIN_CFR_SKIP_ITERS = 60
NEURAL_BRAIN_CFR_SKIP_ITERS = max(0, min(NEURAL_BRAIN_CFR_SKIP_ITERS, NEURAL_BRAIN_CFR_ITERS - 1))
TESSERACT_PATH_ENV = os.environ.get("TESSERACT_PATH", "").strip()
_CANARY_LOCK = threading.Lock()
_CANARY_RECENT: deque[Dict[str, Any]] = deque(maxlen=CANARY_WINDOW_CALLS)
_CANARY_STATE: Dict[str, Any] = {
    "total_calls": 0,
    "tripped": False,
    "trip_reason": "",
    "trip_metric": "",
    "trip_value": None,
    "trip_threshold": None,
    "trip_at_unix": None,
}


def _percentile(values: list[float], q: float) -> Optional[float]:
    if not values:
        return None
    sorted_vals = sorted(values)
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    q = max(0.0, min(1.0, q))
    idx = (len(sorted_vals) - 1) * q
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return sorted_vals[lo]
    frac = idx - lo
    return sorted_vals[lo] * (1.0 - frac) + sorted_vals[hi] * frac


def _canary_summary_from_entries(entries: list[Dict[str, Any]]) -> Dict[str, Any]:
    if not entries:
        return {
            "window_calls": 0,
            "fallback_rate": None,
            "keep_rate": None,
            "latency_p95_sec": None,
        }
    fallback_rate = sum(1.0 for row in entries if bool(row.get("fallback"))) / float(len(entries))
    keep_rate = sum(1.0 for row in entries if bool(row.get("kept"))) / float(len(entries))
    latencies = [float(row["latency_sec"]) for row in entries if isinstance(row.get("latency_sec"), (int, float))]
    return {
        "window_calls": len(entries),
        "fallback_rate": fallback_rate,
        "keep_rate": keep_rate,
        "latency_p95_sec": _percentile(latencies, 0.95),
    }


def _canary_status_snapshot() -> Dict[str, Any]:
    with _CANARY_LOCK:
        entries = list(_CANARY_RECENT)
        summary = _canary_summary_from_entries(entries)
        state = dict(_CANARY_STATE)
    return {
        "enabled": CANARY_GUARDRAILS_ENABLED,
        "window_calls": CANARY_WINDOW_CALLS,
        "min_calls_before_trip": CANARY_MIN_CALLS_BEFORE_TRIP,
        "max_fallback_rate": CANARY_MAX_FALLBACK_RATE,
        "min_keep_rate": CANARY_MIN_KEEP_RATE,
        "max_p95_latency_sec": CANARY_MAX_P95_LATENCY_SEC,
        "kill_switch_mode": CANARY_KILL_SWITCH_MODE,
        "auto_exit_on_trip": CANARY_AUTO_EXIT_ON_TRIP,
        "summary": summary,
        "state": state,
    }


def _trip_canary(
    *,
    metric: str,
    value: Optional[float],
    threshold: Optional[float],
    reason: str,
) -> None:
    with _CANARY_LOCK:
        if _CANARY_STATE.get("tripped"):
            return
        _CANARY_STATE["tripped"] = True
        _CANARY_STATE["trip_reason"] = reason
        _CANARY_STATE["trip_metric"] = metric
        _CANARY_STATE["trip_value"] = value
        _CANARY_STATE["trip_threshold"] = threshold
        _CANARY_STATE["trip_at_unix"] = time.time()
    print(
        f"[canary_guardrail] KILL SWITCH TRIPPED metric={metric} value={value} threshold={threshold} reason={reason}",
        flush=True,
    )
    if CANARY_AUTO_EXIT_ON_TRIP:
        # Optional hard-stop for canary process orchestration.
        os._exit(78)  # noqa: S606


def _record_canary_observation(
    *,
    fallback: bool,
    kept: bool,
    latency_sec: float,
) -> None:
    if not CANARY_GUARDRAILS_ENABLED:
        return
    with _CANARY_LOCK:
        _CANARY_STATE["total_calls"] = int(_CANARY_STATE.get("total_calls", 0)) + 1
        _CANARY_RECENT.append(
            {
                "fallback": bool(fallback),
                "kept": bool(kept),
                "latency_sec": float(latency_sec),
                "ts_unix": time.time(),
            }
        )
        if _CANARY_STATE.get("tripped"):
            return
        entries = list(_CANARY_RECENT)
    if len(entries) < CANARY_MIN_CALLS_BEFORE_TRIP:
        return
    summary = _canary_summary_from_entries(entries)
    fallback_rate = summary.get("fallback_rate")
    keep_rate = summary.get("keep_rate")
    latency_p95_sec = summary.get("latency_p95_sec")
    if isinstance(fallback_rate, float) and fallback_rate > CANARY_MAX_FALLBACK_RATE:
        _trip_canary(
            metric="fallback_rate",
            value=fallback_rate,
            threshold=CANARY_MAX_FALLBACK_RATE,
            reason="fallback_rate_exceeded",
        )
        return
    if isinstance(keep_rate, float) and keep_rate < CANARY_MIN_KEEP_RATE:
        _trip_canary(
            metric="keep_rate",
            value=keep_rate,
            threshold=CANARY_MIN_KEEP_RATE,
            reason="keep_rate_below_minimum",
        )
        return
    if isinstance(latency_p95_sec, float) and latency_p95_sec > CANARY_MAX_P95_LATENCY_SEC:
        _trip_canary(
            metric="latency_p95_sec",
            value=latency_p95_sec,
            threshold=CANARY_MAX_P95_LATENCY_SEC,
            reason="latency_p95_exceeded",
        )
        return


def _is_canary_tripped() -> bool:
    with _CANARY_LOCK:
        return bool(_CANARY_STATE.get("tripped", False))


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
            "{'preset':'mock'} | {'preset':'openai_fast'} | {'preset':'openai_mini'} | {'preset':'openai_5mini'} | {'preset':'openai_52'} | "
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
    runtime_profile: Optional[str] = Field(
        default=None,
        description="Runtime profile: fast | normal. Controls per-stage latency budgets.",
    )


class VisionIngestRequest(BaseModel):
    image_path: str = Field(..., description="Absolute path to the captured image file.")
    source: str = Field(default="sharex", description="Capture source label (sharex/manual/etc).")
    profile: str = Field(default="general", description="OCR profile: general | cards | numeric")
    psm: Optional[int] = Field(default=None, ge=3, le=13, description="Optional override for tesseract --psm.")
    whitelist: Optional[str] = Field(default=None, description="Optional explicit tesseract whitelist.")
    save_copy: bool = Field(default=True, description="Copy source image into 5_Vision_Extraction/incoming.")


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


def _ensure_vision_dirs() -> None:
    VISION_INCOMING_DIR.mkdir(parents=True, exist_ok=True)
    VISION_OUT_DIR.mkdir(parents=True, exist_ok=True)


def _resolve_tesseract_executable() -> Path:
    candidates: list[str] = []
    if TESSERACT_PATH_ENV:
        candidates.append(TESSERACT_PATH_ENV)
    candidates.extend(
        [
            "tesseract",
            r"C:\Program Files\Tesseract-OCR\tesseract.exe",
            r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe",
        ]
    )
    for candidate in candidates:
        try:
            path_obj = Path(candidate)
            if path_obj.exists():
                return path_obj
            probe = subprocess.run(
                [candidate, "--version"],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            if probe.returncode == 0:
                return Path(candidate)
        except (OSError, subprocess.SubprocessError):
            continue
    raise HTTPException(
        status_code=500,
        detail="tesseract executable not found. Set TESSERACT_PATH or install Tesseract to PATH.",
    )


def _vision_profile_defaults(profile: str) -> tuple[int, Optional[str]]:
    normalized = str(profile or "general").strip().lower()
    if normalized == "cards":
        return 7, "AKQJT98765432shdcSHDC "
    if normalized == "numeric":
        return 7, "0123456789.,:$/"
    return 6, None


def _safe_vision_stem(path_value: Path) -> str:
    raw = path_value.stem.strip()
    if not raw:
        return "capture"
    safe = "".join(ch if (ch.isalnum() or ch in {"_", "-", "."}) else "_" for ch in raw)
    return safe or "capture"


def _run_tesseract_image_to_text(
    *,
    tesseract_exe: Path,
    image_path: Path,
    output_base: Path,
    psm: int,
    whitelist: Optional[str],
) -> tuple[str, Path, float]:
    cmd = [str(tesseract_exe), str(image_path), str(output_base), "--psm", str(psm)]
    if whitelist:
        cmd.extend(["-c", f"tessedit_char_whitelist={whitelist}"])
    started = time.perf_counter()
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    elapsed = time.perf_counter() - started
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail={
                "error": "tesseract_failed",
                "returncode": proc.returncode,
                "stderr": proc.stderr[-4000:],
                "stdout": proc.stdout[-4000:],
            },
        )
    txt_path = Path(str(output_base) + ".txt")
    if not txt_path.exists():
        raise HTTPException(status_code=500, detail="tesseract did not produce OCR text output.")
    text = txt_path.read_text(encoding="utf-8", errors="ignore")
    return text, txt_path, elapsed


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


def _resolve_neural_python_command() -> str:
    if NEURAL_BRAIN_PYTHON:
        return NEURAL_BRAIN_PYTHON
    if sys.executable:
        return sys.executable
    return "python"


def _extract_json_object_from_stdout(raw_stdout: str) -> Optional[Dict[str, Any]]:
    text = str(raw_stdout or "").strip()
    if not text:
        return None
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    for line in reversed(lines):
        if not (line.startswith("{") and line.endswith("}")):
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def _spot_has_valid_hero_cards(spot: Dict[str, Any]) -> bool:
    meta = spot.get("meta", {})
    if not isinstance(meta, dict):
        return False
    hero_cards = meta.get("hero_cards")
    if not isinstance(hero_cards, list) or len(hero_cards) != 2:
        return False
    for card in hero_cards:
        token = str(card or "").strip()
        if len(token) < 2:
            return False
    return True


def _normalize_action_token(token: str) -> str:
    raw = str(token or "").strip().lower()
    if not raw:
        return ""
    if raw in {"fold", "check", "call"}:
        return raw
    if raw == "all_in":
        return "raise"
    if ":" in raw:
        action, amount = raw.split(":", 1)
        action = action.strip()
        if action in {"bet", "raise"}:
            try:
                amt = int(float(amount))
            except ValueError:
                return action
            return f"raise:{amt}"
        return action
    if raw in {"bet", "raise"}:
        return "raise"
    return raw


def _run_neural_brain_adapter(
    *,
    spot: Dict[str, Any],
    allowed_actions: list[str],
    timeout_sec: int,
) -> tuple[Optional[Dict[str, Any]], Optional[str], float]:
    if not NEURAL_BRAIN_ENABLED:
        return None, "neural_brain_disabled", 0.0
    if not _spot_has_valid_hero_cards(spot):
        return None, "missing_or_invalid_hero_cards", 0.0
    if not NEURAL_BRAIN_ADAPTER_PATH.exists():
        return None, f"neural_adapter_missing:{NEURAL_BRAIN_ADAPTER_PATH}", 0.0

    normalized_allowed = []
    seen = set()
    for token in allowed_actions:
        normalized = _normalize_action_token(token)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        normalized_allowed.append(normalized)

    effective_timeout = max(1, min(int(timeout_sec), int(NEURAL_BRAIN_TIMEOUT_SEC)))
    cmd = [
        _resolve_neural_python_command(),
        str(NEURAL_BRAIN_ADAPTER_PATH),
        "--timeout-sec",
        str(effective_timeout),
    ]
    payload = {
        "spot": spot,
        "allowed_actions": normalized_allowed,
    }
    env = os.environ.copy()
    env["DYYPHOLDEM_CFR_ITERS"] = str(NEURAL_BRAIN_CFR_ITERS)
    env["DYYPHOLDEM_CFR_SKIP_ITERS"] = str(NEURAL_BRAIN_CFR_SKIP_ITERS)

    started = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            timeout=effective_timeout,
            check=False,
            env=env,
        )
    except subprocess.TimeoutExpired:
        elapsed = time.perf_counter() - started
        return None, f"neural_adapter_timeout_{effective_timeout}s", elapsed
    except Exception as exc:  # pylint: disable=broad-except
        elapsed = time.perf_counter() - started
        return None, f"neural_adapter_exec_error:{exc}", elapsed
    elapsed = time.perf_counter() - started

    parsed = _extract_json_object_from_stdout(proc.stdout)
    if proc.returncode != 0:
        stderr_tail = (proc.stderr or "")[-600:]
        return None, f"neural_adapter_failed_rc={proc.returncode}:{stderr_tail}", elapsed
    if not isinstance(parsed, dict):
        stdout_tail = (proc.stdout or "")[-600:]
        return None, f"neural_adapter_invalid_json:{stdout_tail}", elapsed
    if not bool(parsed.get("ok", False)):
        return None, str(parsed.get("error", "neural_adapter_returned_not_ok")), elapsed

    root_actions = parsed.get("root_actions")
    chosen_action = str(parsed.get("chosen_action", "")).strip().lower()
    if not isinstance(root_actions, list) or not root_actions:
        return None, "neural_adapter_missing_root_actions", elapsed
    if not chosen_action:
        return None, "neural_adapter_missing_chosen_action", elapsed
    parsed["chosen_action"] = _normalize_action_token(chosen_action)
    return parsed, None, elapsed


def _apply_neural_overlay_to_result(base_result: Dict[str, Any], neural_payload: Dict[str, Any]) -> Dict[str, Any]:
    result = dict(base_result)
    root_actions = neural_payload.get("root_actions")
    if isinstance(root_actions, list) and root_actions:
        result["root_actions"] = root_actions
    decision_raw = result.get("decision", {})
    decision = dict(decision_raw) if isinstance(decision_raw, dict) else {}
    chosen_action = _normalize_action_token(str(neural_payload.get("chosen_action", "")).strip().lower())
    if chosen_action:
        decision["action"] = chosen_action
    decision["policy"] = "neural_brain"
    result["decision"] = decision
    warnings_raw = result.get("warnings", [])
    warnings = list(warnings_raw) if isinstance(warnings_raw, list) else []
    if "neural_brain_overlay" not in warnings:
        warnings.append("neural_brain_overlay")
    result["warnings"] = warnings
    return result


def _to_float_or_none(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _normalize_action_summary_tokens(action_items: Any) -> list[str]:
    allowed: list[str] = []
    if not isinstance(action_items, list):
        return allowed
    for item in action_items:
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


def _action_summary_frequency(item: Dict[str, Any]) -> float:
    if not isinstance(item, dict):
        return 0.0
    if isinstance(item.get("avg_frequency"), (int, float)):
        return float(item["avg_frequency"])
    if isinstance(item.get("frequency"), (int, float)):
        return float(item["frequency"])
    return 0.0


def _pick_primary_action_token_from_summary(action_items: Any) -> str:
    if not isinstance(action_items, list) or not action_items:
        return ""
    best_token = ""
    best_freq = float("-inf")
    for item in action_items:
        if not isinstance(item, dict):
            continue
        action = _normalize_action_token(str(item.get("action", "")).strip().lower())
        if not action:
            continue
        amount = item.get("amount")
        if action in {"bet", "raise"} and isinstance(amount, (int, float)):
            action = f"raise:{int(amount)}"
        freq = _action_summary_frequency(item)
        if freq > best_freq:
            best_freq = freq
            best_token = action
    if best_token:
        return best_token
    normalized = _normalize_action_summary_tokens(action_items)
    return normalized[0] if normalized else ""


def _primary_action_from_result_payload(result_payload: Dict[str, Any]) -> str:
    decision_raw = result_payload.get("decision")
    if isinstance(decision_raw, dict):
        token = _normalize_action_token(str(decision_raw.get("action", "")).strip().lower())
        if token:
            return token
    active_found = bool(result_payload.get("active_node_found"))
    if active_found:
        token = _pick_primary_action_token_from_summary(result_payload.get("active_node_actions", []))
        if token:
            return token
    token = _pick_primary_action_token_from_summary(result_payload.get("root_actions", []))
    if token:
        return token
    allowed = _extract_allowed_root_actions(result_payload)
    return allowed[0] if allowed else ""


def _build_neural_shadow_summary(
    *,
    runtime_profile: str,
    mode: str,
    attempted: bool,
    applied: bool,
    elapsed_sec: float,
    timeout_sec: int,
    error: Optional[str],
    payload: Optional[Dict[str, Any]],
    selected_action: str,
    allowed_actions_in: list[str],
) -> Dict[str, Any]:
    neural_choice = ""
    neural_actions: list[str] = []
    neural_root_count = 0
    neural_adapter = ""
    neural_surrogate = False
    if isinstance(payload, dict):
        neural_choice = _normalize_action_token(str(payload.get("chosen_action", "")).strip().lower())
        neural_actions = _normalize_action_summary_tokens(payload.get("root_actions", []))
        neural_root = payload.get("root_actions")
        if isinstance(neural_root, list):
            neural_root_count = len(neural_root)
        meta = payload.get("meta")
        if isinstance(meta, dict):
            neural_adapter = str(meta.get("adapter") or "")
            neural_surrogate = bool(meta.get("surrogate", False))
    agree: Optional[bool] = None
    if neural_choice and selected_action:
        if neural_choice == selected_action:
            agree = True
        else:
            # Treat sized-vs-unsized raises as agreement.
            agree = neural_choice.startswith("raise") and selected_action.startswith("raise")
    summary = {
        "enabled": bool(NEURAL_BRAIN_ENABLED),
        "mode": str(mode),
        "runtime_profile": str(runtime_profile),
        "attempted": bool(attempted),
        "available": bool(isinstance(payload, dict)),
        "applied": bool(applied),
        "elapsed_sec": float(elapsed_sec),
        "timeout_sec": int(max(0, timeout_sec)),
        "error": error,
        "selected_action": selected_action,
        "neural_chosen_action": neural_choice,
        "agrees_with_selected": agree,
        "allowed_actions_in": list(allowed_actions_in),
        "neural_allowed_actions": neural_actions,
        "neural_root_action_count": int(neural_root_count),
        "neural_adapter": neural_adapter,
        "neural_surrogate": neural_surrogate,
    }
    return summary


def _extract_allowed_root_actions(result_payload: Dict[str, Any]) -> list[str]:
    active_found = bool(result_payload.get("active_node_found"))
    active_actions = result_payload.get("active_node_actions", [])
    if active_found:
        normalized = _normalize_action_summary_tokens(active_actions)
        if normalized:
            return normalized
    return _normalize_action_summary_tokens(result_payload.get("root_actions", []))


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


def _extract_spot_facing_bet(spot: Dict[str, Any]) -> float:
    facing = 0.0
    meta = spot.get("meta")
    if isinstance(meta, dict):
        facing = max(facing, float(_to_float_or_none(meta.get("facing_bet")) or 0.0))
    if facing <= 0.0:
        active = str(spot.get("active_node_path", "")).strip()
        facing = float(_extract_last_bet_amount_from_active_node_path(active) or 0)
    return max(0.0, facing)


def _dynamic_all_in_threshold(spot: Dict[str, Any], base_threshold: float) -> tuple[float, Dict[str, Any]]:
    clamped_base = min(max(float(base_threshold), 0.50), 0.99)
    if not SPOT_DYNAMIC_ALL_IN_THRESHOLD_ENABLED:
        return clamped_base, {"enabled": False, "base": clamped_base}

    board = spot.get("board", [])
    board_len = len(board) if isinstance(board, list) else 0
    if board_len <= 0:
        street = "preflop"
    elif board_len >= 5:
        street = "river"
    elif board_len == 4:
        street = "turn"
    else:
        street = "flop"
    facing_bet = _extract_spot_facing_bet(spot)
    minimum_bet = float(_to_float_or_none(spot.get("minimum_bet")) or 1.0)
    starting_pot = float(_to_float_or_none(spot.get("starting_pot")) or (minimum_bet * 2.0))
    effective_pot = max(1.0, starting_pot + (facing_bet if facing_bet > 0.0 else 0.0))

    stack_candidates: list[float] = []
    starting_stack = _to_float_or_none(spot.get("starting_stack"))
    if starting_stack is not None and starting_stack > 0.0:
        stack_candidates.append(float(starting_stack))
    meta = spot.get("meta")
    if isinstance(meta, dict):
        hero_stack_now = _to_float_or_none(meta.get("current_hero_chips"))
        if hero_stack_now is not None and hero_stack_now > 0.0:
            stack_candidates.append(float(hero_stack_now))
    effective_stack = min(stack_candidates) if stack_candidates else max(1.0, starting_pot)
    spr = float(effective_stack) / float(effective_pot)
    facing_ratio = float(facing_bet) / float(effective_pot) if facing_bet > 0.0 else 0.0

    adjust = 0.0
    street_adjust = {
        "preflop": 0.05,
        "flop": 0.02,
        "turn": -0.03,
        "river": -0.06,
    }
    adjust += float(street_adjust.get(street, 0.0))

    if spr <= 1.0:
        adjust -= 0.09
    elif spr <= 2.0:
        adjust -= 0.06
    elif spr <= 4.0:
        adjust -= 0.03
    elif spr >= 10.0:
        adjust += 0.03

    if facing_ratio >= 0.75:
        adjust -= 0.06
    elif facing_ratio >= 0.50:
        adjust -= 0.04
    elif facing_ratio >= 0.33:
        adjust -= 0.02

    active_node_path = str(spot.get("active_node_path", "")).strip()
    if active_node_path:
        adjust -= 0.01

    out = clamped_base + adjust
    floor = min(max(SPOT_DYNAMIC_ALL_IN_THRESHOLD_MIN, 0.50), 0.95)
    ceiling = min(max(SPOT_DYNAMIC_ALL_IN_THRESHOLD_MAX, floor), 0.99)
    out = min(max(out, floor), ceiling)
    return out, {
        "enabled": True,
        "base": clamped_base,
        "adjust": round(adjust, 4),
        "street": street,
        "spr": round(spr, 4),
        "facing_bet": round(facing_bet, 4),
        "facing_ratio": round(facing_ratio, 4),
    }


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
    spot_street = _detect_spot_street(request.spot)
    
    is_class1 = bool(classes.get("turn_probe_punish", False))
    is_class23 = bool(classes.get("river_bigbet_overfold_punish", False) or classes.get("river_underbluff_defense", False))
    
    # If no explicit class is defined, fallback to street-level inference for broad pool tagging
    if not classes:
        if spot_street == "turn":
            is_class1 = True
            classes["turn_probe_punish"] = True
        elif spot_street == "river":
            is_class23 = True
            classes["river_bigbet_overfold_punish"] = True
            
    mode = str(llm_config.get("mode", "")).strip().lower()

    if BENCHMARK_MODE_BYPASS_ROUTING and mode == "benchmark":
        return requested, "benchmark_mode_bypass", classes
    if PROD_RIVER_MULTI_NODE_SHADOW and is_class23:
        return False, "forced_off_class23_shadow", classes
    if PROD_CLASS1_MULTI_NODE_LIVE and is_class1:
        return True, "forced_on_class1_live", classes
    return requested, "request_flag", classes


def _normalize_runtime_profile(profile: Optional[str]) -> str:
    value = str(profile or "").strip().lower()
    if value == "live_fast":
        value = "fast_live"
    if value in {"fast", "fast_live", "normal"}:
        return value
    return RUNTIME_PROFILE_DEFAULT


def _stage_budget_value(request_timeout: int, cap: int, min_floor: int = 10) -> int:
    floor_val = max(1, int(min_floor))
    timeout = max(floor_val, int(request_timeout))
    cap_val = max(floor_val, int(cap))
    return max(floor_val, min(timeout, cap_val))


def _resolve_stage_budgets(runtime_profile: str, request_timeout: int, spot: Optional[Dict[str, Any]] = None) -> Dict[str, int]:
    if runtime_profile == "fast":
        baseline_cap = FAST_BASELINE_TIMEOUT_SEC
        llm_cap = FAST_LLM_TIMEOUT_SEC
        locked_cap = FAST_LOCKED_TIMEOUT_SEC
        locked_total_cap = FAST_LOCKED_STAGE_TOTAL_SEC
        min_floor = 10
    elif runtime_profile == "fast_live":
        baseline_cap = FAST_LIVE_BASELINE_TIMEOUT_SEC
        llm_cap = FAST_LIVE_LLM_TIMEOUT_SEC
        locked_cap = FAST_LIVE_LOCKED_TIMEOUT_SEC
        locked_total_cap = FAST_LIVE_LOCKED_STAGE_TOTAL_SEC
        min_floor = 1
    else:
        baseline_cap = NORMAL_BASELINE_TIMEOUT_SEC
        llm_cap = NORMAL_LLM_TIMEOUT_SEC
        locked_cap = NORMAL_LOCKED_TIMEOUT_SEC
        locked_total_cap = NORMAL_LOCKED_STAGE_TOTAL_SEC
        min_floor = 10

    baseline_timeout = _stage_budget_value(request_timeout, baseline_cap, min_floor=min_floor)
    if runtime_profile in {"fast", "fast_live"} and isinstance(spot, dict):
        spot_street = _detect_spot_street(spot)
        street_cap = None
        if spot_street == "flop":
            street_cap = FAST_BASELINE_TIMEOUT_FLOP_SEC if runtime_profile == "fast" else FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC
        elif spot_street == "turn":
            street_cap = FAST_BASELINE_TIMEOUT_TURN_SEC if runtime_profile == "fast" else FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC
        elif spot_street == "river":
            street_cap = FAST_BASELINE_TIMEOUT_RIVER_SEC if runtime_profile == "fast" else FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC
        if isinstance(street_cap, int):
            baseline_timeout = _stage_budget_value(baseline_timeout, street_cap, min_floor=min_floor)
    if runtime_profile == "fast_live" and isinstance(spot, dict):
        active_node_path = str(spot.get("active_node_path", "")).strip()
        if active_node_path:
            active_node_cap = FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC
            if _detect_spot_street(spot) == "flop":
                active_node_cap = max(int(active_node_cap), int(FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC))
            active_node_timeout = _stage_budget_value(
                request_timeout,
                active_node_cap,
                min_floor=min_floor,
            )
            baseline_timeout = max(baseline_timeout, active_node_timeout)
    llm_timeout = _stage_budget_value(request_timeout, llm_cap, min_floor=min_floor)
    locked_timeout = _stage_budget_value(request_timeout, locked_cap, min_floor=min_floor)
    locked_total_timeout = _stage_budget_value(request_timeout, locked_total_cap, min_floor=min_floor)
    return {
        "baseline_timeout_sec": baseline_timeout,
        "llm_timeout_sec": llm_timeout,
        "locked_timeout_sec": locked_timeout,
        "locked_stage_total_sec": locked_total_timeout,
    }


def _parse_sizing_env(raw: str, fallback: list[float]) -> list[float]:
    out: list[float] = []
    for token in str(raw or "").split(","):
        value = token.strip()
        if not value:
            continue
        try:
            fval = float(value)
        except ValueError:
            continue
        if fval > 0.0:
            out.append(fval)
    return out or list(fallback)


def _apply_fast_spot_profile(spot: Dict[str, Any]) -> tuple[Dict[str, Any], Dict[str, Any]]:
    tuned = dict(spot)
    changes: Dict[str, Any] = {}
    preserve_donk_tree = bool(str(tuned.get("active_node_path", "")).strip())

    iterations = _to_float_or_none(tuned.get("iterations"))
    if iterations is not None:
        capped = int(max(1, min(int(iterations), FAST_SPOT_MAX_ITERATIONS)))
        if capped != int(iterations):
            changes["iterations"] = {"from": int(iterations), "to": capped}
        tuned["iterations"] = capped
    else:
        tuned["iterations"] = max(1, FAST_SPOT_MAX_ITERATIONS)
        changes["iterations"] = {"from": None, "to": tuned["iterations"]}

    thread_count = _to_float_or_none(tuned.get("thread_count"))
    if thread_count is not None:
        capped_threads = int(max(1, min(int(thread_count), FAST_SPOT_MAX_THREADS)))
        if capped_threads != int(thread_count):
            changes["thread_count"] = {"from": int(thread_count), "to": capped_threads}
        tuned["thread_count"] = capped_threads
    else:
        tuned["thread_count"] = max(1, FAST_SPOT_MAX_THREADS)
        changes["thread_count"] = {"from": None, "to": tuned["thread_count"]}

    raise_cap = _to_float_or_none(tuned.get("raise_cap"))
    if raise_cap is not None:
        capped_raise = int(max(1, min(int(raise_cap), FAST_SPOT_MAX_RAISE_CAP)))
        if capped_raise != int(raise_cap):
            changes["raise_cap"] = {"from": int(raise_cap), "to": capped_raise}
        tuned["raise_cap"] = capped_raise
    else:
        tuned["raise_cap"] = max(1, FAST_SPOT_MAX_RAISE_CAP)
        changes["raise_cap"] = {"from": None, "to": tuned["raise_cap"]}

    raw_threshold = _to_float_or_none(tuned.get("all_in_threshold"))
    had_threshold = raw_threshold is not None
    threshold_base = float(raw_threshold) if had_threshold else min(max(FAST_SPOT_MIN_ALL_IN_THRESHOLD, 0.50), 0.99)
    dynamic_threshold, dynamic_meta = _dynamic_all_in_threshold(tuned, threshold_base)
    clamped_threshold = max(FAST_SPOT_MIN_ALL_IN_THRESHOLD, float(dynamic_threshold))
    clamped_threshold = min(clamped_threshold, 0.99)
    if not had_threshold:
        changes["all_in_threshold"] = {"from": None, "to": clamped_threshold, "dynamic": dynamic_meta}
    elif abs(clamped_threshold - threshold_base) > 1e-9:
        changes["all_in_threshold"] = {"from": threshold_base, "to": clamped_threshold, "dynamic": dynamic_meta}
    tuned["all_in_threshold"] = clamped_threshold

    if FAST_SPOT_FORCE_COMPRESS_STRATEGY:
        old = tuned.get("compress_strategy")
        tuned["compress_strategy"] = True
        if old is not True:
            changes["compress_strategy"] = {"from": old, "to": True}
    if FAST_SPOT_FORCE_REMOVE_DONK_BETS and not preserve_donk_tree:
        old = tuned.get("remove_donk_bets")
        tuned["remove_donk_bets"] = True
        if old is not True:
            changes["remove_donk_bets"] = {"from": old, "to": True}

    bet_sizes = _parse_sizing_env(FAST_SPOT_BET_SIZES_RAW, [0.5])
    raise_sizes = _parse_sizing_env(FAST_SPOT_RAISE_SIZES_RAW, [1.0, 2.0])
    target_bet_sizing = {
        "flop": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
        "turn": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
        "river": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
    }
    if preserve_donk_tree and isinstance(tuned.get("bet_sizing"), dict):
        changes["bet_sizing"] = "preserved_for_active_node_path"
    else:
        old_bet_sizing = tuned.get("bet_sizing")
        tuned["bet_sizing"] = target_bet_sizing
        if old_bet_sizing != target_bet_sizing:
            changes["bet_sizing"] = "reduced_to_fast_profile"

    summary = {
        "profile": "fast",
        "applied": True,
        "max_iterations": FAST_SPOT_MAX_ITERATIONS,
        "max_threads": FAST_SPOT_MAX_THREADS,
        "max_raise_cap": FAST_SPOT_MAX_RAISE_CAP,
        "min_all_in_threshold": FAST_SPOT_MIN_ALL_IN_THRESHOLD,
        "bet_sizes": bet_sizes,
        "raise_sizes": raise_sizes,
        "changes": changes,
    }
    return tuned, summary


def _apply_fast_live_spot_profile(spot: Dict[str, Any]) -> tuple[Dict[str, Any], Dict[str, Any]]:
    tuned = dict(spot)
    changes: Dict[str, Any] = {}
    preserve_donk_tree = bool(str(tuned.get("active_node_path", "")).strip())

    iterations = _to_float_or_none(tuned.get("iterations"))
    if iterations is not None:
        capped = int(max(1, min(int(iterations), FAST_LIVE_SPOT_MAX_ITERATIONS)))
        if capped != int(iterations):
            changes["iterations"] = {"from": int(iterations), "to": capped}
        tuned["iterations"] = capped
    else:
        tuned["iterations"] = max(1, FAST_LIVE_SPOT_MAX_ITERATIONS)
        changes["iterations"] = {"from": None, "to": tuned["iterations"]}

    thread_count = _to_float_or_none(tuned.get("thread_count"))
    if thread_count is not None:
        capped_threads = int(max(1, min(int(thread_count), FAST_LIVE_SPOT_MAX_THREADS)))
        if capped_threads != int(thread_count):
            changes["thread_count"] = {"from": int(thread_count), "to": capped_threads}
        tuned["thread_count"] = capped_threads
    else:
        tuned["thread_count"] = max(1, FAST_LIVE_SPOT_MAX_THREADS)
        changes["thread_count"] = {"from": None, "to": tuned["thread_count"]}

    raise_cap = _to_float_or_none(tuned.get("raise_cap"))
    if raise_cap is not None:
        capped_raise = int(max(1, min(int(raise_cap), FAST_LIVE_SPOT_MAX_RAISE_CAP)))
        if capped_raise != int(raise_cap):
            changes["raise_cap"] = {"from": int(raise_cap), "to": capped_raise}
        tuned["raise_cap"] = capped_raise
    else:
        tuned["raise_cap"] = max(1, FAST_LIVE_SPOT_MAX_RAISE_CAP)
        changes["raise_cap"] = {"from": None, "to": tuned["raise_cap"]}

    raw_threshold = _to_float_or_none(tuned.get("all_in_threshold"))
    had_threshold = raw_threshold is not None
    threshold_base = float(raw_threshold) if had_threshold else min(max(FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD, 0.50), 0.99)
    dynamic_threshold, dynamic_meta = _dynamic_all_in_threshold(tuned, threshold_base)
    clamped_threshold = max(FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD, float(dynamic_threshold))
    clamped_threshold = min(clamped_threshold, 0.99)
    if not had_threshold:
        changes["all_in_threshold"] = {"from": None, "to": clamped_threshold, "dynamic": dynamic_meta}
    elif abs(clamped_threshold - threshold_base) > 1e-9:
        changes["all_in_threshold"] = {"from": threshold_base, "to": clamped_threshold, "dynamic": dynamic_meta}
    tuned["all_in_threshold"] = clamped_threshold

    if FAST_LIVE_SPOT_FORCE_COMPRESS_STRATEGY:
        old = tuned.get("compress_strategy")
        tuned["compress_strategy"] = True
        if old is not True:
            changes["compress_strategy"] = {"from": old, "to": True}
    if FAST_LIVE_SPOT_FORCE_REMOVE_DONK_BETS and not preserve_donk_tree:
        old = tuned.get("remove_donk_bets")
        tuned["remove_donk_bets"] = True
        if old is not True:
            changes["remove_donk_bets"] = {"from": old, "to": True}

    bet_sizes = _parse_sizing_env(FAST_LIVE_SPOT_BET_SIZES_RAW, [0.33, 0.75])
    raise_sizes = _parse_sizing_env(FAST_LIVE_SPOT_RAISE_SIZES_RAW, [1.0, 2.0])
    target_bet_sizing = {
        "flop": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
        "turn": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
        "river": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
    }
    if preserve_donk_tree and isinstance(tuned.get("bet_sizing"), dict):
        old_bet_sizing = tuned.get("bet_sizing")
        active_street = _detect_spot_street(tuned)
        active_bet_sizing = json.loads(json.dumps(target_bet_sizing))
        source_sizing = old_bet_sizing if isinstance(old_bet_sizing, dict) else {}
        active_cfg = source_sizing.get(active_street, {}) if isinstance(source_sizing, dict) else {}

        source_bets = active_cfg.get("bet_sizes", []) if isinstance(active_cfg, dict) else []
        if isinstance(source_bets, list):
            kept_bets = []
            for value in source_bets:
                fval = _to_float_or_none(value)
                if fval is not None and fval > 0:
                    kept_bets.append(float(fval))
                    break
            if kept_bets:
                active_bet_sizing[active_street]["bet_sizes"] = kept_bets

        source_raises = active_cfg.get("raise_sizes", []) if isinstance(active_cfg, dict) else []
        if isinstance(source_raises, list):
            kept_raises = []
            raise_cap_limit = raise_sizes[0] if raise_sizes else None
            for value in source_raises:
                fval = _to_float_or_none(value)
                if fval is None or fval <= 0:
                    continue
                trimmed = float(fval)
                if raise_cap_limit is not None:
                    trimmed = min(trimmed, float(raise_cap_limit))
                kept_raises.append(trimmed)
                break
            if kept_raises:
                active_bet_sizing[active_street]["raise_sizes"] = kept_raises

        tuned["bet_sizing"] = active_bet_sizing
        if old_bet_sizing != active_bet_sizing:
            changes["bet_sizing"] = "reduced_to_fast_live_active_node_profile"
        else:
            changes["bet_sizing"] = "preserved_for_active_node_path"
    else:
        old_bet_sizing = tuned.get("bet_sizing")
        tuned["bet_sizing"] = target_bet_sizing
        if old_bet_sizing != target_bet_sizing:
            changes["bet_sizing"] = "reduced_to_fast_live_profile"

    summary = {
        "profile": "fast_live",
        "applied": True,
        "max_iterations": FAST_LIVE_SPOT_MAX_ITERATIONS,
        "max_threads": FAST_LIVE_SPOT_MAX_THREADS,
        "max_raise_cap": FAST_LIVE_SPOT_MAX_RAISE_CAP,
        "min_all_in_threshold": FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD,
        "bet_sizes": bet_sizes,
        "raise_sizes": raise_sizes,
        "changes": changes,
    }
    return tuned, summary


def _fallback_actions_from_spot(spot: Dict[str, Any]) -> list[str]:
    street = _detect_spot_street(spot)
    actions: list[str] = []
    minimum_bet = _to_float_or_none(spot.get("minimum_bet")) or 1.0
    starting_pot = _to_float_or_none(spot.get("starting_pot")) or (minimum_bet * 2.0)
    facing_bet = 0.0
    meta = spot.get("meta")
    if isinstance(meta, dict):
        facing_bet = max(facing_bet, float(_to_float_or_none(meta.get("facing_bet")) or 0.0))
    if facing_bet <= 0.0:
        facing_bet = float(_extract_last_bet_amount_from_active_node_path(str(spot.get("active_node_path", "")).strip()) or 0)

    if facing_bet > 0.0:
        actions.extend(["fold", "call"])
    else:
        actions.append("check")

    bet_sizing = spot.get("bet_sizing", {})
    if isinstance(bet_sizing, dict):
        street_cfg = bet_sizing.get(street, {})
        if isinstance(street_cfg, dict):
            size_key = "raise_sizes" if facing_bet > 0.0 else "bet_sizes"
            action_base = "raise" if facing_bet > 0.0 else "bet"
            sizes = street_cfg.get(size_key, [])
            if isinstance(sizes, list):
                numeric_sizes = [float(x) for x in sizes if isinstance(x, (int, float)) and float(x) > 0.0]
                if numeric_sizes:
                    if facing_bet > 0.0:
                        amount = int(max(minimum_bet, round(facing_bet * min(numeric_sizes))))
                    else:
                        amount = int(max(minimum_bet, round(starting_pot * min(numeric_sizes))))
                    actions.append(f"{action_base}:{amount}")
    if facing_bet > 0.0:
        if all(not token.startswith("raise:") for token in actions):
            actions.append(f"raise:{int(max(minimum_bet, round(facing_bet * 2.0)))}")
    else:
        if all(not token.startswith("bet:") for token in actions):
            actions.append(f"bet:{int(max(1.0, minimum_bet))}")

    out: list[str] = []
    seen: set[str] = set()
    for token in actions:
        key = token.strip().lower()
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(key)
    return out


_RANK_VALUE_MAP = {
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


def _extract_board_texture_flags(spot: Dict[str, Any]) -> Dict[str, bool]:
    board = spot.get("board")
    if not isinstance(board, list):
        return {"paired": False, "monotone": False, "four_flush": False, "connected": False, "dry": False}
    ranks: list[int] = []
    suits: list[str] = []
    for raw_card in board[:5]:
        token = str(raw_card or "").strip()
        if len(token) < 2:
            continue
        if token[:2] == "10":
            rank_token = "T"
            suit_token = token[2:3].lower()
        else:
            rank_token = token[:1].upper()
            suit_token = token[-1:].lower()
        rank_val = _RANK_VALUE_MAP.get(rank_token)
        if rank_val is None:
            continue
        ranks.append(rank_val)
        if suit_token in {"s", "h", "d", "c"}:
            suits.append(suit_token)
    paired = len(set(ranks)) < len(ranks) if ranks else False
    suit_counts = {suit: suits.count(suit) for suit in set(suits)}
    max_suit_count = max(suit_counts.values()) if suit_counts else 0
    monotone = max_suit_count >= 3
    four_flush = max_suit_count >= 4
    unique_ranks = sorted(set(ranks))
    connected = len(unique_ranks) >= 3 and (max(unique_ranks) - min(unique_ranks) <= (len(unique_ranks) + 1))
    dry = bool(ranks) and not paired and not monotone and not four_flush and not connected
    return {
        "paired": paired,
        "monotone": monotone,
        "four_flush": four_flush,
        "connected": connected,
        "dry": dry,
    }


def _hero_is_in_position(spot: Dict[str, Any]) -> bool:
    try:
        # Bridge spot contract treats hero as player 1.
        return int(spot.get("in_position_player", 0)) == 1
    except (TypeError, ValueError):
        return False


def _choose_smallest_sized_action(allowed_actions: list[str], action_base: str) -> Optional[str]:
    best_action: Optional[str] = None
    best_amount: Optional[int] = None
    for action in allowed_actions:
        token = str(action or "").strip().lower()
        if not token.startswith(f"{action_base}:"):
            continue
        try:
            amount = int(float(token.split(":", 1)[1]))
        except ValueError:
            continue
        if best_amount is None or amount < best_amount:
            best_amount = amount
            best_action = token
    return best_action


def _extract_last_bet_amount_from_active_node_path(active_node_path: str) -> Optional[int]:
    path_value = str(active_node_path or "").strip().lower()
    if not path_value:
        return None
    for segment in reversed(path_value.split("/")):
        token = segment.strip()
        if ":bet:" not in token:
            continue
        try:
            return int(float(token.rsplit(":", 1)[1]))
        except (TypeError, ValueError):
            continue
    return None


def _build_fast_live_active_node_flop_fallback_policy(
    spot: Dict[str, Any],
) -> tuple[list[str], str, list[Dict[str, Any]]]:
    minimum_bet = float(_to_float_or_none(spot.get("minimum_bet")) or 1.0)
    starting_pot = float(_to_float_or_none(spot.get("starting_pot")) or (minimum_bet * 2.0))
    active_node_path = str(spot.get("active_node_path", "")).strip()
    bet_amount = float(
        _extract_last_bet_amount_from_active_node_path(active_node_path)
        or max(int(minimum_bet), int(round(starting_pot * 0.5)))
    )
    denominator = max(1.0, starting_pot + bet_amount)
    mdf = max(0.0, min(1.0, starting_pot / denominator))
    texture = _extract_board_texture_flags(spot)

    fold_freq = max(0.20, min(0.80, 1.0 - mdf))
    if texture["paired"]:
        fold_freq = min(0.90, fold_freq + 0.10)
    if texture["monotone"] or texture["four_flush"]:
        fold_freq = min(0.95, fold_freq + 0.15)
    if texture["connected"]:
        fold_freq = min(0.95, fold_freq + 0.05)

    raise_freq = 0.0
    bet_ratio = bet_amount / max(1.0, starting_pot)
    if texture["dry"] and not texture["paired"] and not texture["monotone"] and bet_ratio <= 0.50:
        raise_freq = min(0.15, max(0.05, mdf * 0.20))
        fold_freq = max(0.10, fold_freq - (raise_freq * 0.5))

    call_freq = max(0.0, 1.0 - fold_freq - raise_freq)
    total = fold_freq + call_freq + raise_freq
    if total <= 0.0:
        fold_freq, call_freq, raise_freq = 0.34, 0.66, 0.0
        total = 1.0
    fold_freq /= total
    call_freq /= total
    raise_freq /= total

    allowed_actions: list[str] = ["fold", "call"]
    raise_token: Optional[str] = None
    if raise_freq > 0.0:
        raise_amount = int(max(minimum_bet, round(bet_amount * 4.0)))
        raise_token = f"raise:{raise_amount}"
        allowed_actions.append(raise_token)

    weighted_rows: list[tuple[str, float]] = [
        ("fold", fold_freq),
        ("call", call_freq),
    ]
    if raise_token is not None:
        weighted_rows.append((raise_token, raise_freq))

    chosen_action = max(weighted_rows, key=lambda row: row[1])[0]
    root_actions = [_token_to_root_action(token, chosen_action) for token, _ in weighted_rows]
    for row, (_, freq) in zip(root_actions, weighted_rows):
        row["frequency"] = float(freq)
    return allowed_actions, chosen_action, root_actions


def _choose_fast_failover_action(spot: Dict[str, Any], allowed_actions: list[str]) -> str:
    street = _detect_spot_street(spot)
    facing_bet = 0.0
    meta = spot.get("meta")
    if isinstance(meta, dict):
        facing_bet = max(facing_bet, float(_to_float_or_none(meta.get("facing_bet")) or 0.0))
    if facing_bet <= 0.0:
        facing_bet = float(_extract_last_bet_amount_from_active_node_path(str(spot.get("active_node_path", "")).strip()) or 0)

    if facing_bet > 0.0:
        minimum_bet = _to_float_or_none(spot.get("minimum_bet")) or 1.0
        starting_pot = _to_float_or_none(spot.get("starting_pot")) or (minimum_bet * 2.0)
        texture = _extract_board_texture_flags(spot)
        denominator = max(1.0, starting_pot + facing_bet)
        mdf = max(0.0, min(1.0, starting_pot / denominator))
        fold_score = max(0.0, min(1.0, 1.0 - mdf))
        if texture["paired"]:
            fold_score = min(1.0, fold_score + 0.10)
        if texture["monotone"] or texture["four_flush"]:
            fold_score = min(1.0, fold_score + 0.12)
        if texture["connected"]:
            fold_score = min(1.0, fold_score + 0.08)
        bet_ratio = facing_bet / max(1.0, starting_pot)
        if bet_ratio >= 1.0:
            fold_score = min(1.0, fold_score + 0.08)
        elif bet_ratio <= 0.33:
            fold_score = max(0.0, fold_score - 0.10)

        if fold_score >= 0.45 and "fold" in allowed_actions:
            return "fold"
        if "call" in allowed_actions:
            return "call"
        for candidate in allowed_actions:
            if candidate.startswith("raise:"):
                return candidate
        return allowed_actions[0] if allowed_actions else "call"

    if street in {"flop", "turn"}:
        smallest_bet = _choose_smallest_sized_action(allowed_actions, "bet")
        if smallest_bet:
            texture = _extract_board_texture_flags(spot)
            if street == "flop" and _hero_is_in_position(spot) and texture["dry"]:
                return smallest_bet
            if street == "turn" and _hero_is_in_position(spot) and texture["dry"] and not texture["paired"]:
                return smallest_bet
            if "check" not in allowed_actions:
                return smallest_bet
    preferred_by_street = {
        "flop": FAST_FAILOVER_DEFAULT_FLOP_ACTION,
        "turn": FAST_FAILOVER_DEFAULT_TURN_ACTION,
        "river": FAST_FAILOVER_DEFAULT_RIVER_ACTION,
    }
    preferred = str(preferred_by_street.get(street, "check")).strip().lower()
    if preferred:
        if preferred in allowed_actions:
            return preferred
        pref_base = preferred.split(":", 1)[0]
        for action in allowed_actions:
            if action.split(":", 1)[0] == pref_base:
                return action
    for candidate in ("check", "call"):
        if candidate in allowed_actions:
            return candidate
    return allowed_actions[0] if allowed_actions else "check"


def _token_to_root_action(token: str, chosen: str) -> Dict[str, Any]:
    base = token
    amount = None
    if ":" in token:
        lhs, rhs = token.split(":", 1)
        base = lhs.strip().lower()
        try:
            amount = int(float(rhs))
        except ValueError:
            amount = None
    item: Dict[str, Any] = {
        "action": base,
        "frequency": 1.0 if token == chosen else 0.0,
    }
    if amount is not None and base in {"bet", "raise"}:
        item["amount"] = amount
    return item


def _build_fast_failover_response(
    *,
    request: SolveRequest,
    runtime_profile: str,
    stage_budgets: Dict[str, int],
    request_total_budget_sec: int,
    llm_timeout_effective: int,
    locked_stage_total_effective: float,
    total_bridge_time: float,
    baseline_error: str,
    fast_spot_profile_summary: Optional[Dict[str, Any]],
    selection_reason: str = "fast_profile_baseline_failed_lookup_fallback",
    multi_node_policy_reason: str = "fast_failover_lookup",
) -> Dict[str, Any]:
    neural_elapsed = 0.0
    neural_error: Optional[str] = None
    neural_applied = False
    active_node_path = str(request.spot.get("active_node_path", "")).strip()
    use_active_node_flop_policy = (
        runtime_profile == "fast_live"
        and _detect_spot_street(request.spot) == "flop"
        and bool(active_node_path)
    )
    if use_active_node_flop_policy:
        allowed_actions, chosen_action, root_actions = _build_fast_live_active_node_flop_fallback_policy(request.spot)
    else:
        allowed_actions = _fallback_actions_from_spot(request.spot)
        chosen_action = _choose_fast_failover_action(request.spot, allowed_actions)
        root_actions = [_token_to_root_action(token, chosen_action) for token in allowed_actions]
    allowed_actions_before_neural = list(allowed_actions)
    neural_attempted = False
    neural_timeout_effective = 0
    neural_payload, neural_error, neural_elapsed = _run_neural_brain_adapter(
        spot=request.spot,
        allowed_actions=allowed_actions,
        timeout_sec=NEURAL_BRAIN_TIMEOUT_SEC,
    )
    if NEURAL_BRAIN_ENABLED:
        neural_attempted = True
        neural_timeout_effective = int(max(1, NEURAL_BRAIN_TIMEOUT_SEC))
    if isinstance(neural_payload, dict):
        neural_root_actions = neural_payload.get("root_actions")
        neural_allowed = _normalize_action_summary_tokens(neural_root_actions)
        neural_choice = _normalize_action_token(str(neural_payload.get("chosen_action", "")).strip().lower())
        neural_meta = neural_payload.get("meta") if isinstance(neural_payload.get("meta"), dict) else {}
        neural_surrogate = bool(neural_meta.get("surrogate", False))
        if isinstance(neural_root_actions, list) and neural_root_actions:
            root_actions = neural_root_actions
        if neural_allowed:
            allowed_actions = neural_allowed
        if neural_choice:
            chosen_action = neural_choice
        if NEURAL_BRAIN_MODE in {"prefer", "prefer_on_fast_failover"} and not neural_surrogate:
            neural_applied = True
        elif NEURAL_BRAIN_MODE in {"prefer", "prefer_on_fast_failover"} and neural_surrogate:
            neural_error = "surrogate_shadow_only"

    selected_strategy = "neural_brain" if neural_applied else "fallback_lookup_policy"
    effective_selection_reason = (
        "neural_brain_preferred_on_fast_failover" if neural_applied else selection_reason
    )
    result_payload = {
        "runtime_fallback": True,
        "final_exploitability_pct": None,
        "root_actions": root_actions,
        "node_lock": {
            "provided": False,
            "applied": False,
            "applications": 0,
            "reason": "fast_failover_no_solver_result",
        },
        "decision": {
            "action": chosen_action,
            "street": _detect_spot_street(request.spot),
            "policy": ("neural_brain" if neural_applied else "lookup_fallback"),
        },
        "warnings": [f"fast_failover_applied:{baseline_error}"],
    }
    selected_action = _primary_action_from_result_payload(result_payload)
    neural_shadow = _build_neural_shadow_summary(
        runtime_profile=runtime_profile,
        mode=NEURAL_BRAIN_MODE,
        attempted=neural_attempted,
        applied=neural_applied,
        elapsed_sec=neural_elapsed,
        timeout_sec=neural_timeout_effective,
        error=neural_error,
        payload=neural_payload,
        selected_action=selected_action,
        allowed_actions_in=allowed_actions_before_neural,
    )
    return {
        "status": "ok",
        "node_lock": None,
        "node_lock_kept": False,
        "selected_strategy": selected_strategy,
        "selection_reason": effective_selection_reason,
        "allowed_root_actions": allowed_actions,
        "multi_node_policy": {
            "requested": bool(request.enable_multi_node_locks),
            "enabled": False,
            "reason": multi_node_policy_reason,
            "rollout_classes": _extract_rollout_classes(request.spot),
        },
        "result": result_payload,
        "neural_shadow": neural_shadow,
        "baseline_result": None,
        "locked_result": None,
        "metrics": {
            "llm_time_sec": 0.0,
            "solver_time_sec": 0.0,
            "baseline_solver_time_sec": 0.0,
            "locked_solver_time_sec": 0.0,
            "locked_solver_time_total_sec": 0.0,
            "total_bridge_time_sec": total_bridge_time,
            "lock_applied": False,
            "lock_applications": 0,
            "final_exploitability_pct": None,
            "baseline_exploitability_pct": None,
            "locked_exploitability_pct": None,
            "exploitability_delta_pct": None,
            "ev_keep_margin": request.ev_keep_margin,
            "locked_beats_margin_gate": None,
            "lock_confidence": None,
            "lock_confidence_tag": "unknown",
            "lock_quality_score": 0.0,
            "node_lock_target_count": 0,
            "llm_candidate_mode_enabled": False,
            "llm_candidate_target_count": 0,
            "llm_candidate_generated_count": 0,
            "llm_candidate_solve_count": 0,
            "llm_candidate_errors": [baseline_error],
            "llm_is_local_request": _is_local_request(dict(request.llm or DEFAULT_LLM_CONFIG)),
            "multi_node_requested": bool(request.enable_multi_node_locks),
            "multi_node_enabled": False,
            "multi_node_policy_reason": multi_node_policy_reason,
            "llm_error": baseline_error,
            "neural_time_sec": neural_elapsed,
            "neural_error": neural_error,
            "neural_mode": NEURAL_BRAIN_MODE,
            "neural_applied": neural_applied,
            "neural_shadow": neural_shadow,
            "runtime_profile": runtime_profile,
            "stage_budgets": stage_budgets,
            "fast_spot_profile": fast_spot_profile_summary,
            "effective_stage_budgets": {
                "request_total_budget_sec": request_total_budget_sec,
                "llm_timeout_sec": llm_timeout_effective,
                "locked_stage_total_sec": locked_stage_total_effective,
            },
        },
        "canary_guardrails": _canary_status_snapshot(),
    }


@app.get("/health")
def health() -> Dict[str, Any]:
    shark_cli = _resolve_shark_cli()
    tesseract_path = ""
    tesseract_ok = False
    try:
        tesseract_path = str(_resolve_tesseract_executable())
        tesseract_ok = True
    except HTTPException:
        tesseract_path = ""
        tesseract_ok = False
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
        "river_candidate_count": RIVER_CANDIDATE_COUNT,
        "runtime_profile_default": RUNTIME_PROFILE_DEFAULT,
        "neural_brain_enabled": NEURAL_BRAIN_ENABLED,
        "neural_brain_mode": NEURAL_BRAIN_MODE,
        "neural_brain_adapter_path": str(NEURAL_BRAIN_ADAPTER_PATH),
        "neural_brain_timeout_sec": NEURAL_BRAIN_TIMEOUT_SEC,
        "neural_brain_cfr_iters": NEURAL_BRAIN_CFR_ITERS,
        "neural_brain_cfr_skip_iters": NEURAL_BRAIN_CFR_SKIP_ITERS,
        "fast_baseline_timeout_sec": FAST_BASELINE_TIMEOUT_SEC,
        "fast_baseline_timeout_flop_sec": FAST_BASELINE_TIMEOUT_FLOP_SEC,
        "fast_baseline_timeout_turn_sec": FAST_BASELINE_TIMEOUT_TURN_SEC,
        "fast_baseline_timeout_river_sec": FAST_BASELINE_TIMEOUT_RIVER_SEC,
        "fast_llm_timeout_sec": FAST_LLM_TIMEOUT_SEC,
        "fast_locked_timeout_sec": FAST_LOCKED_TIMEOUT_SEC,
        "fast_locked_stage_total_sec": FAST_LOCKED_STAGE_TOTAL_SEC,
        "fast_max_tokens": FAST_MAX_TOKENS,
        "fast_spot_max_iterations": FAST_SPOT_MAX_ITERATIONS,
        "fast_spot_max_threads": FAST_SPOT_MAX_THREADS,
        "fast_spot_max_raise_cap": FAST_SPOT_MAX_RAISE_CAP,
        "fast_spot_min_all_in_threshold": FAST_SPOT_MIN_ALL_IN_THRESHOLD,
        "fast_spot_force_compress_strategy": FAST_SPOT_FORCE_COMPRESS_STRATEGY,
        "fast_spot_force_remove_donk_bets": FAST_SPOT_FORCE_REMOVE_DONK_BETS,
        "fast_spot_bet_sizes_raw": FAST_SPOT_BET_SIZES_RAW,
        "fast_spot_raise_sizes_raw": FAST_SPOT_RAISE_SIZES_RAW,
        "fast_failover_on_baseline_error": FAST_FAILOVER_ON_BASELINE_ERROR,
        "fast_flop_lookup_only": FAST_FLOP_LOOKUP_ONLY,
        "fast_turn_lookup_only": FAST_TURN_LOOKUP_ONLY,
        "fast_failover_default_flop_action": FAST_FAILOVER_DEFAULT_FLOP_ACTION,
        "fast_failover_default_turn_action": FAST_FAILOVER_DEFAULT_TURN_ACTION,
        "fast_failover_default_river_action": FAST_FAILOVER_DEFAULT_RIVER_ACTION,
        "fast_force_root_only": FAST_FORCE_ROOT_ONLY,
        "fast_skip_llm_stage": FAST_SKIP_LLM_STAGE,
        "fast_live_baseline_timeout_sec": FAST_LIVE_BASELINE_TIMEOUT_SEC,
        "fast_live_baseline_timeout_flop_sec": FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC,
        "fast_live_baseline_timeout_turn_sec": FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC,
        "fast_live_baseline_timeout_river_sec": FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC,
        "fast_live_active_node_timeout_sec": FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC,
        "fast_live_active_node_timeout_flop_sec": FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC,
        "fast_live_active_node_flop_lookup_only": FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY,
        "fast_live_llm_timeout_sec": FAST_LIVE_LLM_TIMEOUT_SEC,
        "fast_live_locked_timeout_sec": FAST_LIVE_LOCKED_TIMEOUT_SEC,
        "fast_live_locked_stage_total_sec": FAST_LIVE_LOCKED_STAGE_TOTAL_SEC,
        "fast_live_max_tokens": FAST_LIVE_MAX_TOKENS,
        "fast_live_spot_max_iterations": FAST_LIVE_SPOT_MAX_ITERATIONS,
        "fast_live_spot_max_threads": FAST_LIVE_SPOT_MAX_THREADS,
        "fast_live_spot_max_raise_cap": FAST_LIVE_SPOT_MAX_RAISE_CAP,
        "fast_live_spot_min_all_in_threshold": FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD,
        "fast_live_spot_force_compress_strategy": FAST_LIVE_SPOT_FORCE_COMPRESS_STRATEGY,
        "fast_live_spot_force_remove_donk_bets": FAST_LIVE_SPOT_FORCE_REMOVE_DONK_BETS,
        "fast_live_spot_bet_sizes_raw": FAST_LIVE_SPOT_BET_SIZES_RAW,
        "fast_live_spot_raise_sizes_raw": FAST_LIVE_SPOT_RAISE_SIZES_RAW,
        "spot_dynamic_all_in_threshold_enabled": SPOT_DYNAMIC_ALL_IN_THRESHOLD_ENABLED,
        "spot_dynamic_all_in_threshold_min": SPOT_DYNAMIC_ALL_IN_THRESHOLD_MIN,
        "spot_dynamic_all_in_threshold_max": SPOT_DYNAMIC_ALL_IN_THRESHOLD_MAX,
        "spot_normal_min_all_in_threshold": SPOT_NORMAL_MIN_ALL_IN_THRESHOLD,
        "fast_live_failover_on_baseline_error": FAST_LIVE_FAILOVER_ON_BASELINE_ERROR,
        "fast_live_force_root_only": FAST_LIVE_FORCE_ROOT_ONLY,
        "fast_live_skip_llm_stage": FAST_LIVE_SKIP_LLM_STAGE,
        "normal_baseline_timeout_sec": NORMAL_BASELINE_TIMEOUT_SEC,
        "normal_llm_timeout_sec": NORMAL_LLM_TIMEOUT_SEC,
        "normal_locked_timeout_sec": NORMAL_LOCKED_TIMEOUT_SEC,
        "normal_locked_stage_total_sec": NORMAL_LOCKED_STAGE_TOTAL_SEC,
        "enable_cloud_candidate_search": ENABLE_CLOUD_CANDIDATE_SEARCH,
        "cloud_candidate_count_cap": CLOUD_CANDIDATE_COUNT_CAP,
        "vision_root": str(VISION_ROOT),
        "vision_incoming_dir": str(VISION_INCOMING_DIR),
        "vision_out_dir": str(VISION_OUT_DIR),
        "tesseract_available": tesseract_ok,
        "tesseract_path": tesseract_path,
        "canary_guardrails": _canary_status_snapshot(),
    }


@app.post("/vision/ingest")
def vision_ingest(request: VisionIngestRequest) -> Dict[str, Any]:
    _ensure_vision_dirs()
    tesseract_exe = _resolve_tesseract_executable()
    source_path = Path(request.image_path).expanduser()
    if not source_path.is_absolute():
        source_path = (ROOT / source_path).resolve()
    if not source_path.exists() or not source_path.is_file():
        raise HTTPException(status_code=400, detail=f"image_path does not exist or is not a file: {source_path}")

    default_psm, default_whitelist = _vision_profile_defaults(request.profile)
    psm = int(request.psm if request.psm is not None else default_psm)
    whitelist = request.whitelist if request.whitelist is not None else default_whitelist

    run_stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    source_stem = _safe_vision_stem(source_path)
    ingest_path = source_path
    if request.save_copy:
        copied_name = f"{source_stem}.{run_stamp}{source_path.suffix.lower()}"
        copied_path = VISION_INCOMING_DIR / copied_name
        shutil.copy2(source_path, copied_path)
        ingest_path = copied_path

    output_base = VISION_OUT_DIR / f"{source_stem}.{run_stamp}"
    text, txt_path, ocr_elapsed = _run_tesseract_image_to_text(
        tesseract_exe=tesseract_exe,
        image_path=ingest_path,
        output_base=output_base,
        psm=psm,
        whitelist=whitelist,
    )
    collapsed = " ".join(text.split())
    preview = collapsed[:240]
    record = {
        "status": "ok",
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "source": request.source,
        "profile": request.profile,
        "psm": psm,
        "whitelist": whitelist,
        "tesseract_path": str(tesseract_exe),
        "ocr_time_sec": ocr_elapsed,
        "source_image_path": str(source_path),
        "ingest_image_path": str(ingest_path),
        "ocr_text_path": str(txt_path),
        "ocr_text_preview": preview,
        "ocr_text": text,
    }
    record_path = Path(str(output_base) + ".json")
    record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    latest_path = VISION_OUT_DIR / "latest.json"
    latest_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    record["record_path"] = str(record_path)
    record["latest_path"] = str(latest_path)
    return record


@app.post("/solve")
def solve(request: SolveRequest) -> Dict[str, Any]:
    bridge_started = time.perf_counter()
    request_total_budget_sec = max(10, int(request.timeout_sec))
    request_deadline = bridge_started + float(request_total_budget_sec)
    _validate_spot(request.spot)
    shark_cli = _resolve_shark_cli()
    llm_config = dict(request.llm or DEFAULT_LLM_CONFIG)
    runtime_profile = _normalize_runtime_profile(request.runtime_profile)
    stage_budgets = _resolve_stage_budgets(runtime_profile, request.timeout_sec, request.spot)
    _enforce_local_production_policy(llm_config)
    effective_spot = dict(request.spot)
    fast_spot_profile_summary: Optional[Dict[str, Any]] = None
    spot_street = _detect_spot_street(request.spot)
    if runtime_profile == "normal":
        raw_threshold = _to_float_or_none(effective_spot.get("all_in_threshold"))
        had_threshold = raw_threshold is not None
        threshold_base = float(raw_threshold) if had_threshold else min(max(SPOT_NORMAL_MIN_ALL_IN_THRESHOLD, 0.50), 0.99)
        dynamic_threshold, dynamic_meta = _dynamic_all_in_threshold(effective_spot, threshold_base)
        clamped_threshold = max(SPOT_NORMAL_MIN_ALL_IN_THRESHOLD, float(dynamic_threshold))
        clamped_threshold = min(clamped_threshold, 0.99)
        effective_spot["all_in_threshold"] = clamped_threshold
        if (not had_threshold) or abs(clamped_threshold - threshold_base) > 1e-9:
            fast_spot_profile_summary = {
                "profile": "normal",
                "applied": True,
                "changes": {
                    "all_in_threshold": {
                        "from": threshold_base if had_threshold else None,
                        "to": clamped_threshold,
                        "dynamic": dynamic_meta,
                    }
                },
            }
    elif runtime_profile == "fast":
        effective_spot, fast_spot_profile_summary = _apply_fast_spot_profile(effective_spot)
    elif runtime_profile == "fast_live":
        effective_spot, fast_spot_profile_summary = _apply_fast_live_spot_profile(effective_spot)

    if runtime_profile == "fast" and spot_street == "flop" and FAST_FLOP_LOOKUP_ONLY:
        total_bridge_time = time.perf_counter() - bridge_started
        _record_canary_observation(
            fallback=True,
            kept=False,
            latency_sec=total_bridge_time,
        )
        return _build_fast_failover_response(
            request=request,
            runtime_profile=runtime_profile,
            stage_budgets=stage_budgets,
            request_total_budget_sec=request_total_budget_sec,
            llm_timeout_effective=int(stage_budgets["llm_timeout_sec"]),
            locked_stage_total_effective=float(stage_budgets["locked_stage_total_sec"]),
            total_bridge_time=total_bridge_time,
            baseline_error="fast_flop_lookup_only",
            fast_spot_profile_summary=fast_spot_profile_summary,
            selection_reason="fast_profile_flop_lookup_only",
            multi_node_policy_reason="fast_flop_lookup_only",
        )
    if runtime_profile == "fast" and spot_street == "turn" and FAST_TURN_LOOKUP_ONLY:
        total_bridge_time = time.perf_counter() - bridge_started
        _record_canary_observation(
            fallback=True,
            kept=False,
            latency_sec=total_bridge_time,
        )
        return _build_fast_failover_response(
            request=request,
            runtime_profile=runtime_profile,
            stage_budgets=stage_budgets,
            request_total_budget_sec=request_total_budget_sec,
            llm_timeout_effective=int(stage_budgets["llm_timeout_sec"]),
            locked_stage_total_effective=float(stage_budgets["locked_stage_total_sec"]),
            total_bridge_time=total_bridge_time,
            baseline_error="fast_turn_lookup_only",
            fast_spot_profile_summary=fast_spot_profile_summary,
            selection_reason="fast_profile_turn_lookup_only",
            multi_node_policy_reason="fast_turn_lookup_only",
        )
    if (
        runtime_profile == "fast_live"
        and spot_street == "flop"
        and FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY
        and str(request.spot.get("active_node_path", "")).strip()
    ):
        total_bridge_time = time.perf_counter() - bridge_started
        _record_canary_observation(
            fallback=True,
            kept=False,
            latency_sec=total_bridge_time,
        )
        return _build_fast_failover_response(
            request=request,
            runtime_profile=runtime_profile,
            stage_budgets=stage_budgets,
            request_total_budget_sec=request_total_budget_sec,
            llm_timeout_effective=int(stage_budgets["llm_timeout_sec"]),
            locked_stage_total_effective=float(stage_budgets["locked_stage_total_sec"]),
            total_bridge_time=total_bridge_time,
            baseline_error="fast_live_active_node_flop_lookup_only",
            fast_spot_profile_summary=fast_spot_profile_summary,
            selection_reason="fast_live_profile_active_node_flop_lookup_only",
            multi_node_policy_reason="fast_live_active_node_flop_lookup_only",
        )

    # Pass 1: baseline (no lock) is always computed first.
    baseline_result: Dict[str, Any]
    baseline_solver_time = 0.0
    try:
        baseline_run = _run_shark_cli(
            shark_cli,
            spot_payload=effective_spot,
            node_lock_payload=None,
            timeout_sec=stage_budgets["baseline_timeout_sec"],
            quiet=request.quiet,
        )
        baseline_result = baseline_run["result"]
        baseline_solver_time = baseline_run["solver_wall_time_sec"]
    except HTTPException as exc:
        failover_on_baseline_error = (
            FAST_FAILOVER_ON_BASELINE_ERROR
            if runtime_profile == "fast"
            else (FAST_LIVE_FAILOVER_ON_BASELINE_ERROR if runtime_profile == "fast_live" else False)
        )
        if failover_on_baseline_error:
            total_bridge_time = time.perf_counter() - bridge_started
            baseline_error = f"baseline_stage_failed:{exc.detail}"
            _record_canary_observation(
                fallback=True,
                kept=False,
                latency_sec=total_bridge_time,
            )
            return _build_fast_failover_response(
                request=request,
                runtime_profile=runtime_profile,
                stage_budgets=stage_budgets,
                request_total_budget_sec=request_total_budget_sec,
                llm_timeout_effective=int(stage_budgets["llm_timeout_sec"]),
                locked_stage_total_effective=float(stage_budgets["locked_stage_total_sec"]),
                total_bridge_time=total_bridge_time,
                baseline_error=baseline_error,
                fast_spot_profile_summary=fast_spot_profile_summary,
            )
        raise
    allowed_root_actions = _extract_allowed_root_actions(baseline_result)
    node_lock_catalog = _extract_node_lock_catalog(baseline_result)
    llm_timeout_effective = int(stage_budgets["llm_timeout_sec"])
    locked_stage_total_effective = float(stage_budgets["locked_stage_total_sec"])

    if CANARY_GUARDRAILS_ENABLED and _is_canary_tripped():
        canary_status = _canary_status_snapshot()
        if CANARY_KILL_SWITCH_MODE == "reject":
            raise HTTPException(
                status_code=503,
                detail={
                    "error": "canary_kill_switch_tripped",
                    "canary_guardrails": canary_status,
                },
            )
        total_bridge_time = time.perf_counter() - bridge_started
        _record_canary_observation(
            fallback=True,
            kept=False,
            latency_sec=total_bridge_time,
        )
        return {
            "status": "ok",
            "node_lock": None,
            "node_lock_kept": False,
            "selected_strategy": "baseline_gto",
            "selection_reason": "canary_kill_switch_tripped_baseline_only",
            "allowed_root_actions": allowed_root_actions,
            "multi_node_policy": {
                "requested": bool(request.enable_multi_node_locks),
                "enabled": False,
                "reason": "canary_kill_switch",
                "rollout_classes": _extract_rollout_classes(request.spot),
            },
            "result": baseline_result,
            "baseline_result": baseline_result,
            "locked_result": None,
            "metrics": {
                "llm_time_sec": 0.0,
                "solver_time_sec": baseline_solver_time,
                "baseline_solver_time_sec": baseline_solver_time,
                "locked_solver_time_sec": 0.0,
                "locked_solver_time_total_sec": 0.0,
                "total_bridge_time_sec": total_bridge_time,
                "lock_applied": False,
                "lock_applications": 0,
                "final_exploitability_pct": baseline_result.get("final_exploitability_pct"),
                "baseline_exploitability_pct": baseline_result.get("final_exploitability_pct"),
                "locked_exploitability_pct": None,
                "exploitability_delta_pct": None,
                "ev_keep_margin": request.ev_keep_margin,
                "locked_beats_margin_gate": None,
                "lock_confidence": None,
                "lock_confidence_tag": "unknown",
                "lock_quality_score": 0.0,
                "node_lock_target_count": 0,
                "llm_candidate_mode_enabled": False,
                "llm_candidate_target_count": 1,
                "llm_candidate_generated_count": 0,
                "llm_candidate_solve_count": 0,
                "llm_candidate_errors": ["canary_kill_switch_tripped"],
                "llm_is_local_request": _is_local_request(llm_config),
                "multi_node_requested": bool(request.enable_multi_node_locks),
                "multi_node_enabled": False,
                "multi_node_policy_reason": "canary_kill_switch",
                "llm_error": "canary_kill_switch_tripped",
                "runtime_profile": runtime_profile,
                "stage_budgets": stage_budgets,
                "fast_spot_profile": fast_spot_profile_summary,
                "effective_stage_budgets": {
                    "request_total_budget_sec": request_total_budget_sec,
                    "llm_timeout_sec": llm_timeout_effective,
                    "locked_stage_total_sec": locked_stage_total_effective,
                },
            },
            "canary_guardrails": _canary_status_snapshot(),
        }

    llm_started = time.perf_counter()
    llm_error = None
    node_lock = None
    multi_node_enabled, multi_node_policy_reason, rollout_classes = _resolve_multi_node_policy(request, llm_config)
    spot_street = _detect_spot_street(request.spot)
    candidate_target_count = TURN_CANDIDATE_COUNT if spot_street == "turn" else RIVER_CANDIDATE_COUNT
    llm_mode = str(llm_config.get("mode", "")).strip().lower()
    force_root_only = (
        FAST_FORCE_ROOT_ONLY
        if runtime_profile == "fast"
        else (FAST_LIVE_FORCE_ROOT_ONLY if runtime_profile == "fast_live" else False)
    )
    if force_root_only and llm_mode != "benchmark":
        multi_node_enabled = False
        policy_suffix = "fast_root_only" if runtime_profile == "fast" else "fast_live_root_only"
        multi_node_policy_reason = f"{multi_node_policy_reason}+{policy_suffix}"
        candidate_target_count = 1
    is_local_request = _is_local_request(llm_config)
    llm_budget_remaining = max(0.0, request_deadline - time.perf_counter())
    llm_timeout_effective = int(max(1, min(stage_budgets["llm_timeout_sec"], int(math.ceil(llm_budget_remaining)))))
    llm_config["timeout_sec"] = float(llm_timeout_effective)
    if runtime_profile in {"fast", "fast_live"} and "max_tokens" not in llm_config:
        llm_config["max_tokens"] = FAST_MAX_TOKENS if runtime_profile == "fast" else FAST_LIVE_MAX_TOKENS
    if not is_local_request:
        # Keep cloud costs controlled by default. Allow parity search only when explicitly enabled.
        if ENABLE_CLOUD_CANDIDATE_SEARCH and llm_mode == "benchmark":
            candidate_target_count = min(candidate_target_count, max(1, CLOUD_CANDIDATE_COUNT_CAP))
        else:
            candidate_target_count = 1
    candidate_mode_enabled = (
        multi_node_enabled
        and spot_street in {"turn", "river"}
        and candidate_target_count > 1
    )
    llm_config["allowed_root_actions"] = allowed_root_actions
    llm_config["node_lock_catalog"] = node_lock_catalog
    llm_config["opponent_profile"] = dict(request.opponent_profile or {})
    llm_config["enable_multi_node_locks"] = multi_node_enabled
    llm_candidates: list[Dict[str, Any]] = []
    skip_llm_stage = (
        FAST_SKIP_LLM_STAGE
        if runtime_profile == "fast"
        else (FAST_LIVE_SKIP_LLM_STAGE if runtime_profile == "fast_live" else False)
    )
    if skip_llm_stage and llm_mode != "benchmark":
        llm_error = "fast_profile_llm_stage_skipped" if runtime_profile == "fast" else "fast_live_profile_llm_stage_skipped"
    elif llm_budget_remaining < 1.0:
        llm_error = "global_budget_exhausted_before_llm_stage"
    else:
        try:
            if candidate_mode_enabled:
                llm_candidates = get_llm_intuition_candidates(
                    request.spot,
                    llm_config,
                    candidate_count=candidate_target_count,
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
    locked_budget_remaining = max(0.0, request_deadline - time.perf_counter())
    locked_stage_total_effective = max(
        0.0, min(float(stage_budgets["locked_stage_total_sec"]), float(locked_budget_remaining))
    )
    locked_stage_deadline = time.perf_counter() + float(locked_stage_total_effective)
    if llm_candidates:
        if locked_stage_total_effective < 1.0:
            candidate_errors.append("global_budget_exhausted_before_locked_stage")
            llm_error = llm_error or "global_budget_exhausted_before_locked_stage"
            llm_candidates = []
        candidate_runs: list[Dict[str, Any]] = []
        for idx, candidate in enumerate(llm_candidates):
            now = time.perf_counter()
            stage_remaining = locked_stage_deadline - now
            total_remaining = request_deadline - now
            if stage_remaining < 1.0 or total_remaining < 1.0:
                candidate_errors.append("locked_stage_budget_exhausted")
                break
            locked_timeout_effective = int(
                max(
                    1,
                    min(
                        stage_budgets["locked_timeout_sec"],
                        int(math.floor(stage_remaining)),
                        int(math.floor(total_remaining)),
                    ),
                )
            )
            try:
                locked_run = _run_shark_cli(
                    shark_cli,
                    spot_payload=effective_spot,
                    node_lock_payload=candidate,
                    timeout_sec=locked_timeout_effective,
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
        now = time.perf_counter()
        remaining = min(locked_stage_deadline - now, request_deadline - now)
        if remaining < 1.0:
            llm_error = llm_error or "locked_stage_budget_exhausted"
        else:
            locked_timeout_effective = int(max(1, min(stage_budgets["locked_timeout_sec"], int(math.floor(remaining)))))
            locked_run = _run_shark_cli(
                shark_cli,
                spot_payload=effective_spot,
                node_lock_payload=node_lock,
                timeout_sec=locked_timeout_effective,
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
    elif llm_error == "fast_profile_llm_stage_skipped":
        selection_reason = "fast_profile_llm_stage_skipped_using_baseline"
    elif llm_error:
        selection_reason = "llm_generation_failed_using_baseline"
    elif node_lock is None:
        selection_reason = "no_llm_lock_available_using_baseline"
    else:
        selection_reason = "locked_result_missing_metric_using_baseline"

    neural_payload = None
    neural_error: Optional[str] = None
    neural_elapsed = 0.0
    neural_applied = False
    neural_timeout_effective = 0
    neural_attempted = False
    allowed_actions_before_neural = list(allowed_root_actions)
    if NEURAL_BRAIN_ENABLED and NEURAL_BRAIN_MODE in {"shadow", "prefer"}:
        neural_budget_remaining = max(0.0, request_deadline - time.perf_counter())
        if neural_budget_remaining >= 1.0:
            neural_attempted = True
            neural_timeout_effective = int(max(1, min(NEURAL_BRAIN_TIMEOUT_SEC, int(math.ceil(neural_budget_remaining)))))
            neural_payload, neural_error, neural_elapsed = _run_neural_brain_adapter(
                spot=request.spot,
                allowed_actions=allowed_root_actions,
                timeout_sec=neural_timeout_effective,
            )
            if isinstance(neural_payload, dict):
                neural_allowed = _normalize_action_summary_tokens(neural_payload.get("root_actions", []))
                neural_meta = neural_payload.get("meta") if isinstance(neural_payload.get("meta"), dict) else {}
                neural_surrogate = bool(neural_meta.get("surrogate", False))
                if NEURAL_BRAIN_MODE == "prefer" and not neural_surrogate:
                    result = _apply_neural_overlay_to_result(result, neural_payload)
                    selected_strategy = "neural_brain"
                    selection_reason = "neural_brain_preferred"
                    node_lock_kept = False
                    if neural_allowed:
                        allowed_root_actions = neural_allowed
                    neural_applied = True
                elif NEURAL_BRAIN_MODE == "prefer" and neural_surrogate:
                    neural_error = "surrogate_shadow_only"
        else:
            neural_error = "global_budget_exhausted_before_neural_stage"
    elif NEURAL_BRAIN_ENABLED and NEURAL_BRAIN_MODE == "prefer_on_fast_failover":
        neural_error = "skipped_non_failover_neural_stage"

    selected_action = _primary_action_from_result_payload(result)
    neural_shadow = _build_neural_shadow_summary(
        runtime_profile=runtime_profile,
        mode=NEURAL_BRAIN_MODE,
        attempted=neural_attempted,
        applied=neural_applied,
        elapsed_sec=neural_elapsed,
        timeout_sec=neural_timeout_effective,
        error=neural_error,
        payload=neural_payload,
        selected_action=selected_action,
        allowed_actions_in=allowed_actions_before_neural,
    )

    lock_confidence = _avg_lock_confidence(node_lock)
    lock_quality_score = (
        (0.5 if node_lock_kept else 0.0)
        + (0.3 if bool(result.get("node_lock", {}).get("applied", False)) else 0.0)
        + (0.2 if exploitability_delta is not None and exploitability_delta < 0.0 else 0.0)
    )

    total_bridge_time = time.perf_counter() - bridge_started
    _record_canary_observation(
        fallback=bool(llm_error),
        kept=bool(node_lock_kept),
        latency_sec=total_bridge_time,
    )

    response_payload = {
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
        "neural_shadow": neural_shadow,
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
            "llm_candidate_target_count": candidate_target_count if candidate_mode_enabled else 1,
            "llm_candidate_generated_count": len(llm_candidates),
            "llm_candidate_solve_count": locked_candidate_solve_count,
            "llm_candidate_errors": candidate_errors,
            "llm_is_local_request": is_local_request,
            "multi_node_requested": bool(request.enable_multi_node_locks),
            "multi_node_enabled": multi_node_enabled,
            "multi_node_policy_reason": multi_node_policy_reason,
            "llm_error": llm_error,
            "neural_time_sec": neural_elapsed,
            "neural_error": neural_error,
            "neural_mode": NEURAL_BRAIN_MODE,
            "neural_applied": neural_applied,
            "neural_timeout_sec": neural_timeout_effective,
            "neural_shadow": neural_shadow,
            "runtime_profile": runtime_profile,
            "stage_budgets": stage_budgets,
            "fast_spot_profile": fast_spot_profile_summary,
            "effective_stage_budgets": {
                "request_total_budget_sec": request_total_budget_sec,
                "llm_timeout_sec": llm_timeout_effective,
                "locked_stage_total_sec": locked_stage_total_effective,
            },
        },
        "canary_guardrails": _canary_status_snapshot(),
    }
    return response_payload


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("bridge_server:app", host="127.0.0.1", port=8000, reload=False)
