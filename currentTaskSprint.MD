### Last Updated: 2026-03-06 22:00 America/Los_Angeles

### Current Situation
The repository is focused on completing the offline reference corpus to achieve a true `freeze_ready=true` state before starting a baseline neural train/eval pass. The core heads-up poker app is fully playable and stable using the `fast_live` profile, while the neural pipeline remains correctly gated. The broad-tail `shark_classic` reference pass is currently active against the missing-row subset that excludes the quarantined `flop|p_lt10|f_0|spr_16p` hotspot.

**Done when:** strict post-pass reports `freeze_ready=true` and train/eval is pointed at frozen reference labels.

### Verified Facts
- Core app is functional and playable (`fast_live`).
- The broad-tail labeler is currently running through the targeted missing-row subset.
- Labeler resume accounting has been fixed locally (`scripts/label_reference_offline.py`).
- The watchdog script has been patched to handle fresh-run startups correctly (`scripts/watch_offline_labeler_guard.ps1`).
- The user-facing broad-tail launcher has been added and hardened:
  - `scripts/run_broad_tail_away.ps1`
  - `USER_ONLY/01_run_broad_tail_away.ps1`
  - stale watchdogs are now replaced automatically
  - duplicate tail windows are deduped
  - backend bridge/labeler/watchdog consoles are hidden
- `scripts/train_local_neural.py:227` defaults to `solver_teacher_rows.jsonl`, which is not aligned with the target freeze pipeline.
- Last strict post-pass baseline results:
  - `labels_unique = 1453`
  - `errors_unique = 45`
  - `missing_rows = 4309`
  - `first_missing_index = 1498`
  - `freeze_ready = false`
- Current live broad-tail snapshot:
  - global disk counts:
    - `labels_unique = 2191`
    - `errors_unique = 47`
  - broad-tail manifest:
    - `attempted = 725`
    - `succeeded = 725`
    - `failed = 0`
    - `next_index = 725`

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
  - current broad-tail delta since the morning snapshot:
    - `+738` successful labels
    - `+2` explicit errors
- **Impact:** `freeze_ready` remains false, preventing the safe and trustworthy evaluation of a shadow neural model.

### Current Read
- The overnight run generated real value as corpus progress, not as a freeze unlock.
- The broad-tail follow-up run is materially healthier than the hotspot and is still active.
- Manifest/output mismatches have already been reconciled from output truth and are no longer part of the active strict-failure reasons.
- The remaining known quality hotspot is still concentrated in the flop bucket:
  - `flop|p_lt10|f_0|spr_16p`
  - `attempted = 104`
  - `succeeded = 59`
  - `failed = 45`
  - `fail_rate_attempted = 0.432692`
- The broad-tail shortcut is now usable for day-to-day unattended runs:
  - `.\USER_ONLY\01_run_broad_tail_away.ps1`
  - this path should be used instead of hand-building bridge + labeler + watchdog commands

### Open Questions
- Will the remaining unresolved row segment produce any successful labels, or are they entirely timeout-bound edge cases?
- Is there an expectation to eventually recover strategic value from these timeout-heavy nodes by explicitly tweaking the reference solver runtime, or is deterministic explicit failure acceptable for corpus completion?
- After the broad-tail pass finishes, does `solver_reference_labels.jsonl` actually carry full target distributions in a training-ready shape, or only scalar selected-action labels for the current trainer?

### Active Execution Path
- Run the broad-tail subset through:
  - `.\USER_ONLY\01_run_broad_tail_away.ps1`
- Let it continue until:
  - the labeler exits
  - the watchdog starts intervening repeatedly
  - or a new hidden hotspot becomes obvious in the error pattern

### Recommended Next Checks
1. Let the broad-tail pass finish or reach a stable stopping boundary.
2. Run `scripts\reconcile_offline_label_manifest.py` and then strict `scripts\report_reference_label_postpass.py` to measure the new global delta against `missing_rows = 4309`.
3. Inspect one real `solver_reference_labels.jsonl` row to determine whether `target` contains a full action distribution or only a scalar selected action before scoping the trainer upgrade.
4. After the broad-tail result is known, decide how to treat the quarantined `flop|p_lt10|f_0|spr_16p` bucket.
