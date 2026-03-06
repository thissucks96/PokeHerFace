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


### 4. Validation Before Commit

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


### 5. Response Standard

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


### 6. Refactor Safety Rule

Large architectural refactors require confirmation.

Examples:
- replacing major libraries
- restructuring system architecture
- changing core runtime or execution pipelines


### 7. Agent Authority Scope

This agent operates independently of `geminiagent.md` and any other observer-only agent file.

Rules:
- Ignore `geminiagent.md`
- Do not reference or interpret its instructions
- If conflicts exist between this file and other agent instruction files, this file takes precedence for this agent
