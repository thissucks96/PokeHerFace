# PokeHerFace Version1

Heads-up poker engine workspace:
- C++ solver core (`shark_cli`)
- Python bridge/router
- WinForms tester UI
- Optional neural shadow path

## Current Status

- App is functional for heads-up game-loop testing.
- Live-safe profile is `fast_live`.
- `normal` profile is stronger in some spots but can stall on high-complexity nodes.
- OCR/screen capture is currently optional and can be disabled for manual-state testing.
- Neural path is available, but default use is shadow/controlled promotion.
- Bridge enforces a full `spot` contract before solve (all major Shark fields required).
- Live payloads now set dynamic `in_position_player` and always include `active_node_path`.
- Active-node facing-bet requests now canonicalize bet amount to nearest legal tree size.

## Developer Handoff

Read these first before significant implementation work:
- `AGENT.MD`
- `HANDOFF_NEW_DEVELOPER.md`
- `History.MD` (shared memory across chats, if populated)

Full transfer-of-ownership reference:
- `HANDOFF_NEW_DEVELOPER.md`

User-facing launchers:
- `USER_ONLY/README.txt`
- `USER_ONLY/01_run_broad_tail_away.ps1`

## Project Layout

- `1_Engine_Core/` C++ solver (`shark_cli.exe`, GUI sources)
- `2_Neural_Brain/` neural research/inference workspace
- `3_Hand_Histories/` hand-history data
- `4_LLM_Bridge/` bridge server, routing, datasets, sim harnesses
- `5_Vision_Extraction/` tester runtime artifacts and capture flows
- `scripts/` PowerShell automation and test runners

## Quick Start (Windows)

From repo root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\setup_windows.ps1
```

Use the repo venv Python for local scripts unless there is a clear reason not to:

```powershell
.\.venv\Scripts\python.exe
```

Run preflight:

```powershell
.\scripts\preflight_windows.ps1
```

## Main Test Commands

Stateful synthetic sim:

```powershell
.\scripts\test_stateful_sim.ps1 -Hands 50 -RuntimeProfile fast_live -VillainMode engine_random
.\scripts\test_stateful_sim.ps1 -Hands 50 -RuntimeProfile fast_live -VillainMode scripted_aggressive
```

Neural dataset pilot (mixed geometry + quality gate):

```powershell
.\scripts\run_neural_collection_recipe.ps1 -RecipePreset mixed_geometry_v1 -TotalHands 500 -RuntimeProfile fast_live
.\.venv\Scripts\python.exe .\scripts\quality_gate_flop_distribution.py --strict
.\.venv\Scripts\python.exe .\scripts\build_neural_dataset.py --response-dir 5_Vision_Extraction\out\flop_engine --write
```

Feature-contract parity check (offline rows vs live-spot encoding):

```powershell
.\.venv\Scripts\python.exe .\scripts\test_feature_contract_parity.py `
  --input-jsonl .\2_Neural_Brain\local_pipeline\data\raw_spots\solver_teacher_rows.jsonl `
  --strict
```

Offline reference labeling (checkpoint/resume):

```powershell
.\.venv\Scripts\python.exe .\scripts\label_reference_offline.py `
  --input-jsonl .\logs\neural_pilot_merged_20260303_3x500\reports\solver_teacher_rows.merged3x500.jsonl `
  --output-jsonl .\2_Neural_Brain\local_pipeline\data\raw_spots\solver_reference_labels.jsonl `
  --error-jsonl .\2_Neural_Brain\local_pipeline\reports\offline_label_errors.jsonl `
  --manifest-json .\2_Neural_Brain\local_pipeline\reports\offline_label_manifest.json `
  --runtime-profile shark_classic `
  --timeout-sec 180 `
  --max-retries 2 `
  --checkpoint-every 25 `
  --resume
```

Offline labeler watchdog (10-minute stale-write SLA + safe JSONL tail repair + resume relaunch):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\watch_offline_labeler_guard.ps1 `
  -ProcessId 45068 `
  -StaleMinutes 10
```

Note: the guard auto-applies a minimum quiet window derived from labeler `--timeout-sec` and `--max-retries` to avoid false restarts during legitimate long rows.

Leave-the-PC broad-tail runbook (bridge + resume + watchdog + visible progress):

```powershell
.\USER_ONLY\01_run_broad_tail_away.ps1
.\USER_ONLY\01_run_broad_tail_away.ps1 -RestartExisting
```

This is the best unattended run for the repository right now because dataset freeze is still the primary blocker. The launcher:
- checks or starts the bridge
- resumes the broad-tail `shark_classic` labeler
- replaces stale watchdogs automatically
- opens one visible progress tail and one visible error tail
- hides backend bridge/labeler/watchdog consoles

Post-pass unresolved gate export (for deterministic neural OOD blocking):

```powershell
$bucket = "flop|p_lt10|f_0|spr_16p"
.\.venv\Scripts\python.exe .\scripts\report_reference_label_postpass.py `
  --input-jsonl .\logs\neural_pilot_merged_20260303_3x500\reports\solver_teacher_rows.merged3x500.jsonl `
  --labels-jsonl .\2_Neural_Brain\local_pipeline\data\raw_spots\solver_reference_labels.jsonl `
  --errors-jsonl .\2_Neural_Brain\local_pipeline\reports\offline_label_errors.jsonl `
  --manifest-json .\2_Neural_Brain\local_pipeline\reports\offline_label_manifest.json `
  --report-json .\2_Neural_Brain\local_pipeline\reports\reference_label_postpass_report.json `
  --unresolved-gate-json .\2_Neural_Brain\local_pipeline\reports\unresolved_gate_ids.json `
  --accepted-systemic-bucket-id $bucket `
  --strict
```

For this repository's current known hard-OOD boundary, `flop|p_lt10|f_0|spr_16p` is treated as a documented unresolved region rather than a silent gap. Strict post-pass counts those rows as `accepted_ood_missing_rows`, exports their unresolved gate IDs, and keeps `fast_live` fallback authoritative there.

Bridge runtime deterministic unresolved gate (local-only, no cloud dependency):

```powershell
$env:NEURAL_BRAIN_ENABLED = "1"
$env:NEURAL_BRAIN_MODE = "shadow"
$env:NEURAL_BRAIN_POLICY_CHECKPOINT_PATH = "A:\PokeHerFace\Version1\2_Neural_Brain\local_pipeline\artifacts\checkpoints\neural_policy_shadow_v1.pt"
$env:NEURAL_UNRESOLVED_GATE_ENABLED = "1"
$env:NEURAL_UNRESOLVED_COARSE_GATE_ENABLED = "0"   # optional tier-2 adjacency gate
$env:NEURAL_UNRESOLVED_GATE_JSON = "A:\PokeHerFace\Version1\2_Neural_Brain\local_pipeline\reports\unresolved_gate_ids.json"
```

The neural adapter now tries the local checkpoint path first for shadow/prefer decisions and only falls back to the older adapter path if that checkpoint is missing or unusable. The bridge `/health` output includes `neural_brain_policy_checkpoint_path` so you can confirm which shadow checkpoint is configured.

Direct reproducible A/B (same seed):

```powershell
.\.venv\Scripts\python.exe 4_LLM_Bridge\run_stateful_sim.py --hands 25 --runtime-profile fast_live --seed 4090 --output 4_LLM_Bridge\examples\synthetic_hands\ab_fast_live_seed4090.json
.\.venv\Scripts\python.exe 4_LLM_Bridge\run_stateful_sim.py --hands 25 --runtime-profile shark_classic --timeout-shark-classic 180 --seed 4090 --output 4_LLM_Bridge\examples\synthetic_hands\ab_shark_classic_seed4090.json
.\.venv\Scripts\python.exe 4_LLM_Bridge\run_stateful_sim.py --hands 25 --runtime-profile shark_classic --shark-classic-reference --seed 4090 --output 4_LLM_Bridge\examples\synthetic_hands\ab_shark_classic_reference_seed4090.json
```

Fast-live tuning sweep (tracks latency deltas vs baseline):

```powershell
.\scripts\run_fast_live_tuning_sweep.ps1 -Hands 8 -VillainMode scripted_aggressive
```

Outputs:
- Per-config report JSON files in `4_LLM_Bridge\examples\synthetic_hands\fast_live_tuning\`
- Sweep summary JSON + CSV with:
  - `bb_100` delta vs baseline
  - flop/turn/river latency deltas vs baseline

Acceptance:

```powershell
.\scripts\test_acceptance.ps1 -Suite turn_class1 -Preset local_qwen3_coder_30b
.\scripts\test_acceptance.ps1 -Suite river_class23 -Preset local_qwen3_coder_30b
```

UI tester:

```powershell
.\tesseract_test.ps1
```

UI hand export:
- Use `Copy Hand Snapshot` (right panel) or right-click `Table State` overlay -> `Copy Hand Snapshot`.
- Snapshot includes current state (cards/board/pot/commits/status/advice) plus current hand log lines.

Manual vs 1v1 dataset capture:
- Manual play against the built-in 1v1 engine now writes structured session data to `5_Vision_Extraction\out\manual_training\manual_vs_1v1_<session>.jsonl`.
- Records include hand starts, engine results, hero actions, villain actions, and hand outcomes so the session can be converted into future neural training data without scraping human-readable logs.

## Runtime Profiles

- `fast_live`: production candidate (bounded latency + stronger spot tuning)
- `normal`: full-latency path for offline quality reference
- `normal_neural`: placeholder profile for neural teaching/data collection (normal-like solve path, separately tagged)
- `shark_classic`: Shark-original contract profile (flop 50/100 + raise 100; turn/river 33/66/100 + raise 50/100, donk-check forced, all-in threshold 0.67, raise cap 3)

`fast_live` now supports a baseline race mode:
- runs `normal` and `fast_live` baseline solves in parallel
- uses the first successful result (with explicit priority when `normal` wins)
- only on configured streets (`FAST_LIVE_NORMAL_RACE_STREETS`, default `turn,river`)
- capped by `FAST_LIVE_NORMAL_RACE_TIMEOUT_SEC` (default `10`)

`fast_live` active-node sizing now keeps a small subset (not only one size) on the active street:
- `FAST_LIVE_ACTIVE_STREET_BET_KEEP` (default `2`)
- `FAST_LIVE_ACTIVE_STREET_RAISE_KEEP` (default `2`)
- `FAST_LIVE_PRESERVE_DONK_TREE_ON_ACTIVE_NODE` (default `0`; keep off for lower flop latency)
- pre-solver flop fast-fail complexity guard (skips only high-SPR/wide-range/high-timeout-risk flop spots):
  - `FAST_LIVE_FLOP_COMPLEXITY_GUARD_ENABLED` (default `1`)
  - `FAST_LIVE_FLOP_COMPLEXITY_GUARD_ALLOW_ACTIVE_NODE` (default `0`)
  - `FAST_LIVE_FLOP_GUARD_MIN_STACK_BB` (default `80`)
  - `FAST_LIVE_FLOP_GUARD_MIN_SPR` (default `10.0`)
  - `FAST_LIVE_FLOP_GUARD_MIN_VILLAIN_RANGE_WIDTH` (default `20`)
  - `FAST_LIVE_FLOP_GUARD_MAX_FACING_RATIO` (default `0.25`)
  - `FAST_LIVE_FLOP_GUARD_MAX_BASELINE_TIMEOUT_SEC` (default `10`)
- global flop reduction (applies on all `fast_live` flop spots before active-node overrides):
  - `FAST_LIVE_FLOP_FORCE_REDUCTION` (default `1`)
  - `FAST_LIVE_FLOP_REDUCTION_BET_SIZES` (default `0.5,1.0`)
  - `FAST_LIVE_FLOP_REDUCTION_RAISE_SIZES` (default `1.0`)
  - `FAST_LIVE_FLOP_MAX_ITERATIONS` (default `2`)
  - `FAST_LIVE_FLOP_MAX_RAISE_CAP` (default `3`)
- targeted active-node flop reduction (applies only on flop facing-bet nodes):
  - `FAST_LIVE_ACTIVE_NODE_FLOP_FORCE_REDUCTION` (default `1`)
  - `FAST_LIVE_ACTIVE_NODE_FLOP_BET_SIZES` (default `0.5,1.0`)
  - `FAST_LIVE_ACTIVE_NODE_FLOP_RAISE_SIZES` (default `1.0`)
  - `FAST_LIVE_ACTIVE_NODE_FLOP_MAX_ITERATIONS` (default `2`)
  - `FAST_LIVE_ACTIVE_NODE_FLOP_MAX_RAISE_CAP` (default `3`)
- baseline-path river tree controls (non-fallback tuning lever):
  - `FAST_LIVE_RIVER_BET_SIZES` (default empty -> inherits `FAST_LIVE_SPOT_BET_SIZES`)
  - `FAST_LIVE_RIVER_RAISE_SIZES` (default empty -> inherits `FAST_LIVE_SPOT_RAISE_SIZES`)

`fast_live` failover now exposes multiple sized fallback actions (instead of only min-size), then applies a targeted flop c-bet bias in known disagreement buckets:
- `FAST_FAILOVER_MAX_SIZED_ACTIONS` (default `3`)
- `FAST_LIVE_FLOP_CBET75_BIAS_ENABLED` (default `1`)
- `FAST_LIVE_FLOP_CBET75_POT_MIN` / `FAST_LIVE_FLOP_CBET75_POT_MAX` (defaults `10` / `20`)
- `FAST_LIVE_FLOP_CBET75_TARGET_RATIO` (default `0.75`)
- `FAST_LIVE_FLOP_CBET75_MIN_BET_RATIO` / `FAST_LIVE_FLOP_CBET75_MAX_BET_RATIO` (defaults `0.60` / `0.90`)
- `FAST_LIVE_FLOP_CBET75_BOARD_CLASSES` (default `two-tone|disconnected,rainbow|disconnected,rainbow|connected`)
- weighted mix for targeted flop fallback buckets:
  - `FAST_LIVE_FLOP_CBET_MIX_WEIGHT_BET75` (default `0.70`)
  - `FAST_LIVE_FLOP_CBET_MIX_WEIGHT_BET33` (default `0.20`)
  - `FAST_LIVE_FLOP_CBET_MIX_WEIGHT_CHECK` (default `0.10`)
- fallback telemetry level:
  - `FAST_LIVE_TELEMETRY_LEVEL` (`lean|full`, default `lean`)
- scoped river fallback override (single high-drift bucket tuning):
  - `FAST_LIVE_RIVER_SMALL_FACE_OVERRIDE_ENABLED` (default `1`)
  - `FAST_LIVE_RIVER_SMALL_FACE_POT_MIN_BB` / `FAST_LIVE_RIVER_SMALL_FACE_POT_MAX_BB` (defaults `20` / `40`)
  - `FAST_LIVE_RIVER_SMALL_FACE_MAX_RATIO` (default `0.33`)
  - `FAST_LIVE_RIVER_SMALL_FACE_BOARD_CLASSES` (default `rainbow|unpaired|disconnected`)
  - `FAST_LIVE_RIVER_SMALL_FACE_WEIGHT_ALLIN` / `FAST_LIVE_RIVER_SMALL_FACE_WEIGHT_CALL` / `FAST_LIVE_RIVER_SMALL_FACE_WEIGHT_FOLD` (defaults `0.70` / `0.30` / `0.00`)
- scoped fast_live baseline override (single matched turn/river bucket; weighted, legal-action-safe):
  - `FAST_LIVE_TARGET_BUCKET_OVERRIDE_ENABLED` (default `1`)
  - `FAST_LIVE_TARGET_BUCKET_OVERRIDE_STREET` (`turn|river`, default `river`)
  - `FAST_LIVE_TARGET_BUCKET_OVERRIDE_POT_MIN_BB` / `FAST_LIVE_TARGET_BUCKET_OVERRIDE_POT_MAX_BB` (defaults `20` / `40`)
  - `FAST_LIVE_TARGET_BUCKET_OVERRIDE_MAX_RATIO` (default `0.33`)
  - `FAST_LIVE_TARGET_BUCKET_OVERRIDE_BOARD_CLASSES` (default `rainbow|unpaired|disconnected`)
  - `FAST_LIVE_TARGET_BUCKET_OVERRIDE_WEIGHT_ALLIN` / `FAST_LIVE_TARGET_BUCKET_OVERRIDE_WEIGHT_CALL` / `FAST_LIVE_TARGET_BUCKET_OVERRIDE_WEIGHT_FOLD` (defaults `0.80` / `0.15` / `0.05`)
- fallback telemetry now includes:
  - `metrics.fast_live_fallback_bucket_id`
  - `metrics.fast_live_flop_cbet_mix_applied`
  - `metrics.fast_live_river_small_face_override_applied`
  - `metrics.fast_live_target_bucket_override_applied`
  - `metrics.fast_live_target_bucket_override_bucket_id`
  - `metrics.fast_live_target_bucket_override_selected_action`
  - `metrics.fast_live_fallback_select_time_ms`
  - `metrics.fast_live_fallback_meta` (only populated in `full`)

`normal` no longer silently auto-overrides to `fast_live` postflop unless explicitly enabled:
- `ENGINE_ALLOW_NORMAL_POSTFLOP_OVERRIDE=1`

`fast` is deprecated and aliases to `fast_live`.

## Neural Mode

Bridge supports:
- `shadow`
- `prefer`
- `prefer_on_fast_failover`

Use shadow first for validation; promote only after agreement/latency gates are met.
Do not treat neural prefer-mode as ready until dataset freeze and evaluation gates pass cleanly.

## Important Notes

- Core `shark_cli` solve path is CPU multithreaded today.
- GPU usage is mostly from local LLM/neural inference paths.
- Large generated outputs are ignored by `.gitignore` (reports/log artifacts).
- Contract regression check (bridge online):

```powershell
.\.venv\Scripts\python.exe scripts\test_profile_contract.py --endpoint http://127.0.0.1:8000/solve
```

- Stateful sim reports are now `stateful_sim_report.v3` and include:
  - profile-aware timeout metadata (`timeout_sec_default`, `timeout_sec_effective`)
  - aggregated error classes (`error_counts`, `error_counts_by_street`, `hands_with_error`)
  - fallback split metrics (`fallback_count_by_street`, `fallback_rate_by_street`, `strategy_sources_by_street`)
- When `--artifact-dir` is provided, stateful sim now writes payload/response artifacts for both successful solves and failed calls (timeout/HTTP errors), so failure forensics are preserved.
- `run_stateful_sim.py` now supports:
  - `--shark-classic-reference`: constrained Shark-contract reference setup (smaller stack/range for reliable fidelity runs)
  - `--villain-range`: explicit range-width control for dataset generation recipes
  - early `complexity_guard_skip` labeling for high-complexity non-reference `shark_classic` flop spots (can be disabled with `--disable-complexity-guard`)
- Bridge now has an optional shark-classic complexity guard for direct `/solve` calls:
  - `SHARK_CLASSIC_COMPLEXITY_GUARD_ENABLED=1` (default on)
  - `SHARK_CLASSIC_GUARD_MIN_STACK=80`
  - `SHARK_CLASSIC_GUARD_MIN_VILLAIN_RANGE_WIDTH=20`
  - `SHARK_CLASSIC_GUARD_MAX_TIMEOUT_SEC=180`

## Next Best Steps

1. Complete the offline reference corpus until strict post-pass can report a true `freeze_ready=true` state with clean manifest sync.
2. Re-run strict post-pass and unresolved-gate export after meaningful label/reference checkpoints.
3. Point train/eval to frozen reference labels and run baseline local eval only after freeze gates pass.
4. Keep neural in shadow or other non-authoritative modes until freeze and eval gates are satisfied; continue `fast_live` tuning separately.
