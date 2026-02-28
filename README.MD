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
- `shark_cli.exe` now supports optional `active_node_path` input and returns `active_node_actions` for the matching solved node when present.
  - Current limitation: `active_node_actions` are node-level range averages, not exact combo-conditioned frequencies yet.
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

### Vision Queue Status (Current Workstream)

- We are actively building the visual window queue path from ROI captures into solver payloads.
- Current behavior:
  - hero and board OCR can be captured from the clickable tester and queued to `/solve`,
  - UI stays responsive while engine jobs run in background,
  - backend auto-start/stop is managed by the tester (with minimized startup windows).
- Current blockers:
  - OCR speed is still slower than target for live pacing,
  - OCR misses/retries still create latency spikes,
  - mixed run paths (`Run Hero`, single-slot, staged runs) still need tighter state-machine consistency.
- In-scope implementation files for this phase:
  - `tesseract_test.ps1`,
  - `4_LLM_Bridge/bridge_server.py`,
  - `4_LLM_Bridge/llm_client.py`.

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

Runtime profile selection (A_2 toggle):

```powershell
# Low-latency profile
.\scripts\test_acceptance.ps1 -Suite turn_class1 -Preset local_qwen3_coder_30b -RuntimeProfile fast

# Live-capped mini-solve profile
.\scripts\test_acceptance.ps1 -Suite turn_class1 -Preset local_qwen3_coder_30b -RuntimeProfile fast_live

# Full-latency profile
.\scripts\test_acceptance.ps1 -Suite turn_class1 -Preset local_qwen3_coder_30b -RuntimeProfile normal
```

Current API testing policy: use `openai_52` as the only cloud preset by default.

Run A/B/C routing backtest (`baseline_gto`, `class1_live_shadow23`, `full_multi_node_benchmark`):

```powershell
.\scripts\test_backtest_abc.ps1 -Preset local_qwen3_coder_30b -MaxSpots 40
```

With explicit runtime profile:

```powershell
.\scripts\test_backtest_abc.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast -MaxSpots 40
.\scripts\test_backtest_abc.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast_live -MaxSpots 40
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

Fast profile end-to-end:

```powershell
.\scripts\test_all.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast
.\scripts\test_all.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast_live
```

Run a cloned fast-edge profile sweep (same acceptance + A/B/C flow, tuned for lower latency):

```powershell
.\scripts\test_fast_profile.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast -ProfileName fast_edge_v1 -RestartServices
```

Run synthetic end-to-end process timing (full `/solve` flow on the 10-hand synthetic pack, with bottleneck JSON report):

```powershell
.\scripts\test_synthetic_pack.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast
```

Direct python runner (same report, custom output path):

```powershell
python .\4_LLM_Bridge\run_synthetic_hand_pack.py `
  --pack .\4_LLM_Bridge\examples\synthetic_hands\ten_hand_progression.json `
  --preset local_qwen3_coder_30b `
  --runtime-profile fast `
  --output .\4_LLM_Bridge\examples\synthetic_hands\timing_report.json
```

`test_fast_profile.ps1` writes a single run folder under `4_LLM_Bridge/examples/fast_profile_runs/` with:
- profile env snapshot,
- turn/river acceptance summaries + details,
- A/B/C backtest report,
- consolidated `fast_profile.summary.json`.

Bridge runtime profile budgets (`POST /solve`):
- `runtime_profile=fast`:
  - baseline timeout cap: `FAST_BASELINE_TIMEOUT_SEC` (default `60`)
  - street baseline caps:
    - `FAST_BASELINE_TIMEOUT_FLOP_SEC` (default `15`)
    - `FAST_BASELINE_TIMEOUT_TURN_SEC` (default `25`)
    - `FAST_BASELINE_TIMEOUT_RIVER_SEC` (default `25`)
  - `FAST_FLOP_LOOKUP_ONLY` (`1`/`0`, default `1`) bypasses the expensive flop baseline solve entirely and returns a lightweight flop lookup policy immediately in `fast` mode.
    - current heuristic: small flop c-bet on dry boards when hero is in position; otherwise conservative fallback (`check`/`call`).
  - `FAST_TURN_LOOKUP_ONLY` (`1`/`0`, default `0`) optionally applies the same idea to turn in `fast` mode.
    - current heuristic: small turn stab only on dry, unpaired boards when hero is in position; otherwise conservative fallback (`check`/`call`).
  - LLM stage timeout cap: `FAST_LLM_TIMEOUT_SEC` (default `25`)
  - locked solve timeout cap: `FAST_LOCKED_TIMEOUT_SEC` (default `60`)
  - locked stage total budget: `FAST_LOCKED_STAGE_TOTAL_SEC` (default `90`)
  - lean spot profile auto-tuning:
    - `FAST_SPOT_MAX_ITERATIONS` (default `2`)
    - `FAST_SPOT_MAX_THREADS` (default `8`)
    - `FAST_SPOT_MAX_RAISE_CAP` (default `2`)
    - `FAST_SPOT_MIN_ALL_IN_THRESHOLD` (default `0.80`)
    - `FAST_SPOT_FORCE_COMPRESS_STRATEGY` (default `1`)
    - `FAST_SPOT_FORCE_REMOVE_DONK_BETS` (default `1`)
    - `FAST_SPOT_BET_SIZES` csv (default `0.5`)
    - `FAST_SPOT_RAISE_SIZES` csv (default `1.0`)
  - fast runtime policy router:
    - `FAST_FORCE_ROOT_ONLY` (default `1`) forces root-only lock path in fast profile.
    - `FAST_SKIP_LLM_STAGE` (default `1`) skips lock generation in fast profile unless benchmark mode.
  - fast fallback ladder:
    - `FAST_FAILOVER_ON_BASELINE_ERROR` (default `1`) returns immediate lookup fallback payload instead of HTTP 504 when baseline stage fails.
    - `FAST_FAILOVER_DEFAULT_FLOP_ACTION` / `FAST_FAILOVER_DEFAULT_TURN_ACTION` / `FAST_FAILOVER_DEFAULT_RIVER_ACTION` (defaults `check`).
- `runtime_profile=fast_live`:
  - baseline timeout cap: `FAST_LIVE_BASELINE_TIMEOUT_SEC` (default `3`)
  - street baseline caps:
    - `FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC` (default `3`)
    - `FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC` (default `2`)
    - `FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC` (default `1`)
  - active-node baseline cap:
    - `FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC` (default `4`) only applies when `spot.active_node_path` is present, so non-root decision tests can get a slightly larger budget without slowing all root-level `fast_live` solves.
    - `FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC` (default `6`) overrides that active-node cap only for non-root flop solves, because flop is currently the only street still overrunning the tighter active-node budget.
    - `FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY` (default `1`) skips the expensive non-root flop solve entirely and returns the immediate lookup fallback on that path, while preserving real non-root solver math for turn and river.
    - that non-root flop fallback is now deterministic and MDF-based: it parses the facing bet from `active_node_path`, uses pot geometry plus simple board texture flags to emit a lightweight weighted `fold` / `call` / (sometimes) `raise` mix instead of the old hardcoded `call`.
    - when `spot.active_node_path` is present, `fast_live` also reduces the action tree instead of fully preserving caller sizing: it keeps only the active street's first lead size, trims that street to one reduced raise size, and applies the compact `fast_live` sizing profile on later streets.
  - compact live mini-solve spot profile:
    - `FAST_LIVE_SPOT_MAX_ITERATIONS` (default `1`)
    - `FAST_LIVE_SPOT_MAX_THREADS` (default `2`)
    - `FAST_LIVE_SPOT_MAX_RAISE_CAP` (default `1`)
    - `FAST_LIVE_SPOT_MIN_ALL_IN_THRESHOLD` (default `0.80`)
    - `FAST_LIVE_SPOT_FORCE_COMPRESS_STRATEGY` (default `1`)
    - `FAST_LIVE_SPOT_FORCE_REMOVE_DONK_BETS` (default `1`)
    - `FAST_LIVE_SPOT_BET_SIZES` csv (default `0.25`)
    - `FAST_LIVE_SPOT_RAISE_SIZES` csv (default `0.75`)
  - live runtime policy router:
    - `FAST_LIVE_FORCE_ROOT_ONLY` (default `1`) forces root-only, solver-first live behavior.
    - `FAST_LIVE_SKIP_LLM_STAGE` (default `1`) skips LLM/node-lock generation by default for the capped live path.
    - `FAST_LIVE_MAX_TOKENS` (default `160`) is applied only if the LLM stage is explicitly re-enabled.
  - fallback ladder:
    - `FAST_LIVE_FAILOVER_ON_BASELINE_ERROR` (default `1`) returns the same immediate lookup fallback if the capped baseline stage times out or errors.
  - intended role: the production-candidate middle tier between `fast` and `normal` (real mini-solve under hard latency caps).
- `runtime_profile=normal`:
  - baseline timeout cap: `NORMAL_BASELINE_TIMEOUT_SEC` (default `900`)
  - LLM stage timeout cap: `NORMAL_LLM_TIMEOUT_SEC` (default `60`)
  - locked solve timeout cap: `NORMAL_LOCKED_TIMEOUT_SEC` (default `900`)
  - locked stage total budget: `NORMAL_LOCKED_STAGE_TOTAL_SEC` (default `900`)

In `runtime_profile=fast`, bridge metrics now include `fast_spot_profile` so timing reports can confirm exactly which spot reductions were applied.

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

No-engine startup variant:

```powershell
.\tesseract_test_noengine.ps1
```

- Click `Pick ROI` and drag-select ROIs for board cards (`flop1`, `flop2`, `flop3`, `turn`, `river`), `hero` (auto-clones to `hero2`), and action placeholders (`check_btn`, `fold_btn`, `call_btn`, `raise_btn`, `allin_btn`).
- Board and hero overlays now render the assigned card token in the center of the box (for example `A♠`) while keeping the slot label in the corner.
- The tester UI includes a dedicated `ADVICE` panel plus a draggable floating advice overlay that auto-opens on startup. While the engine is busy it shows `THINKING`; after a completed solve it now renders the bridge recommendation plus the top two weighted actions from `result.root_actions`, with strategy/time metadata on a second line for readability.
- The advice primary label now buckets engine output into clearer user actions (`CHECK`, `CALL`, `CALL ANY`, `FOLD`, `RAISE`) and preserves explicit amounts when the bridge returns them (for example `CALL 3`, `RAISE 12`).
- Manual `CALL` / `RAISE` prompts now default to the last recommended engine amount when one is available, so the user can accept or edit the suggested size instead of retyping from scratch.
- The visible manual action controls now use a dynamic `Check` / `Call` button, `Fold`, `Raise`, and `All In`; the first button automatically flips to `Call` whenever the current advice/action mix includes a call path, otherwise it stays `Check`. `All In` commits the entire remaining hero stack immediately.
- The main tester window now reflows on resize: the left workspace expands/contracts, the advice panel stays pinned to the right, and the log/output panes scale with the window instead of colliding.
- The manual action buttons were moved into the right-side advice panel so the header rows stay focused on capture/run controls instead of stacking every control in one strip.
- The target picker now exposes the simplified live labels (`hero`, `pot`, `check`, `fold`, `call`, `raise`, `all_in`) while still mapping those controls back to the underlying ROI keys internally. Legacy `bet_btn` remains supported as a compatibility alias for older saved ROIs.
- The advice panel was simplified: the low-value static "Planned Outputs" block was removed so the live advice detail gets more vertical space.
- The advice panel now also includes editable stake controls for `SB`, `BB`, and `Buy-In`. The tester rescales engine payloads from the current template in big-blind units, so `minimum_bet`, `starting_pot`, `starting_stack`, and the local preflop raise size all follow the configured stakes instead of staying hardcoded at `1/2` blinds and `100` buy-in.
- The tester now tracks a simple live table state:
  - `Current Pot`
  - `Hero Stack`
  - these values are shown in the right-side panel and in a draggable floating state overlay, and the engine payload now uses them directly so manual action updates affect subsequent solves.
- Under the hood, the tester now also carries a future-facing betting scaffold (`facing_bet`, per-street hero/villain commitments, and villain-count fields) even before villain controls are exposed. That state is already included in the engine logical-state key and payload metadata so same-board betting changes are not incorrectly skipped as "no state change."
- Right-click any board-card or hero-card overlay to open a quick context menu:
  - top-level `Random Card` for a legal non-duplicate assignment
  - `Set Card` -> suit (`Spade ♠`, `Heart ♥`, `Diamond ♦`, `Club ♣`) -> rank (`A`..`2`) for manual card entry
    - Manual board assignment auto-queues a street solve once the board becomes complete for that street (3 cards = flop, 4 = turn, 5 = river), but only after hero cards are valid.
    - Cards already assigned anywhere else are removed from the picker, so duplicate hero/community cards cannot be selected accidentally.
    - Manual card assignment is authoritative for that slot: OCR/vision skips that slot until you clear it.
    - If you assign community cards before hero cards are set, the tester logs a safety warning so you know hero state is still missing.
  - `Run OCR`
  - `Repick ROI`
  - `Clear ROI`
- Right-click any action ROI overlay (`check_btn`, `fold_btn`, `call_btn`, `bet_btn`, `raise_btn`, `allin_btn`) to use that action directly as a manual advice override; those overlays now render their action text in the center and share the same action color language as the advice panel. (`bet_btn` remains accepted as a legacy internal alias, but the visible UI now uses `Raise` as the single standard aggressive action.)
- A dedicated `pot` ROI target now uses Tesseract's numeric OCR profile. Running OCR on that ROI parses the visible pot amount and updates both the live table-state display and the next engine payload.
- `CALL` and `RAISE` manual actions now prompt for an amount, subtract that commitment from `Hero Stack`, and add it to `Current Pot`; `ALL IN` skips the prompt and commits the full remaining hero stack immediately, so the tester's state stays aligned with what is being sent to the engine.
- The single-slot quick-test strip can now be hidden/shown with `Hide Quick Tests` / `Show Quick Tests` so the main staged controls have more space when you do not need per-slot debug runs.
- The hidden/shown quick-test state is persisted across restarts, and the floating `Advice` / `Table State` overlay windows now remember their last screen positions.
- A top-level `Random Card` button is also available in the main control strip; it assigns a legal non-duplicate card to the currently selected card target (or the next unresolved hero slot when `hero` is selected).
- A `New Hand` button clears the staged hero/board cards and solver hand state while preserving the current hero chip count; it resets the pot to the configured blinds for the next hand.
- Right-clicking the floating `Table State` overlay now exposes a `New Hand` shortcut as well, so the state reset is available without returning to the main form.
- `Set Heroes ROI` button is a one-click shortcut that picks `hero1` ROI and auto-clones to `hero2`.
- `Run Engine` starts Ollama + bridge on demand (same action on both tester variants).
- Fast testing controls:
  - `Run flop1` ... `Run river` for single-slot OCR checks (now also updates live hero/board profile state in the UI summary).
  - `Run Hero` reads only `hero1` + `hero2` in one optimized pass, with targeted full-pass retry if a hero slot is unresolved. Once both hero cards are valid, the tester warms the backends and immediately applies a local preflop heuristic (`FOLD` / `CALL` / `RAISE`) so you get hero-only advice before the flop. If the flop/board is already complete, it immediately queues the first full solve; otherwise the full engine solve still waits for the board.
  - `Run Flop (1-3)` for atomic flop capture. When all three flop cards are valid, that is the first actual solve request for the staged hand and it automatically uses the cached hero cards.
  - `Run Turn+E` and `Run River+E` for staged board capture + immediate engine handoff.
  - `Engine Profile` dropdown (`fast`/`fast_live`/`normal`) controls runtime profile sent to bridge `/solve` for each queued engine job.
  - The top status line keeps the last engine result summary while idle (for example `flop:fallback_lookup_policy 0.05s`) so very fast jobs are still visible after completion.
  - Batch stage runs keep vision warm during the pass and include one automatic retry for unresolved slots before final summary/handoff.
- Engine status is shown in the top header text (`Engine: idle|busy`) instead of changing button labels.
- Engine queue line now shows active job metadata in real time (`job id`, `stage`, `elapsed`, `max age`), and stale jobs are auto-cleaned on timeout.
- Engine queue control hardening:
  - state fingerprint dedupe skips no-change re-queues,
  - one active state version is enforced,
  - obsolete in-flight jobs are canceled/replaced when a newer state arrives.
  - queue status line now exposes lifecycle counters (`repl`, `skip`, `done`) and state context (`v`, short `hash`).
  - logical state delta gate prevents re-queue when hero/board/street state has not changed.
- Hero auto-send:
  - define `hero` ROI once (tester auto-clones to `hero2`),
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
  - `ENGINE_RUNTIME_PROFILE` (`fast`/`normal`, default `fast`)
  - `ENGINE_ENABLE_MULTI_NODE` (`0`/`1`, default `0`)
  - `ENGINE_SOLVER_TIMEOUT_SEC` (default `180`)
  - `ENGINE_JOB_MAX_AGE_SEC` (default `max(120, ENGINE_SOLVER_TIMEOUT_SEC+45)`) for stale background-job cleanup
  - `ENGINE_PRIORITY_ROUTING` (`1`/`0`, default `1`) enables stage-priority queue routing.
  - `ENGINE_PRIORITY_HOLD_SEC` (default `1.5`) keeps higher-priority active jobs from being preempted by lower-priority updates for a short hold window.
  - `BACKEND_AUTOSTART` (`1`/`0`, default `1`)
  - `OLLAMA_VISION_KEEP_ALIVE` (default `0s`; unloads vision model after each OCR call to free VRAM for solver/LLM work)
  - `POKE_OCR_PARALLEL` (`1`/`0`, default `1`) enables parallel slot OCR for staged board/hero passes.
  - `POKE_OCR_PARALLEL_MAX_WORKERS` (default `3`, range `1..8`) caps parallel slot workers.

Backend lifecycle in tester:
- On launch, tester checks Ollama + bridge endpoints and auto-starts missing services (backend windows start minimized).
- On close/restart, tester stops only the backend processes it started in that session.
- Vision model lifecycle:
  - tester sends vision calls with configurable Ollama `keep_alive` (default `0s`),
  - tester also sends an explicit unload request for the vision model during close/restart.

Queue stress verification helper:

```powershell
.\scripts\analyze_ui_queue_log.ps1 -UseLatest
```

This summarizes queue lifecycle events from `session_*.jsonl`:
- queued / started / completed / failed / timeout
- replaced / skip_nochange (hash + logical) / skip_priority
- success rate and skip/replace rates

Headless rapid-stage backend stress helper:

```powershell
.\scripts\test_rapid_stage_sequence.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast
```

This queues a synthetic rapid sequence (`flop` -> `turn` -> `river`) against the bridge with a short stagger and writes a timing report under `4_LLM_Bridge/examples/synthetic_hands/`.

Passive-villain stateful backend harness (no OCR / no UI, structured JSON street progression):

```powershell
.\scripts\test_stateful_sim.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile normal
.\scripts\test_stateful_sim.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast_live
.\scripts\test_stateful_sim.ps1 -Preset local_qwen3_coder_30b -RuntimeProfile fast_live -Aggressive
```

- Default run is now `30` hands (not `100`) so the reference benchmark stays usable while `normal` is still expensive.
- Default run is now `20` hands so the reference benchmark stays inside the current 10–25 hand target while `normal` remains expensive.
- The harness acts as a simple heads-up referee:
  - hero and villain each get hole cards,
  - passive mode: villain checks when checked to and auto-calls any hero bet,
  - aggressive mode (`-Aggressive`): hero is forced OOP for that test path, then villain bets with the first configured bet size for the active runtime profile after hero checks, and still auto-calls any raise,
  - hero gets one decision on flop / turn / river,
  - showdown winner and net bb are recorded.
- In `-Aggressive` mode, each street record now preserves the full solver node mix in `hands[].streets[].action_map`, and the simulated hero action is chosen by weighted sampling from the returned node frequencies instead of always taking the single highest-frequency branch.
- It now makes the full simplified `shark_cli` spot contract explicit for every decision:
  - structural dealt `hero_range` hand class (`44`, `AKs`, `AKo`) for solver compatibility,
  - fixed `villain_range`,
  - board by street,
  - in-position flag,
  - starting pot / stack,
  - minimum bet,
  - all-in threshold,
  - iterations / thread count,
  - raise cap,
  - donk-bet removal,
  - strategy compression,
  - fixed bet sizing tree.
- In aggressive mode, the harness now sends `active_node_path`, preserves donk-bet branches and caller bet sizing for that test path, and the bridge prefers `active_node_actions` over `root_actions` when the solver finds the requested node.
- It writes a JSON report under `4_LLM_Bridge/examples/synthetic_hands/` with:
  - top-level `scenario` block (full harness assumptions),
  - per-hand street actions,
  - per-street solve spot snapshots,
  - per-street latency,
  - actual bridge `selected_strategy` usage (for example `baseline_gto` vs `fallback_lookup_policy`),
  - all-in counts / street distribution,
  - aggregate `bb_100` in this simplified environment.
- Bet application inside the harness now enforces the configured `minimum_bet`, so small-pot 33% probes no longer create illegal 1bb bets.
- This is the current no-vision benchmark for validating backend decision flow before returning to OCR/live integration.

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
