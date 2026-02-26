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

### API Testing Safety Limit
- Batch testing is capped at 10 calls per model unless the user explicitly grants permission to exceed it.
- Until the user confirms plan tier is upgraded, enforce cloud/API calls sequentially with a per-call delay.
- Default minimum delay between OpenAI calls is `OPENAI_MIN_INTERVAL_SEC=2.5` to avoid Tier 1 burst/rate-limit failures.

### Documentation Maintenance
- When significant code changes are made (new capabilities, major behavior changes, or new workflows), update `README.MD` in the same workstream.

### Response Standard
- In every meaningful project update response, include:
  - the current status of the app, and
  - the next best steps.
