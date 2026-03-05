# Neural Shadow Evaluation Contract (v1)

This file defines the promotion contract for moving a local neural shadow from
data-collection/shadow mode toward production preference logic.

The goal is to eliminate subjective promotion decisions and prevent
infrastructure drift from being misread as model quality.

## Scope

- Heads-up pipeline only (current project phase).
- Applies after offline reference labeling and before any prefer-mode rollout.
- Uses local workflows only by default.

## Hard Gates (Must Pass)

1) Data Integrity
- `freeze_ready == true` from strict post-pass report.
- Manifest sync has zero mismatch reasons.
- Integrity failures are zero:
  - invalid JSON rows
  - distribution sum failures
  - selected-action-not-in-distribution failures

2) Reliability
- No illegal action outputs in evaluation runs.
- No inference crashes.
- Runtime unresolved gate behavior is deterministic:
  - unresolved spot => neural skipped => fallback path used.

3) Latency
- End-to-end decision latency targets:
  - `p50 <= 1.5s`
  - `p95 <= 5.0s`
  - `p99 <= 10.0s`
- Feature extraction overhead target:
  - `p99 <= 1.0ms` in bridge hot path.

4) Strategy Value
- Against current fast_live baseline on holdout:
  - `bb/100 delta >= +5`
  - or `>= 0` only when accompanied by materially lower risk/fallback regression.
- Bucket-level disagreement should improve in high-frequency buckets (not only rare outliers).

## Holdout Air-Gap Requirements

Train/eval leakage is disallowed.

Required checks:
- No `row_id` overlap between train and holdout.
- No `feature_key_hash` overlap between train and holdout where hashes exist.
- If feature hash is missing in a row, treat as warning and remediate before promotion.

Use:

```powershell
python .\scripts\check_neural_data_airgap.py `
  --train-jsonl .\2_Neural_Brain\local_pipeline\data\raw_spots\solver_reference_labels.train.jsonl `
  --holdout-jsonl .\2_Neural_Brain\local_pipeline\data\raw_spots\solver_reference_labels.holdout.jsonl `
  --strict
```

## Timebox Policy

To avoid infrastructural quicksand:
- Do not add new pipeline features until one baseline train+eval pass completes.
- If gates fail, fix blockers with highest EV/latency impact first.
- Re-run on unseen holdout seeds before any promotion decision.

## Promotion Decision

Promote only when all hard gates pass.

If any hard gate fails:
- remain in shadow mode,
- keep fallback path authoritative,
- remediate and re-evaluate.

