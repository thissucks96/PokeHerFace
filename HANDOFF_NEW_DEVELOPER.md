# PokeHerFace V1 - Developer Handoff / Transfer of Ownership

Last updated: 2026-03-05 (America/Los_Angeles)  
Primary repository root: `A:\PokeHerFace\Version1`

---

## 1) Executive Summary

This project is a heads-up poker system composed of:
- a C++ discounted-CFR solver core (`shark_cli`),
- a Python bridge/router layer (FastAPI) that orchestrates solve calls and profile behavior,
- a WinForms tester loop for manual + semi-automated gameplay,
- a local neural pipeline for shadow-mode learning and later controlled promotion.

The system is functional and playable. The most important current program objective is not UI work or new strategy features, but **closing the data-to-training loop with strict integrity guarantees** so neural experiments can be trusted.

Current position:
- Bridge/runtime architecture is significantly hardened.
- Feature-contract parity and extraction telemetry are in place.
- Offline reference labeling is partially completed but not freeze-ready.
- Promotion contract and holdout air-gap policy are now documented and partially automated.

---

## 2) Architecture and Codebase Map

## Root Directories

- `1_Engine_Core/`  
  Shark solver source and binaries. Core solving path (`shark_cli`) is CPU multithreaded.

- `2_Neural_Brain/`  
  Neural research workspace. Current active path is `local_pipeline/` (train-our-own).

- `3_Hand_Histories/`  
  Hand-history corpora and conversion inputs.

- `4_LLM_Bridge/`  
  FastAPI bridge and simulation tools. This is the central orchestration layer.

- `5_Vision_Extraction/`  
  UI runtime artifacts, OCR/capture output, and session logs.

- `scripts/`  
  Operational scripts for setup, simulation, dataset creation, labeling, quality gates, and validation.

## Root Files

- `README.MD`  
  Operational quick-start, runtime profile notes, and major commands.

- `shared_feature_contract.py`  
  Canonical feature contract used by both offline and live paths. Includes deterministic hashing, vectorization, and extraction validation metadata.

- `AGENTS.MD`  
  Repository-specific agent policy (commit/message/workflow constraints).

---

## 3) Major Modules and Responsibilities

## `4_LLM_Bridge/bridge_server.py`

Core API service. Responsibilities:
- Validate/normalize incoming `spot` payloads.
- Route by runtime profile (`fast_live`, `normal`, `normal_neural`, `shark_classic`).
- Launch baseline solve and optional locked solve paths.
- Apply fallback policies and complexity guards.
- Apply unresolved neural gate blocking.
- Produce rich telemetry in `metrics`.
- Expose `/health` with configuration and runtime telemetry snapshots.

Key behavior themes:
- `fast_live`: bounded latency, aggressive fallback protections.
- `normal`: stronger but can exceed practical latency on hard nodes.
- `shark_classic`: fidelity/reference behavior path.
- Neural path defaults to shadow/guarded usage.

## `4_LLM_Bridge/neural_brain_adapter.py`

Neural adapter invocation logic used by bridge.  
In production-safe mode, neural is gated and not authoritative unless explicit promotion conditions are met.

## `4_LLM_Bridge/run_stateful_sim.py`

Synthetic hand runner for profile testing and A/B comparisons.  
Used heavily to generate performance and strategy drift evidence.

## `scripts/build_neural_dataset.py`

Builds dataset rows from bridge artifacts.  
Now stamps feature contract metadata (`schema/hash/key/vector`) per row.

## `scripts/label_reference_offline.py`

Long-running offline reference labeler:
- calls bridge endpoint with heavy reference profile,
- supports checkpointing, resume, retries, and manifest output,
- writes labels and errors JSONL outputs.

## `scripts/watch_offline_labeler_guard.ps1`

Operational watchdog for stale labeler processes:
- detects stale writes,
- repairs JSONL tail safety,
- restarts via resume workflow.

## `scripts/report_reference_label_postpass.py`

Streaming post-pass validator:
- bucket fail rates (`failed/attempted`),
- integrity checks of distribution legality,
- strict freeze verdict (`freeze_ready`),
- unresolved gate ID export (exact and coarse).

## `scripts/test_feature_contract_parity.py`

Parity checker between offline row encoding and live-spot encoding contract.  
Critical anti-drift test before scaling generation/training.

## `scripts/check_neural_data_airgap.py` (new)

Train-vs-holdout leakage checker:
- `row_id` overlap,
- `feature_key_hash` overlap.

Use this before evaluating any model promotion candidate.

## `2_Neural_Brain/local_pipeline/`

Canonical local training workspace:
- `configs/` training/eval/quality gate templates.
- `data/raw_spots/` and `data/processed/`.
- `artifacts/checkpoints/` and `artifacts/exports/`.
- `reports/`.

New contract doc:
- `2_Neural_Brain/local_pipeline/NEURAL_EVAL_CONTRACT.md`

---

## 4) End-to-End System Flow

## A) Live Gameplay/Decision Flow

1. UI/game loop captures or constructs current state.
2. A `spot` payload is sent to bridge `POST /solve`.
3. Bridge selects runtime profile and pre-processes spot constraints.
4. Baseline solve path runs (or guarded fast-fail fallback path if intractable).
5. Optional neural shadow call is attempted if enabled and not unresolved-gated.
6. Bridge returns selected action, action distribution, and full metrics.
7. UI applies action legality and game state transition logic.

Important:
- Fail-safes prioritize continuity and legal actions over perfect equilibrium when time budget is threatened.
- Feature extraction now returns explicit validity status and timing telemetry.

## B) Offline Data and Training Flow

1. Generate teacher rows via synthetic/stateful collection recipes.
2. Run quality gate checks on distribution mix.
3. Label with reference profile using offline labeler (`shark_classic` style reference path).
4. Run strict post-pass validation and unresolved gate export.
5. Verify train/holdout air-gap.
6. Freeze artifact.
7. Train baseline model.
8. Evaluate on holdout against locked contract.
9. Promote only if all hard gates pass.

---

## 5) Data Flow, Dependencies, and Integration Points

## Data Paths

- Bridge artifacts: `5_Vision_Extraction/out/flop_engine/...`
- Teacher rows: `logs/.../solver_teacher_rows*.jsonl`
- Reference labels: `2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels*.jsonl`
- Label errors: `2_Neural_Brain/local_pipeline/reports/offline_label_errors*.jsonl`
- Label manifest: `2_Neural_Brain/local_pipeline/reports/offline_label_manifest*.json`
- Post-pass report: `2_Neural_Brain/local_pipeline/reports/reference_label_postpass_report.json`
- Unresolved gate export: `2_Neural_Brain/local_pipeline/reports/unresolved_gate_ids.json`

## Dependency Relationships

- Bridge depends on:
  - `shark_cli` executable from `1_Engine_Core/`,
  - local LLM/neural adapter components,
  - feature contract module (`shared_feature_contract.py`).

- Dataset/training scripts depend on:
  - bridge output schema,
  - shared feature contract,
  - post-pass and quality-gate outputs.

- Promotion decisions depend on:
  - integrity and manifest checks,
  - holdout leakage checks,
  - latency + EV contract thresholds.

## Critical Integration Points

- Bridge <-> Solver (`shark_cli`) process boundary.
- Bridge <-> Neural adapter boundary (shadow/prefer gating).
- Offline labeler <-> bridge endpoint reliability under long timeout rows.
- Post-pass strict contract as final gate before training.

---

## 6) Current Development Focus and Why

Primary focus: **finish trustworthy reference corpus and gate-driven baseline training**.

Why:
- There is enough infrastructure to run experiments.
- Additional infra tweaks without a first gated training/eval pass risk "infrastructural quicksand."
- We need objective evidence of EV/latency value before more system complexity.

The strategy now is timeboxed:
1. complete/fix data freeze path,
2. run one baseline model pass,
3. evaluate against locked contract,
4. decide continue/pivot.

---

## 7) In Progress / Blocked / Unfinished

## In Progress

- Offline reference labeling completion for merged pilot corpus.
- Strict freeze path operationalization with manifest-synced semantics.

## Blocked

- Baseline training promotion path is blocked by `freeze_ready=false`.
- Current post-pass indicates:
  - large missing row count,
  - manifest mismatch against accumulated output files.

## Unfinished

- Full automation of all contract thresholds in one evaluator (some thresholds are documented/configured, but not yet universally enforced by a single script).
- End-to-end promotion run on a clean, fully frozen corpus.
- Long-horizon stability checks under production-like load.

---

## 8) Historical Technical Challenges and Resolutions

## Challenge: Game-state desync and illegal action loops

Symptoms:
- check/call mismatch,
- repeated actions required,
- WAIT/check lock-ups.

Resolution:
- tightened action legality checks,
- improved state transition handling,
- better table/status telemetry and explicit action metadata.

Lesson:
- in betting engines, state machine correctness outranks strategy quality early.

## Challenge: Flop latency explosions / timeouts

Symptoms:
- multi-second to minute+ stalls on specific geometries.

Resolution:
- `fast_live` profile complexity reduction,
- flop complexity guard and fast-fail behavior,
- bounded fallback selection with telemetry.

Lesson:
- bounded latency architecture needs explicit "intractable geometry" handling, not just higher timeouts.

## Challenge: Neural feature drift risk

Symptoms:
- offline/live encoding mismatch risk in rapidly changing code.

Resolution:
- shared feature contract + schema/hash,
- parity checker script,
- bridge extraction telemetry and validity flags.

Lesson:
- no model promotion without deterministic feature parity proof.

## Challenge: Offline labeling brittleness

Symptoms:
- long-running process stalls, partial writes, restart fragility.

Resolution:
- manifest/checkpoint/retry design,
- stale-write watchdog,
- post-pass streaming integrity checks.

Lesson:
- treat data generation as operations engineering, not just scripting.

---

## 9) Current Strengths and Stable Areas

- Bridge profile routing and fallback behavior are robust for live loop continuity.
- Feature contract and parity path are stable and measurable.
- Telemetry surface is rich enough for diagnosis.
- Strict post-pass integrity logic catches malformed training artifacts.
- Deterministic unresolved gate protects live inference from known unresolved regions.

---

## 10) Known Weaknesses, Technical Debt, and Risks

- Reference label completion is partial; freeze gate currently failing.
- Manifest sync semantics can conflict with resumed/pre-populated output files.
- Some promotion contract checks are documented but not fully centralized in one executable evaluator.
- `normal` profile quality is useful but latency impractical for production loops.
- Untracked local artifacts (`logs/`, synthetic outputs) can obscure operational state if not curated.

Risk:
- accidental leakage between train and holdout if air-gap checks are skipped.

---

## 11) Setup and Workflow (Windows)

## Environment setup

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\setup_windows.ps1
.\scripts\preflight_windows.ps1
```

## Start bridge

```powershell
python .\4_LLM_Bridge\bridge_server.py
```

## Run synthetic profile tests

```powershell
.\scripts\test_stateful_sim.ps1 -Hands 50 -RuntimeProfile fast_live -VillainMode engine_random
```

## Build/check dataset path

```powershell
python .\scripts\build_neural_dataset.py --write
python .\scripts\validate_neural_dataset.py --strict
python .\scripts\test_feature_contract_parity.py --input-jsonl .\2_Neural_Brain\local_pipeline\data\raw_spots\solver_teacher_rows.jsonl --strict
```

## Label/reference + post-pass

```powershell
python .\scripts\label_reference_offline.py --resume
python .\scripts\report_reference_label_postpass.py --strict
```

## Air-gap check

```powershell
python .\scripts\check_neural_data_airgap.py --train-jsonl <train> --holdout-jsonl <holdout> --strict
```

---

## 12) Testing, Validation, and Acceptance

Required checks before baseline training:
- strict post-pass: `freeze_ready=true`
- no integrity failures
- manifest sync clean
- air-gap check passes

Required checks before any prefer-mode consideration:
- contract thresholds in `NEURAL_EVAL_CONTRACT.md` pass
- latency SLA pass
- EV delta target pass
- fallback safety preserved

---

## 13) Deployment and Operations Notes

- Production candidate profile remains `fast_live`.
- Keep `normal` for quality/reference experiments, not default live operation.
- Keep neural in `shadow` until contract gates pass.
- Preserve watchdog and log discipline for any long offline label runs.
- Use no-sleep/high-performance host policy during long labeling jobs.

---

## 14) Debugging and Maintenance Runbook

If bridge action quality looks wrong:
1. Inspect `metrics` in solve response (selected strategy, fallback flags, unresolved gate fields).
2. Verify runtime profile and active guard settings.
3. Inspect recent artifact payload/response JSONs from sim runs.

If offline labeling stalls:
1. Check manifest write timestamp and process state.
2. Use watchdog for stale-write relaunch.
3. Repair JSONL tail if process was force-killed.
4. Resume and continue from manifest index.

If post-pass fails:
1. Separate integrity failures from completeness/mismatch failures.
2. Resolve manifest semantics for resumed outputs.
3. Re-run strict report and only proceed on clean freeze verdict.

If neural eval looks overly optimistic:
1. Run air-gap checker.
2. Verify holdout separation and seed discipline.
3. Confirm unresolved gate behavior is deterministic and logged.

---

## 15) Immediate Next Actions for New Owner

1. Resolve current `freeze_ready=false` state by completing or cleanly restarting label/reference pass with consistent manifest/output semantics.
2. Run strict post-pass to green.
3. Build train/holdout splits and run air-gap check.
4. Train one baseline model.
5. Evaluate once against locked contract.
6. Decide continue/pivot based on objective metrics only.

---

## 16) Practical Ownership Notes

- Treat this as a reliability-first ML systems project.
- Avoid adding new infra while baseline value proof is pending.
- Preserve deterministic guardrails even if you iterate strategy logic.
- Keep a strict separation between:
  - "pipeline correctness work"
  - "model quality work"
  - "runtime promotion decisions"

That separation is what prevents regressions and bad promotions.

