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

Direct reproducible A/B (same seed):

```powershell
python 4_LLM_Bridge\run_stateful_sim.py --hands 25 --runtime-profile fast_live --seed 4090 --output 4_LLM_Bridge\examples\synthetic_hands\ab_fast_live_seed4090.json
python 4_LLM_Bridge\run_stateful_sim.py --hands 25 --runtime-profile shark_classic --timeout-shark-classic 180 --seed 4090 --output 4_LLM_Bridge\examples\synthetic_hands\ab_shark_classic_seed4090.json
python 4_LLM_Bridge\run_stateful_sim.py --hands 25 --runtime-profile shark_classic --shark-classic-reference --seed 4090 --output 4_LLM_Bridge\examples\synthetic_hands\ab_shark_classic_reference_seed4090.json
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

## Runtime Profiles

- `fast_live`: production candidate (bounded latency + stronger spot tuning)
- `normal`: full-latency path for offline quality reference
- `normal_neural`: placeholder profile for neural teaching/data collection (normal-like solve path, separately tagged)
- `shark_classic`: Shark-original contract profile (flop 50/100 + raise 100; turn/river 33/66/100 + raise 50/100, donk-check forced, all-in threshold 0.67, raise cap 3)

`fast_live` now supports a baseline race mode:
- runs `normal` and `fast_live` baseline solves in parallel
- uses the first successful result (with explicit priority when `normal` wins)
- capped by `FAST_LIVE_NORMAL_RACE_TIMEOUT_SEC` (default `10`)

`fast_live` active-node sizing now keeps a small subset (not only one size) on the active street:
- `FAST_LIVE_ACTIVE_STREET_BET_KEEP` (default `2`)
- `FAST_LIVE_ACTIVE_STREET_RAISE_KEEP` (default `2`)

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
- fallback telemetry now includes:
  - `metrics.fast_live_fallback_bucket_id`
  - `metrics.fast_live_flop_cbet_mix_applied`
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

## Important Notes

- Core `shark_cli` solve path is CPU multithreaded today.
- GPU usage is mostly from local LLM/neural inference paths.
- Large generated outputs are ignored by `.gitignore` (reports/log artifacts).
- Contract regression check (bridge online):

```powershell
python scripts\test_profile_contract.py --endpoint http://127.0.0.1:8000/solve
```

- Stateful sim reports are now `stateful_sim_report.v3` and include:
  - profile-aware timeout metadata (`timeout_sec_default`, `timeout_sec_effective`)
  - aggregated error classes (`error_counts`, `error_counts_by_street`, `hands_with_error`)
- When `--artifact-dir` is provided, stateful sim now writes payload/response artifacts for both successful solves and failed calls (timeout/HTTP errors), so failure forensics are preserved.
- `run_stateful_sim.py` now supports:
  - `--shark-classic-reference`: constrained Shark-contract reference setup (smaller stack/range for reliable fidelity runs)
  - early `complexity_guard_skip` labeling for high-complexity non-reference `shark_classic` flop spots (can be disabled with `--disable-complexity-guard`)
- Bridge now has an optional shark-classic complexity guard for direct `/solve` calls:
  - `SHARK_CLASSIC_COMPLEXITY_GUARD_ENABLED=1` (default on)
  - `SHARK_CLASSIC_GUARD_MIN_STACK=80`
  - `SHARK_CLASSIC_GUARD_MIN_VILLAIN_RANGE_WIDTH=20`
  - `SHARK_CLASSIC_GUARD_MAX_TIMEOUT_SEC=180`

## Next Best Steps

1. Continue tuning `fast_live` for better non-root postflop decisions.
2. Run side-by-side `fast_live` vs `normal` with fair timeout budgets for quality comparison.
3. Expand neural shadow evaluation and promote selectively where safe.
4. Revisit GPU offload for solver hot loops after CPU/routing refinement plateaus.
