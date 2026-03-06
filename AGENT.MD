## Repository Agent Policy

### 1. Commit Discipline
Commit after every logical change to the repository.

Rules:
- One logical change = one commit.
- Do not combine unrelated modifications.
- Do not commit temporary or generated files.
- Do not create a commit if no files changed.

Examples of logical changes:
- modifying a function
- updating documentation
- adjusting build configuration
- adding or updating tests for a focused behavior change

Avoid commits for:
- formatting-only edits unless they are necessary, clearly scoped, and committed separately
- generated artifacts
- build outputs


### 2. Commit Message Structure

All commits must follow this format:

`<type>(<scope>): <concise description>`

`Why: <reason the change was required>`

`Files: <primary file(s), module(s), or component(s) changed>`

`Context: <optional architectural or project context>`

Rules:
- `scope` is required.
- `scope` must identify the primary target of the change.
- Prefer scope in this order:
  1. module or component name
  2. directory name
  3. file name, if the change is highly localized
- `Files` is required and must reference the main file(s) or code area affected.
- Avoid vague scopes such as `misc`, `update`, `changes`, or `stuff`.
- If changes touch multiple unrelated scopes, split them into separate commits.

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

Allowed commit types:
- feat
- fix
- refactor
- docs
- build
- test
- chore


Example:

`build(cmake): add optional platform configuration include`

`Why: allow the build system to load environment-specific settings cleanly`

`Files: CMakeLists.txt, cmake/platform.cmake`

`Context: build configuration modularity`


### 3. Modification Scope

The agent may modify:
- source code
- test files
- configuration files
- documentation
- build scripts

The agent must NOT modify:
- secrets or credentials
- dependency lockfiles unless required
- CI pipelines without explicit instruction
- large binary assets


### 4. Project Onboarding Rule

Before making significant changes, read:
- `README.MD`
- `HANDOFF_NEW_DEVELOPER.md`

Use `HANDOFF_NEW_DEVELOPER.md` as the transfer-of-ownership reference for:
- architecture
- active workstreams
- current blockers
- system boundaries
- historical pitfalls


### 5. Local-Only Workflow Rule

Default to local workflows for LLM and neural validation.

Rules:
- Do not run cloud/API model tests unless explicitly requested.
- Prefer local bridge, local neural, and local evaluation paths.
- Default benchmark and acceptance workflows should target `local_qwen3_coder_30b` when applicable.


### 6. Neural Promotion Safety Rule

The core app may be functional while the neural path remains untrusted.

Rules:
- Do not treat neural prefer-mode as production-ready until dataset freeze and evaluation gates pass.
- Do not skip gates, relax contracts, or bypass unresolved-region protections just to unblock progress.
- Keep neural in shadow or other non-authoritative modes until the documented promotion conditions are satisfied.


### 7. Dataset Freeze Integrity Rule

For neural pipeline work, data integrity outranks speed.

Rules:
- Treat `freeze_ready=true` as a hard prerequisite for baseline train/eval readiness.
- Preserve manifest, labels, errors, and post-pass consistency.
- Prefer deterministic resume and explicit error accounting over silent skips or optimistic assumptions.
- If a corpus is incomplete, describe the blocker chain before proposing promotion or evaluation work.


### 8. Python Environment Rule

Use the repository virtual environment when running Python tooling unless there is a clear reason not to.

Rules:
- Prefer `.venv\Scripts\python.exe` for project scripts and services.
- Do not assume the system Python has the required dependencies.
- If a command is run outside the venv, state that explicitly.


### 9. Generated Artifact Rule

Treat these areas as generated or runtime output unless explicitly working on source files within them:
- `logs/`
- `5_Vision_Extraction/out/`
- `2_Neural_Brain/local_pipeline/reports/`
- `2_Neural_Brain/local_pipeline/artifacts/`
- synthetic output folders under `4_LLM_Bridge/examples/`

Do not commit generated outputs from these locations unless explicitly requested.


### 10. Validation Before Commit


Before committing, run the smallest relevant validation step when feasible.

Examples:
- targeted test
- lint check
- type check
- build check

Rules:
- Prefer minimal validation that matches the change.
- If validation is not feasible, state that explicitly in the update.
- Do not claim validation was performed unless it was actually run.


### 11. Response Standard

Every meaningful implementation update should include:

Current Status
- what has been implemented
- what is working
- what is incomplete

Next Steps
- the most productive next tasks

Rules:
- Keep `Current Status` and `Next Steps` concise by default.
- For brief progress notes, a short end-of-update summary is sufficient.
- Expand only when the work is complex, blocked, or risky.
- If no implementation has started, state that clearly under `Current Status`.
- If no further action is appropriate yet, state that clearly under `Next Steps`.
- Challenge unclear assumptions and request clarification when necessary.


### 12. Runtime Profile Safety Note

Rules:
- Treat `fast_live` as the live-safe runtime candidate unless the task explicitly targets another profile.
- Use `shark_classic` for reference or fidelity workflows where documented.
- Do not change runtime-profile defaults casually during unrelated work.


### 13. Refactor Safety Rule

Large architectural refactors require confirmation.

Examples:
- replacing major libraries
- restructuring system architecture
- changing core runtime or execution pipelines


### 14. Agent Authority Scope

This agent operates independently of `geminiagent.md` and any other observer-only agent file.

Rules:
- Ignore `geminiagent.md`
- Do not reference or interpret its instructions
- If conflicts exist between this file and other agent instruction files, this file takes precedence for this agent
