# Local Neural Pipeline (Train-Our-Own)

This workspace is the canonical place for building a local neural policy/value path
from our own solver labels. It is separate from legacy DyypHoldem assets so we can
iterate cleanly without mixing generated artifacts into source code.

## Goals

- Train a lightweight neural model from our own bridge/solver outputs.
- Keep generated datasets, checkpoints, exports, and reports organized.
- Preserve a clean Git history by excluding local artifacts.

## Layout

- `configs/`: training/eval config templates.
- `data/raw_spots/`: raw labeled spot rows (teacher labels from solver).
- `data/processed/`: feature-ready datasets.
- `artifacts/checkpoints/`: training checkpoints (`.pt`, `.ckpt`, etc.).
- `artifacts/exports/`: runtime exports (TorchScript/ONNX/etc.).
- `reports/`: evaluation outputs (agreement, latency, error clusters).
- `tensorboard/`: local TensorBoard logs.

## Bootstrap

Run:

```powershell
python .\scripts\setup_local_neural_workspace.py
```

This creates the folder layout and writes starter local configs (if missing):
- `2_Neural_Brain/local_pipeline/configs/train_config.local.json`
- `2_Neural_Brain/local_pipeline/configs/dataset_config.local.json`
- `2_Neural_Brain/local_pipeline/configs/eval_gates.local.json`

## Core Scripts

0. Collect mixed training artifacts with mixed geometry + villain profiles:

```powershell
python .\scripts\setup_local_neural_workspace.py
.\scripts\run_neural_collection_recipe.ps1 -RecipePreset mixed_geometry_v1 -TotalHands 500 -RuntimeProfile fast_live
```

Run the pre-training quality gate (guard-hit band + bucket diversity):

```powershell
python .\scripts\quality_gate_flop_distribution.py --strict
```

1. Analyze/build dataset rows (analysis-only by default):

```powershell
python .\scripts\build_neural_dataset.py
```

Write JSONL rows only when explicitly requested:

```powershell
python .\scripts\build_neural_dataset.py --write
```

2. Run strict dataset validation + class-balance report:

```powershell
python .\scripts\validate_neural_dataset.py --strict
```

3. Validate training readiness (no training by default):

```powershell
python .\scripts\train_local_neural.py
```

4. Run training only when explicitly requested:

```powershell
python .\scripts\train_local_neural.py --train
```

5. Evaluate shadow report against promotion gates:

```powershell
python .\scripts\eval_local_neural_shadow.py
```

6. Offline reference labeling (checkpoint + resume + retry):

```powershell
python .\scripts\label_reference_offline.py `
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

Resume a stopped run:

```powershell
python .\scripts\label_reference_offline.py --resume
```

Watchdog guard for stalled runs (stale-write SLA + safe tail repair + relaunch):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\watch_offline_labeler_guard.ps1 `
  -ProcessId 45068 `
  -StaleMinutes 10
```

7. Post-pass validation (streaming):
   - normalized bucket fail rates (`failed / attempted`)
   - integrity checks on `reference.root_actions`:
     - finite frequencies in `[0,1]`
     - probability sum tolerance `abs(sum-1.0) < 1e-5`
     - selected decision action (when present) exists in distribution

```powershell
python .\scripts\report_reference_label_postpass.py `
  --input-jsonl .\logs\neural_pilot_merged_20260303_3x500\reports\solver_teacher_rows.merged3x500.jsonl `
  --labels-jsonl .\2_Neural_Brain\local_pipeline\data\raw_spots\solver_reference_labels.jsonl `
  --errors-jsonl .\2_Neural_Brain\local_pipeline\reports\offline_label_errors.jsonl `
  --manifest-json .\2_Neural_Brain\local_pipeline\reports\offline_label_manifest.json `
  --report-json .\2_Neural_Brain\local_pipeline\reports\reference_label_postpass_report.json `
  --unresolved-gate-json .\2_Neural_Brain\local_pipeline\reports\unresolved_gate_ids.json `
  --integrity-tol 1e-5 `
  --strict
```

8. Runtime unresolved gate (deterministic skip of unresolved geometries for neural calls):

```powershell
$env:NEURAL_BRAIN_ENABLED = "1"
$env:NEURAL_BRAIN_MODE = "shadow"
$env:NEURAL_UNRESOLVED_GATE_ENABLED = "1"
$env:NEURAL_UNRESOLVED_COARSE_GATE_ENABLED = "0"   # optional tier-2 adjacency gate
$env:NEURAL_UNRESOLVED_GATE_JSON = "A:\PokeHerFace\Version1\2_Neural_Brain\local_pipeline\reports\unresolved_gate_ids.json"
```

Notes:
- This is a deterministic gate keyed by geometry bucket ID, not confidence.
- If a spot is unresolved, bridge logs/metrics expose `neural_unresolved_gate_hit=true` and skips neural inference for that spot.
- Export now includes both `unresolved_gate_ids` (exact) and `unresolved_coarse_gate_ids` (texture/SPR/facing buckets).

## Default Safety Locks

- Dataset template defaults are postflop-only with production profiles (`fast_live`, `normal`).
- Dataset template excludes neural-applied and surrogate rows unless explicitly enabled.
- Training template uses deterministic split by `split_key` (`split_method=hash_split_key`) to keep train/val partitions stable across reruns.

## Phase Plan

1. Build labeled dataset from bridge artifacts (teacher = solver/fallback policy).
2. Train imitation baseline model in PyTorch.
3. Run shadow evaluation against live solver decisions.
4. Define promotion gates (agreement + latency + disagreement review).
5. Enable controlled prefer mode only after gates pass.
