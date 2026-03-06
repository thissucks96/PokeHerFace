### Last Updated: 2026-03-06 11:03 America/Los_Angeles

### Current Situation
The repository is focused on completing the offline reference corpus to achieve a true `freeze_ready=true` state before starting a baseline neural train/eval pass. The core heads-up poker app is fully playable and stable using the `fast_live` profile, while the neural pipeline remains correctly gated. The overnight `shark_classic` reference pass has been stopped and measured; it produced material corpus progress, but freeze remains blocked by a large unresolved tail plus one systemic timeout-heavy flop bucket.

**Done when:** strict post-pass reports `freeze_ready=true` and train/eval is pointed at frozen reference labels.

### Verified Facts
- Core app is functional and playable (`fast_live`).
- The overnight run is complete and the labeler has been stopped for a stable morning snapshot.
- Labeler resume accounting has been fixed locally (`scripts/label_reference_offline.py`).
- The watchdog script has been patched to handle fresh-run startups correctly (`scripts/watch_offline_labeler_guard.ps1`).
- `scripts/train_local_neural.py:227` defaults to `solver_teacher_rows.jsonl`, which is not aligned with the target freeze pipeline.
- Morning strict post-pass results:
  - `labels_unique = 1453`
  - `errors_unique = 45`
  - `missing_rows = 4309`
  - `first_missing_index = 1498`
  - `freeze_ready = false`

### Blocker Chain
- **Blocker:** Baseline neural train/eval cannot proceed because the required frozen corpus artifact (`solver_reference_labels.jsonl`) is not complete or validated.
- **Relevant Artifacts:**
  - `2_Neural_Brain/local_pipeline/reports/offline_label_manifest.json`
  - `2_Neural_Brain/local_pipeline/reports/reference_label_postpass_report.json`
  - `2_Neural_Brain/local_pipeline/reports/offline_label_errors.jsonl`
- **Cause:** The offline labeler is still processing remaining unresolved hands, which are currently dominated by 300-second solver timeouts.
- **Current Progress:**
  - pre-run checkpoint:
    - `labels_unique = 1329`
    - `errors_unique = 19`
    - `missing_rows = 4459`
  - morning snapshot:
    - `labels_unique = 1453`
    - `errors_unique = 45`
    - `missing_rows = 4309`
    - `first_missing_index = 1498`
  - overnight delta:
    - `+124` successful labels
    - `+26` explicit errors
    - `-150` missing rows
- **Impact:** `freeze_ready` remains false, preventing the safe and trustworthy evaluation of a shadow neural model.

### Morning Result
- The overnight run generated real value as corpus progress, not as a freeze unlock.
- Strict post-pass is still failing for:
  - `missing_rows=4309`
  - `systemic_buckets=1`
- Manifest/output mismatches have been reconciled from output truth and are no longer part of the active strict-failure reasons.
- The remaining quality hotspot is still concentrated in the flop bucket:
  - `flop|p_lt10|f_0|spr_16p`
  - `attempted = 104`
  - `succeeded = 59`
  - `failed = 45`
  - `fail_rate_attempted = 0.432692`

### Open Questions
- Will the remaining unresolved row segment produce any successful labels, or are they entirely timeout-bound edge cases?
- Is there an expectation to eventually recover strategic value from these timeout-heavy nodes by explicitly tweaking the reference solver runtime, or is deterministic explicit failure acceptable for corpus completion?

### Overnight Run Plan
- Launch the bridge with `.\.venv\Scripts\python.exe`.
- Verify `http://127.0.0.1:8000/health` before leaving the host unattended.
- Resume `scripts\label_reference_offline.py` with the existing `shark_classic` reference settings and watchdog supervision.
- In the morning, run strict `scripts\report_reference_label_postpass.py` unchanged.
- Compare the resulting `missing_rows` and `errors_unique` values against the current checkpoint:
  - `missing_rows = 4459`
  - `errors_unique = 19`

### Recommended Next Checks
1. Decide whether the systemic `flop|p_lt10|f_0|spr_16p` timeout bucket should be accepted as explicit failure coverage or attacked with a different reference-runtime strategy.
2. When needed, run `scripts\reconcile_offline_label_manifest.py` before strict post-pass so manifest stats match output truth after interrupted labeler runs.
3. Investigate the downstream train/eval workflow to ensure the default target in `scripts/train_local_neural.py` is re-wired to point to the newly frozen reference corpus instead of the deprecated `solver_teacher_rows.jsonl` file.
