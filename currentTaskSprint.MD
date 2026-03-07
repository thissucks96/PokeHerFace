### Last Updated: 2026-03-07 14:20 America/Los_Angeles

### Current Situation
The broad-tail reference-label pass is complete. The offline reference corpus now reaches a strict stopped-state `freeze_ready=true` verdict when the known hard-OOD hotspot bucket is designated explicitly in strict post-pass. The core heads-up poker app remains playable and stable on `fast_live`, and neural is still gated pending the next baseline train/eval steps.

**Done when:** one baseline train/eval cycle completes against the frozen reference corpus, with the documented hard-OOD hotspot exported to the unresolved neural gate and the trainer pointed at frozen reference labels instead of teacher rows.

### Verified Facts
- Core app is functional and playable (`fast_live`).
- Broad-tail `shark_classic` pass completed cleanly:
  - `attempted = 3663`
  - `succeeded = 3663`
  - `failed = 0`
  - `stopped_reason = completed`
- Global strict stopped-state corpus numbers are now:
  - `labels_unique = 5116`
  - `errors_unique = 45`
  - `accepted_ood_missing_rows = 646`
  - `missing_rows = 0`
  - `freeze_ready = true`
- The remaining unresolved region is explicitly isolated to:
  - `flop|p_lt10|f_0|spr_16p`
  - `accepted_ood_missing = 646`
  - `attempted = 104`
  - `succeeded = 59`
  - `failed = 45`
  - `severity = accepted_ood_systemic`
- `scripts/train_local_neural.py:227` still defaults to `solver_teacher_rows.jsonl`, which is not aligned with the frozen reference path.
- The hotspot shallow-salvage pilot failed:
  - `0` labels
  - `5` explicit errors
  - all failures were `120s` `shark_cli` timeouts

### Blocker Chain
- **Blocker:** The freeze blocker is cleared, but baseline neural training has not started yet.
- **Relevant Artifacts:**
  - `2_Neural_Brain/local_pipeline/reports/reference_label_postpass_report.json`
  - `2_Neural_Brain/local_pipeline/reports/unresolved_gate_ids.json`
  - `2_Neural_Brain/local_pipeline/reports/offline_label_manifest.json`
- **Cause:** The next work is now downstream wiring and evaluation, not corpus completion.
- **Impact:** Neural remains shadow-only until the trainer input path, data split, air-gap check, and baseline eval are completed.

### Current Read
- The broad-tail chapter is closed successfully.
- The hotspot bucket is now treated as a documented hard-OOD boundary instead of a silent gap.
- Strict post-pass now distinguishes between true missing rows and `accepted_ood_missing_rows`.
- The runtime unresolved gate export remains the safety mechanism that keeps fallback authoritative in the hotspot geometry.

### Open Questions
- Does `solver_reference_labels.jsonl` carry full solver distributions in a trainer-ready shape, or only scalar selected actions?
- Should the first trainer upgrade be a loss/objective change only, or a loader + target-shape rewrite?
- What exact train/holdout split should be used for the first baseline pass now that freeze is green?

### Recommended Next Checks
1. Inspect one real `solver_reference_labels.jsonl` row and confirm the true `target` shape.
2. Point `scripts/train_local_neural.py` at frozen reference labels instead of `solver_teacher_rows.jsonl`.
3. Generate train/holdout splits from the frozen corpus.
4. Run `scripts/check_neural_data_airgap.py --strict`.
5. Run one baseline local train/eval cycle under `2_Neural_Brain/local_pipeline/NEURAL_EVAL_CONTRACT.md`.
