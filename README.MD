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

Acceptance:

```powershell
.\scripts\test_acceptance.ps1 -Suite turn_class1 -Preset local_qwen3_coder_30b
.\scripts\test_acceptance.ps1 -Suite river_class23 -Preset local_qwen3_coder_30b
```

UI tester:

```powershell
.\tesseract_test.ps1
```

## Runtime Profiles

- `fast`: low-latency compact solve path
- `fast_live`: production candidate (bounded latency + stronger spot tuning)
- `normal`: full-latency path for offline quality reference

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

## Next Best Steps

1. Continue tuning `fast_live` for better non-root postflop decisions.
2. Run side-by-side `fast_live` vs `normal` with fair timeout budgets for quality comparison.
3. Expand neural shadow evaluation and promote selectively where safe.
4. Revisit GPU offload for solver hot loops after CPU/routing refinement plateaus.

