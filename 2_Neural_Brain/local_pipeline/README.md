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

1. Analyze/build dataset rows (analysis-only by default):

```powershell
python .\scripts\build_neural_dataset.py
```

Write JSONL rows only when explicitly requested:

```powershell
python .\scripts\build_neural_dataset.py --write
```

2. Validate training readiness (no training by default):

```powershell
python .\scripts\train_local_neural.py
```

Run training only when explicitly requested:

```powershell
python .\scripts\train_local_neural.py --train
```

3. Evaluate shadow report against promotion gates:

```powershell
python .\scripts\eval_local_neural_shadow.py
```

## Phase Plan

1. Build labeled dataset from bridge artifacts (teacher = solver/fallback policy).
2. Train imitation baseline model in PyTorch.
3. Run shadow evaluation against live solver decisions.
4. Define promotion gates (agreement + latency + disagreement review).
5. Enable controlled prefer mode only after gates pass.
