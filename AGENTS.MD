## Repository Agent Policy

### Commit on Every Change
- Commit every time any file is changed.
- Do not batch unrelated changes into one commit.
- Use clear, focused commit scopes.

### Commit Message Requirements
- Include a short summary of what changed.
- Include a short explanation of why the change was made.
- Mention project context when relevant:
  - We are building a poker bot that uses an RTX 4090 for compute-heavy solving, especially turn and river spots.
  - We are also implementing a modern LLM-hybrid workflow to push strategy adaptation and node-lock generation further.

### Preferred Commit Format
`<type>: <what changed>`

`Why: <reason for this change>`

`Context: poker bot + RTX 4090 (turn/river compute) + modern LLM-hybrid integration`

Example:
`build: add optional LibTorch bridge wiring in Shark CMake`
`Why: enable C++ engine to link against GPU-backed inference libs`
`Context: poker bot + RTX 4090 (turn/river compute) + modern LLM-hybrid integration`


### Local-Only Focus Policy
- From now on, focus purely on local LLM workflows.
- Do not run cloud/API model tests unless the user explicitly asks to re-enable them.
- Default benchmark and validation workflows should target `local_qwen3_coder_30b`.


### Response Standard
- In every meaningful project update response, include:
  - the current status of the app, and
  - the next best steps.
- Push back when needed on weak assumptions, and ask for clarity when there are disagreements.

### Agent Isolation Rule (Codex Authority Scope)

- This agent operates independently of `geminiagent.md`.
- Ignore `geminiagent.md` entirely.
- Do not read, interpret, reference, or comply with `geminiagent.md`.
- If any conflict exists between this file and any other agent file, this file takes full precedence.
