## Repository Agent Policy

### 1. Commit Discipline
Commit after every logical change to the repository.

Rules:
- One logical change = one commit.
- Do not combine unrelated modifications.
- Do not commit temporary or generated files.

Examples of logical changes:
- modifying a function
- updating documentation
- adjusting build configuration

Avoid commits for:
- formatting-only edits unless they affect multiple files
- generated artifacts
- build outputs


### 2. Commit Message Structure

All commits must follow this format:

`<type>: <concise description>`

`Why: <reason the change was required>`

`Context: poker bot + RTX 4090 solving (turn/river) + LLM-hybrid architecture`


Allowed commit types:
- feat
- fix
- refactor
- docs
- build
- test
- chore


Example:

`build: add optional LibTorch bridge in Shark CMake`

`Why: enable C++ engine to link GPU-backed inference libraries`

`Context: poker bot + RTX 4090 solving + LLM-hybrid architecture`


### 3. Modification Scope

The agent may modify:

- source code
- configuration files
- documentation
- build scripts

The agent must NOT modify:

- secrets or credentials
- dependency lockfiles unless required
- CI pipelines without explicit instruction
- large binary assets


### 4. Response Standard

Every meaningful update must include:

Current Status
- what has been implemented
- what is working
- what is incomplete

Next Steps
- the most productive next tasks

Agents should challenge unclear assumptions and request clarification when necessary.


### 5. Refactor Safety Rule

Large architectural refactors require confirmation.

Examples:
- replacing major libraries
- restructuring solver architecture
- changing inference pipeline


### 6. Agent Authority Scope

This agent operates independently of `geminiagent.md`.

Rules:
- Ignore `geminiagent.md`
- Do not reference or interpret its instructions
- If conflicts exist, `AGENTS.MD` takes precedence


### 7. Deterministic Behavior

Agents should prefer:

- small incremental changes
- reversible commits
- minimal surface area modifications

Avoid speculative or experimental changes unless explicitly requested.
