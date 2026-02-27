# PokerBotV1 Workspace

This workspace is organized to keep the engine, neural models, hand history data, and LLM bridge isolated but integration-ready.

## Folder Layout

- `1_Engine_Core`: C++ Shark solver and build system.
- `2_Neural_Brain`: DeepHoldem/DeepStack-style PyTorch stack and pretrained model files.
- `3_Hand_Histories`: PHH/raw hand history data.
- `4_LLM_Bridge`: Python bridge for Docker-hosted LLM -> node-lock JSON.
- `libs`: Third-party native dependencies (including `libtorch`).

## Current App Status

- `shark.exe` (GUI) builds and launches on Windows.
- `shark_cli.exe` (headless) accepts JSON input/output for automated solves.
- Node-lock targets are enforced in CFR by `node_id` + `street` (root and non-root).
- Python bridge server (`POST /solve`) runs a two-pass safety loop:
  - baseline no-lock solve,
  - legal-action-constrained lock generation (with opponent profile + node catalog context),
  - locked solve,
  - automatic selection of better result (baseline if lock is not better than baseline by `EV_KEEP_MARGIN`, default `0.001`).
  - turn multi-node guardrail: requires a root anchor target, prunes deep branch-only locks (`depth > 1`), and coerces the best deep proposal into a legal root anchor when needed to avoid check-only synthetic locks.
- Spot pack tooling is available via `4_LLM_Bridge/build_spot_pack.py` for bulk PHH -> tagged spot conversion with manifest/report output.
- PHH opponent-feature extraction is available via `4_LLM_Bridge/extract_opponent_features.py`:
  - `fold_to_turn_probe` (smoothed),
  - `fold_to_river_bigbet` (smoothed),
  - `river_bluff_rate` (smoothed),
  - optional per-player profiles + pool profile.
- Generated spot packs now include `spot.meta.opponent_profile` (pool profile by default) for LLM prompt conditioning.
- Canonical acceptance tooling is available:
  - `4_LLM_Bridge/build_canonical_pack.py` creates fixed, stratified canonical packs across configurable streets (`--streets`, `--min-per-street`).
  - `4_LLM_Bridge/run_acceptance_gate.py` runs preflight filtering + pass/fail gate + EV noise calibration, with optional `spot.meta.opponent_profile` injection.
  - `4_LLM_Bridge/tag_spot_classes.py` tags spots for phased multi-node rollout classes.
- LLM provider selection is supported in the bridge:
  - mock
  - OpenAI API (`gpt-5-mini`, `gpt-5.2`)
  - local OpenAI-compatible endpoints (default production model: `qwen3-coder:30b`)
- Bridge production policy can enforce local routing to `qwen3-coder:30b` only (challengers allowed in `mode=benchmark`).
- Bridge now supports canary guardrails with auto kill-switch behavior on rolling metrics:
  - fallback-rate breach,
  - keep-rate breach,
  - p95 latency breach.

### Phase 13 Bookmark (Local Baseline Locked)

- 5-seed local A/B/C verification completed on `2026-02-26` across seeds:
  - `1001`, `2026`, `4090`, `7777`, `9999`
- 40-spot aggregate results (`test_backtest_abc.ps1`, local `qwen3-coder:30b`):
  - `class1_live_shadow23 bb100_avg = +0.4373`
  - `full_multi_node_benchmark bb100_avg = +0.4373`
  - `fallback_avg = 0.00`
  - `keep_avg = 0.975`
- Gate status:
  - `turn_class1`: pass (`fallback=0.00`, `lock_applied=0.95`, `keep=0.95`)
  - `river_class23`: pass (`fallback=0.00`, `lock_applied=1.00`, `keep=1.00`)
- Baseline interpretation:
  - Local-only pipeline is stable and profitable on the canonical 40-spot proxy run set.
  - Full multi-node and class1-shadow routing are effectively at parity in this sweep.

### Estimated Current Strength

- Overall estimate (current build): **strong constrained decision engine, medium overall deployment maturity**.
- Evidence-backed strength:
  - Positive proxy edge on canonical benchmark mix: `~ +0.437 bb/100` average across 5 seeds.
  - Safety/reliability is high: `fallback=0.00`, `keep~0.975` in multi-seed A/B/C sweeps.
  - Turn and River acceptance gates pass at or above target thresholds.
- Practical interpretation:
  - The app is clearly stronger than unguided/gambling play and stable for structured turn/river decision support.
  - True table-level strength vs stronger human pools still depends on longer live/backtest telemetry beyond canonical packs.

## Current Limits

- Multi-node lock generation is policy-gated by rollout class/routing in the bridge and should remain controlled via env toggles during canary scheduling.
- Hand-history ingestion from `3_Hand_Histories` into spot generation is not fully automated yet.
- LLM quality benchmarking and routing policy tuning are still in progress (current local front-runner: `qwen3-coder:30b`).
- Cloud/API calls are currently Tier 1 rate-limited; bridge enforces serialized OpenAI call spacing via `OPENAI_MIN_INTERVAL_SEC` (default `2.5`).

## Quick Start (Windows)

Run from `A:\PokeHerFace\Version1`:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\setup_windows.ps1
```

Optional tool install pass (uses `winget`):

```powershell
.\scripts\setup_windows.ps1 -InstallTools
```

Run preflight validation (toolchain + runtime DLL staging + shark launch smoke test):

```powershell
.\scripts\preflight_windows.ps1
```

For C++ builds you also need MSVC build tools (`cl.exe`, `nmake`) via Visual Studio Build Tools with the Desktop C++ workload.

## CI Gate Command

Run the canonical acceptance gate (local default model):

```powershell
.\scripts\test_ci.ps1 -Preset local_qwen3_coder_30b -EvKeepMargin 0.001
```

This command starts required local services if needed, runs the 20-spot canonical gate, and exits non-zero on gate failure.

## PowerShell Test Runners

Run class-specific acceptance suites:

```powershell
.\scripts\test_acceptance.ps1 -Suite turn_class1 -Preset local_qwen3_coder_30b
.\scripts\test_acceptance.ps1 -Suite river_class23 -Preset local_qwen3_coder_30b
```

Current API testing policy: use `openai_52` as the only cloud preset by default.

Run A/B/C routing backtest (`baseline_gto`, `class1_live_shadow23`, `full_multi_node_benchmark`):

```powershell
.\scripts\test_backtest_abc.ps1 -Preset local_qwen3_coder_30b -MaxSpots 40
```

Analyze River shadow diagnostics (where full multi-node underperforms class1-shadow):

```powershell
python .\4_LLM_Bridge\analyze_shadow_dumps.py `
  --backtest-report .\4_LLM_Bridge\examples\backtest.abc.ps1.json `
  --output .\4_LLM_Bridge\examples\backtest.shadow_diagnostics.json
```

Run multi-seed gauntlet (builds profiled turn/river pools from PHH by default):

```powershell
.\scripts\test_multiseed_gauntlet.ps1 -Preset local_qwen3_coder_30b
```

Run canary sweeps with one command (starts services, applies guardrails, streams progress, writes summary + config snapshot, stops cleanly):

```powershell
# 2-hour mini-canary (recommended first)
.\scripts\run_canary.ps1 -Profile mini2h -Preset local_qwen3_coder_30b

# 4-hour mini-canary extension
.\scripts\run_canary.ps1 -Profile mini4h -Preset local_qwen3_coder_30b

# 48-hour long canary
.\scripts\run_canary.ps1 -Profile full48h -Preset local_qwen3_coder_30b
```

Each canary run writes artifacts under:
`4_LLM_Bridge/examples/canary_runs/canary.<timestamp>.<profile>/`

- `config_snapshot.json` (includes git commit hash + thresholds + run config)
- `.env.snapshot` (if present at `4_LLM_Bridge/.env`)
- `records.ndjson` (per-call telemetry)
- `summary.json` (final pass/fail + alerts)

Alert thresholds are included directly in canary summaries:
- `fallback_rate > max_fallback_rate`
- `keep_rate < min_keep_rate`
- `latency_p95_sec > max_p95_latency_sec`

Guardrail env controls (applied by `run_canary.ps1`):
- `CANARY_GUARDRAILS_ENABLED=1`
- `CANARY_WINDOW_CALLS`
- `CANARY_MIN_CALLS_BEFORE_TRIP`
- `CANARY_MAX_FALLBACK_RATE`
- `CANARY_MIN_KEEP_RATE`
- `CANARY_MAX_P95_LATENCY_SEC`
- `CANARY_KILL_SWITCH_MODE` (`baseline_only` or `reject`)

Run the full stack in one command (`CI + turn/river acceptance + A/B/C`; gauntlet optional):

```powershell
.\scripts\test_all.ps1 -Preset local_qwen3_coder_30b
.\scripts\test_all.ps1 -Preset local_qwen3_coder_30b -IncludeGauntlet
```

Run live per-call progress in the terminal for API/local benchmark calls:

```powershell
.\scripts\test_api_progress.ps1 -Presets openai_52 -CallsPerModel 10
```

Launch the manual user-facing clickable interface (desktop preview, no solver actions yet):

```powershell
.\PLAY_MANUAL.ps1
```

OCR note for manual UI prep:
- `PLAY_MANUAL.ps1` now detects Tesseract and includes an `OCR Check` button.
- Detection order:
  1. `TESSERACT_PATH` env var,
  2. `tesseract` from `PATH`,
  3. fallback path `C:\Program Files\Tesseract-OCR\tesseract.exe`.

ShareX API ingest setup (dedicated vision pipeline):

- Workspace: `5_Vision_Extraction/`
- Local endpoint: `POST http://127.0.0.1:8000/vision/ingest`
- ShareX hook script:

```powershell
powershell.exe -ExecutionPolicy Bypass -File A:\PokeHerFace\Version1\5_Vision_Extraction\sharex_ingest.ps1 -ImagePath "$input"
```

The hook ensures the bridge is running, submits capture path to `/vision/ingest`, and writes latest response logs under:
- `5_Vision_Extraction/out/latest_sharex_ingest_response.json`
- `5_Vision_Extraction/out/sharex_ingest_response.*.json`

Clickable OCR watcher test utility:

```powershell
.\tesseract_test.ps1
```

- Click `Pick ROI` and drag-select per-card ROIs (`flop1`, `flop2`, `flop3`, `turn`, `river`).
- Fast testing controls:
  - `Run flop1` ... `Run river`, plus `Run hero1` / `Run hero2`, for single-slot OCR checks.
  - `Run Flop (1-3)` for atomic flop capture.
  - `Run Turn+E` and `Run River+E` for staged board capture + immediate engine handoff.
- Hero auto-send:
  - define separate ROIs for `hero1` and `hero2`,
  - once both hero cards are identified and board cards are valid, tester auto-queues engine solve.
- Engine handoff from tester:
  - staged runs (`Run Flop (1-3)`, `Run Turn+E`, `Run River+E`) validate strict rank+suit cards (`[AKQJT98765432][shdc]`),
  - builds a spot payload from `4_LLM_Bridge/examples/spot.sample.json` (board replaced by captured flop/turn/river street state),
  - sends one request to `POST /solve` in a background job (non-blocking UI),
  - writes payload/response artifacts under `5_Vision_Extraction/out/flop_engine/`.
- Session logs from tester:
  - text log: `5_Vision_Extraction/out/ui_session_logs/session_*.log`
  - structured log: `5_Vision_Extraction/out/ui_session_logs/session_*.jsonl`
- Optional env overrides for tester handoff:
  - `BRIDGE_SOLVE_ENDPOINT` (default `http://127.0.0.1:8000/solve`)
  - `ENGINE_SPOT_TEMPLATE_PATH` (default `4_LLM_Bridge/examples/spot.sample.json`)
  - `ENGINE_OCR_OUT_DIR` (default `5_Vision_Extraction/out/flop_engine`)
  - `ENGINE_LLM_PRESET` (default `local_qwen3_coder_30b`)
  - `ENGINE_ENABLE_MULTI_NODE` (`0`/`1`, default `0`)
  - `ENGINE_SOLVER_TIMEOUT_SEC` (default `180`)
  - `BACKEND_AUTOSTART` (`1`/`0`, default `1`)

Backend lifecycle in tester:
- On launch, tester checks Ollama + bridge endpoints and auto-starts missing services.
- On close/restart, tester stops only the backend processes it started in that session.

## Quick Start (WSL / Linux)

```bash
cd /mnt/a/PokeHerFace/Version1
chmod +x ./scripts/setup_wsl.sh
./scripts/setup_wsl.sh
```

Optional package install pass:

```bash
./scripts/setup_wsl.sh --install-tools
```

## Required Manual Drops

1. Extract CUDA LibTorch into:
   `libs/libtorch`
2. Ensure models exist in:
   `2_Neural_Brain/data/models` (`.pt` or `.tar`)
3. Keep large neural artifacts out of Git history:
   `2_Neural_Brain/src/**` model assets (`.pt`, `.pkl`, `.sqlite`, `.tar`, `.model`) should be local-only.

## C++ GPU Bridge Configure Command

```powershell
cmake -S A:\PokeHerFace\Version1\1_Engine_Core `
      -B A:\PokeHerFace\Version1\1_Engine_Core\build `
      -DENABLE_LIBTORCH=ON `
      -DLIBTORCH_ROOT=A:\PokeHerFace\Version1\libs\libtorch
```

If CMake reports missing `nmake` or compiler, run from a Visual Studio Developer PowerShell/Command Prompt.

## Headless Solver Contract (`shark_cli`)

`shark_cli` now supports JSON-driven headless mode:

```powershell
A:\PokeHerFace\Version1\1_Engine_Core\build_ninja_vcpkg_rel\shark_cli.exe `
  --input A:\PokeHerFace\Version1\1_Engine_Core\testing\fixtures\spot.sample.json `
  --node-lock A:\PokeHerFace\Version1\1_Engine_Core\testing\fixtures\node_lock.sample.json `
  --output A:\PokeHerFace\Version1\1_Engine_Core\testing\fixtures\result.sample.json
```

- Input schema: `spot.json` (`hero_range`, `villain_range`, `board`, solve params).
- Optional input: `node_lock.json` (`node_locks` array preferred; legacy single-target fields still accepted).
- Output schema: `result.json` (timing, exploitability, tree stats, root action frequencies, node-lock catalog, warnings).

## Project Direction

This project combines:

- high-performance poker solving on RTX 4090 (especially compute-heavy turn/river spots), and
- a modern LLM-hybrid layer for strategy interpretation and node-lock generation.

### Near-Term Direction

1. Run canonical acceptance gate regularly and track `fallback_rate`, `lock_applied_rate`, `keep_rate`, and lock-quality telemetry.
2. Benchmark local challengers (`gpt-oss:20b`, Qwen, DeepSeek) vs OpenAI presets on the same canonical pack.
3. Expand/validate multi-node lock prompts against canonical packs before enabling by default.
4. Continue PHH -> spot pack automation with stronger depth/position tagging coverage.
5. Expand opponent-feature set beyond baseline fold metrics (turn check-raise, river bluff rate, line-specific fold rates).

## Long-Test Queue

1. `mini2h` canary: `.\scripts\run_canary.ps1 -Profile mini2h -Preset local_qwen3_coder_30b`
2. `mini4h` canary: `.\scripts\run_canary.ps1 -Profile mini4h -Preset local_qwen3_coder_30b`
3. `full48h` canary: `.\scripts\run_canary.ps1 -Profile full48h -Preset local_qwen3_coder_30b`
4. Post-canary 5-seed reconfirmation: run `test_backtest_abc.ps1` with seeds `1001, 2026, 4090, 7777, 9999`.
