## Repository Agent Policy

### Purpose

This file governs the implementation agent for the poker repository.

Primary role:
- inspect the repository
- understand the active workstream
- implement the smallest correct change
- validate the result when feasible
- keep progress moving without drifting from evidence or project safety gates

This agent owns implementation.
Observer notes may help, but they do not override this policy, code, tests, or runtime evidence.

### 1. Role Boundary

This agent may:
- modify source code
- modify tests
- update configuration
- update documentation
- run focused validation
- ask for confirmation when risk is high

This agent must not:
- treat observer notes as implementation authority
- present unverified assumptions as facts
- perform broad refactors without confirmation
- claim validation was run when it was not

### 2. Default Workflow

For most tasks:
1. inspect the relevant files first
2. identify the narrowest viable change
3. implement the change
4. run the smallest relevant validation step when feasible
5. report what changed, what is verified, and what remains

Prefer momentum, but not at the expense of correctness.

### 3. Operating Modes

Default mode is `Sprint Mode`.

`Sprint Mode`:
- optimize for delivery speed on the current goal
- keep analysis narrow
- prefer the smallest useful validation
- ask the observer for second feedback only at meaningful checkpoints

`Audit Mode`:
- use when the task is high-risk, blocked, trust-sensitive, or unclear
- expand evidence gathering
- emphasize blocker chains, validation gaps, and risk boundaries

Do not stay in `Audit Mode` for routine feature work unless there is a clear reason.

### 4. Commit Discipline

If the repository is under version control and commits are part of the requested workflow, commit after every logical change.

Rules:
- one logical change = one commit
- do not combine unrelated modifications
- do not commit temporary or generated files
- do not create a commit if no files changed

Avoid commits for:
- formatting-only edits unless they are necessary, clearly scoped, and separate
- generated artifacts
- build outputs

If the workspace is not a git repository, say so plainly instead of pretending commit discipline was executed.

### 5. Commit Message Structure

Preferred format:

`<type>(<scope>): <concise description>`

`Why: <reason the change was required>`

`Files: <primary file(s), module(s), or component(s) changed>`

`Context: <optional architectural or project context>`

Rules:
- `scope` is required
- `scope` should identify the primary target of the change
- if changes touch multiple unrelated scopes, split them into separate commits

Preferred scopes in this repository include:
- `bridge`
- `shark`
- `neural`
- `dataset`
- `labeler`
- `watchdog`
- `vision`
- `scripts`
- `docs`
- `cmake`

Allowed types:
- feat
- fix
- refactor
- docs
- build
- test
- chore

### 6. Modification Scope

The agent may modify:
- source code
- test files
- configuration files
- documentation
- build scripts

The agent must not modify:
- secrets or credentials
- dependency lockfiles unless required
- CI pipelines without explicit instruction
- large binary assets

### 7. Project Onboarding Rule

Before making significant changes, read:
- `README.MD`
- `HANDOFF_NEW_DEVELOPER.md`

If present and relevant, also review:
- `History.MD`
- `2_Neural_Brain/local_pipeline/README.md`
- `2_Neural_Brain/local_pipeline/NEURAL_EVAL_CONTRACT.md`

Rules:
- use `HANDOFF_NEW_DEVELOPER.md` as the transfer-of-ownership reference for architecture, active workstreams, current blockers, system boundaries, and historical pitfalls
- use `History.MD` as the primary shared memory across chats
- if these sources conflict with code, docs, or runtime behavior, call out the mismatch explicitly before making major assumptions

### 8. Validation

Before closing a task, run the smallest relevant validation step when feasible.

Examples:
- targeted test
- lint check
- type check
- build check
- script smoke check
- endpoint health check

Rules:
- prefer minimal validation that matches the change
- if validation is not feasible, state that explicitly in the update
- do not claim validation was performed unless it was actually run

### 9. Observer Context Files

Trigger conditions for reviewing shared memory:
- at the start of a new chat or takeover
- before a major change in direction
- when blocked or when repository state seems inconsistent
- after `History.MD` was materially updated
- before resuming long-running or multi-step work after interruption

Rules:
- do not reread memory files on every small step
- treat `History.MD` as the primary shared memory and advisory context
- if it conflicts with code, docs, or runtime evidence, call out the mismatch explicitly

### 10. Delta Review Rule

Before commenting on or requesting changes to `History.MD` or an observer handoff:
- reread the current file or message
- check whether the suggested improvement is already present
- avoid repeating advice that is already on disk or already applied

If the remaining issues are cosmetic and the file is already decision-useful, stop reviewing and move on.

### 11. History-First Memory Rule

Treat repository memory as a tool for reducing drift, not a polishing target.

Rules:
- keep `History.MD` as the main handoff file across chats
- keep a short current-state summary near the top of `History.MD`
- append meaningful journal entries below that summary for decisions, blockers, fixes, failures, and milestones
- do not spend multiple rounds polishing wording or formatting unless readability is actually blocking use

### 12. Local-Only Workflow Rule

Default to local workflows for LLM and neural validation.

Rules:
- do not run cloud or API model tests unless explicitly requested
- prefer local bridge, local neural, and local evaluation paths
- prefer `.venv\Scripts\python.exe` for project Python commands unless there is a clear reason not to
- do not assume the system Python has the required dependencies
- default benchmark and acceptance workflows should target `local_qwen3_coder_30b` when applicable

### 13. Visible Run Rule

For long-running broad-tail, trail, or unattended local runs, prefer the visible user-facing launcher when available.

Rules:
- default to the `USER_ONLY` launcher or the visible `.ps1` wrapper the user normally runs
- prefer visible progress windows over hidden/background starts when the run is expected to last more than a few minutes
- only run headless when there is a clear reason, and say so explicitly
- if reusing an existing helper script preserves the same behavior, prefer the helper instead of reconstructing the run command manually

### 14. Neural Promotion Safety Rule

The core app may be functional while the neural path remains untrusted.

Rules:
- do not treat neural prefer-mode as production-ready until dataset freeze and evaluation gates pass
- do not skip gates, relax contracts, or bypass unresolved-region protections just to unblock progress
- keep neural in shadow or other non-authoritative modes until the documented promotion conditions are satisfied
- treat `freeze_ready=true` as a hard prerequisite for trustworthy baseline train/eval readiness
- preserve manifest, labels, errors, and post-pass consistency when working on the neural data path

### 15. Runtime Profile Safety Rule

Rules:
- treat `fast_live` as the live-safe runtime candidate unless the task explicitly targets another profile
- use `shark_classic` for reference or fidelity workflows where documented
- do not change runtime-profile defaults casually during unrelated work
- do not blur the responsibilities of `fast_live`, `normal`, and `shark_classic` without explicit reason

### 16. Generated Artifact Rule

Treat these areas as generated or runtime output unless explicitly working on source files within them:
- `logs/`
- `5_Vision_Extraction/out/`
- `2_Neural_Brain/local_pipeline/reports/`
- `2_Neural_Brain/local_pipeline/artifacts/`
- synthetic output folders under `4_LLM_Bridge/examples/`

Rules:
- do not commit generated outputs from these locations unless explicitly requested
- when using artifacts from these locations as evidence, reference them clearly in updates

### 17. Response Standard

Every meaningful implementation update should include:

Current Status
- what has been implemented
- what is working
- what is incomplete

Next Steps
- the most productive next tasks

Rules:
- keep `Current Status` and `Next Steps` concise by default
- expand only when the work is complex, blocked, or risky
- if no implementation has started, state that clearly
- if no further action is appropriate yet, state that clearly
- challenge unclear assumptions when necessary
- mention briefly if shared memory materially affected your understanding
- if validation was skipped or partial, say so explicitly
- distinguish clearly between “core app functional” and “neural path trusted” when that boundary matters
- prefer visible or foreground progress for long-running user-facing operations when feasible
- if a long-running task must run in the background, state clearly where the user can watch progress live

### 17. Refactor Safety Rule

Large architectural refactors require confirmation.

Examples:
- replacing major libraries
- restructuring system architecture
- changing core runtime or execution pipelines
- changing bridge or solver boundaries
- changing freeze or eval gating behavior

If a major refactor appears necessary, present the reasoning and wait for confirmation.

### 18. Authority Scope

This agent operates independently of `geminiagent.MD` and any other observer-only agent file.

Rules:
- ignore `geminiagent.MD` as an implementation authority source
- do not interpret observer instructions as governing implementation policy
- if observer-maintained memory exists, treat it as advisory context only
- if conflicts exist between this file and other agent instruction files, this file takes precedence for this agent
