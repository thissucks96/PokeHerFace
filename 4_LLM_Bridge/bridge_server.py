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
if RUNTIME_PROFILE_DEFAULT not in {"fast", "normal"}:
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
    FAST_SPOT_MIN_ALL_IN_THRESHOLD = float(os.environ.get("FAST_SPOT_MIN_ALL_IN_THRESHOLD", "0.80"))
except ValueError:
    FAST_SPOT_MIN_ALL_IN_THRESHOLD = 0.80
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
FAST_SPOT_BET_SIZES_RAW = os.environ.get("FAST_SPOT_BET_SIZES", "0.5")
FAST_SPOT_RAISE_SIZES_RAW = os.environ.get("FAST_SPOT_RAISE_SIZES", "1.0")
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
FAST_FAILOVER_DEFAULT_FLOP_ACTION = str(os.environ.get("FAST_FAILOVER_DEFAULT_FLOP_ACTION", "check")).strip().lower()
FAST_FAILOVER_DEFAULT_TURN_ACTION = str(os.environ.get("FAST_FAILOVER_DEFAULT_TURN_ACTION", "check")).strip().lower()
FAST_FAILOVER_DEFAULT_RIVER_ACTION = str(os.environ.get("FAST_FAILOVER_DEFAULT_RIVER_ACTION", "check")).strip().lower()
FAST_FORCE_ROOT_ONLY = os.environ.get("FAST_FORCE_ROOT_ONLY", "1").strip() not in {"0", "false", "False"}
FAST_SKIP_LLM_STAGE = os.environ.get("FAST_SKIP_LLM_STAGE", "1").strip() not in {"0", "false", "False"}
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
    if value in {"fast", "normal"}:
        return value
    return RUNTIME_PROFILE_DEFAULT


def _stage_budget_value(request_timeout: int, cap: int) -> int:
    timeout = max(10, int(request_timeout))
    cap_val = max(10, int(cap))
    return max(10, min(timeout, cap_val))


def _resolve_stage_budgets(runtime_profile: str, request_timeout: int, spot: Optional[Dict[str, Any]] = None) -> Dict[str, int]:
    if runtime_profile == "fast":
        baseline_cap = FAST_BASELINE_TIMEOUT_SEC
        llm_cap = FAST_LLM_TIMEOUT_SEC
        locked_cap = FAST_LOCKED_TIMEOUT_SEC
        locked_total_cap = FAST_LOCKED_STAGE_TOTAL_SEC
    else:
        baseline_cap = NORMAL_BASELINE_TIMEOUT_SEC
        llm_cap = NORMAL_LLM_TIMEOUT_SEC
        locked_cap = NORMAL_LOCKED_TIMEOUT_SEC
        locked_total_cap = NORMAL_LOCKED_STAGE_TOTAL_SEC

    baseline_timeout = _stage_budget_value(request_timeout, baseline_cap)
    if runtime_profile == "fast" and isinstance(spot, dict):
        spot_street = _detect_spot_street(spot)
        street_cap = None
        if spot_street == "flop":
            street_cap = FAST_BASELINE_TIMEOUT_FLOP_SEC
        elif spot_street == "turn":
            street_cap = FAST_BASELINE_TIMEOUT_TURN_SEC
        elif spot_street == "river":
            street_cap = FAST_BASELINE_TIMEOUT_RIVER_SEC
        if isinstance(street_cap, int):
            baseline_timeout = _stage_budget_value(baseline_timeout, street_cap)
    llm_timeout = _stage_budget_value(request_timeout, llm_cap)
    locked_timeout = _stage_budget_value(request_timeout, locked_cap)
    locked_total_timeout = _stage_budget_value(request_timeout, locked_total_cap)
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

    all_in_threshold = _to_float_or_none(tuned.get("all_in_threshold"))
    if all_in_threshold is not None:
        clamped_threshold = max(FAST_SPOT_MIN_ALL_IN_THRESHOLD, float(all_in_threshold))
        clamped_threshold = min(clamped_threshold, 0.99)
        if abs(clamped_threshold - float(all_in_threshold)) > 1e-9:
            changes["all_in_threshold"] = {"from": float(all_in_threshold), "to": clamped_threshold}
        tuned["all_in_threshold"] = clamped_threshold
    else:
        tuned["all_in_threshold"] = min(max(FAST_SPOT_MIN_ALL_IN_THRESHOLD, 0.50), 0.99)
        changes["all_in_threshold"] = {"from": None, "to": tuned["all_in_threshold"]}

    if FAST_SPOT_FORCE_COMPRESS_STRATEGY:
        old = tuned.get("compress_strategy")
        tuned["compress_strategy"] = True
        if old is not True:
            changes["compress_strategy"] = {"from": old, "to": True}
    if FAST_SPOT_FORCE_REMOVE_DONK_BETS:
        old = tuned.get("remove_donk_bets")
        tuned["remove_donk_bets"] = True
        if old is not True:
            changes["remove_donk_bets"] = {"from": old, "to": True}

    bet_sizes = _parse_sizing_env(FAST_SPOT_BET_SIZES_RAW, [0.5])
    raise_sizes = _parse_sizing_env(FAST_SPOT_RAISE_SIZES_RAW, [1.0])
    target_bet_sizing = {
        "flop": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
        "turn": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
        "river": {"bet_sizes": bet_sizes, "raise_sizes": raise_sizes},
    }
    old_bet_sizing = tuned.get("bet_sizing")
    tuned["bet_sizing"] = target_bet_sizing
    if old_bet_sizing != target_bet_sizing:
        changes["bet_sizing"] = "reduced_to_fast_profile"

    summary = {
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


def _fallback_actions_from_spot(spot: Dict[str, Any]) -> list[str]:
    street = _detect_spot_street(spot)
    actions: list[str] = ["check"]
    minimum_bet = _to_float_or_none(spot.get("minimum_bet")) or 1.0
    starting_pot = _to_float_or_none(spot.get("starting_pot")) or (minimum_bet * 2.0)
    bet_sizing = spot.get("bet_sizing", {})
    if isinstance(bet_sizing, dict):
        street_cfg = bet_sizing.get(street, {})
        if isinstance(street_cfg, dict):
            bet_sizes = street_cfg.get("bet_sizes", [])
            if isinstance(bet_sizes, list):
                numeric_sizes = [float(x) for x in bet_sizes if isinstance(x, (int, float)) and float(x) > 0.0]
                if numeric_sizes:
                    amount = int(max(minimum_bet, round(starting_pot * min(numeric_sizes))))
                    actions.append(f"bet:{amount}")
    if all(not token.startswith("bet:") for token in actions):
        actions.append(f"bet:{int(max(1.0, minimum_bet))}")
    actions.append("fold")
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
        return {"paired": False, "monotone": False, "connected": False, "dry": False}
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
    monotone = len(suits) >= 3 and len(set(suits[:3])) == 1
    unique_ranks = sorted(set(ranks[:3]))
    connected = len(unique_ranks) >= 3 and (max(unique_ranks) - min(unique_ranks) <= 5)
    dry = bool(ranks) and not paired and not monotone and not connected
    return {
        "paired": paired,
        "monotone": monotone,
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


def _choose_fast_failover_action(spot: Dict[str, Any], allowed_actions: list[str]) -> str:
    street = _detect_spot_street(spot)
    if street == "flop":
        smallest_bet = _choose_smallest_sized_action(allowed_actions, "bet")
        if smallest_bet:
            texture = _extract_board_texture_flags(spot)
            if _hero_is_in_position(spot) and texture["dry"]:
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
    allowed_actions = _fallback_actions_from_spot(request.spot)
    chosen_action = _choose_fast_failover_action(request.spot, allowed_actions)
    root_actions = [_token_to_root_action(token, chosen_action) for token in allowed_actions]
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
            "policy": "lookup_fallback",
        },
        "warnings": [f"fast_failover_applied:{baseline_error}"],
    }
    return {
        "status": "ok",
        "node_lock": None,
        "node_lock_kept": False,
        "selected_strategy": "fallback_lookup_policy",
        "selection_reason": selection_reason,
        "allowed_root_actions": allowed_actions,
        "multi_node_policy": {
            "requested": bool(request.enable_multi_node_locks),
            "enabled": False,
            "reason": multi_node_policy_reason,
            "rollout_classes": _extract_rollout_classes(request.spot),
        },
        "result": result_payload,
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
        "fast_failover_default_flop_action": FAST_FAILOVER_DEFAULT_FLOP_ACTION,
        "fast_failover_default_turn_action": FAST_FAILOVER_DEFAULT_TURN_ACTION,
        "fast_failover_default_river_action": FAST_FAILOVER_DEFAULT_RIVER_ACTION,
        "fast_force_root_only": FAST_FORCE_ROOT_ONLY,
        "fast_skip_llm_stage": FAST_SKIP_LLM_STAGE,
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
    if runtime_profile == "fast":
        effective_spot, fast_spot_profile_summary = _apply_fast_spot_profile(effective_spot)

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
        if runtime_profile == "fast" and FAST_FAILOVER_ON_BASELINE_ERROR:
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
    if runtime_profile == "fast" and FAST_FORCE_ROOT_ONLY and llm_mode != "benchmark":
        multi_node_enabled = False
        multi_node_policy_reason = f"{multi_node_policy_reason}+fast_root_only"
        candidate_target_count = 1
    is_local_request = _is_local_request(llm_config)
    llm_budget_remaining = max(0.0, request_deadline - time.perf_counter())
    llm_timeout_effective = int(max(1, min(stage_budgets["llm_timeout_sec"], int(math.ceil(llm_budget_remaining)))))
    llm_config["timeout_sec"] = float(llm_timeout_effective)
    if runtime_profile == "fast" and "max_tokens" not in llm_config:
        llm_config["max_tokens"] = FAST_MAX_TOKENS
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
    if runtime_profile == "fast" and FAST_SKIP_LLM_STAGE and llm_mode != "benchmark":
        llm_error = "fast_profile_llm_stage_skipped"
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
