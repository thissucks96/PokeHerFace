# PokerBotV1 Workspace

This workspace is organized to keep the engine, neural models, hand history data, and LLM bridge isolated but integration-ready.

## Folder Layout

- `1_Engine_Core`: C++ Shark solver and build system.
- `2_Neural_Brain`: DeepHoldem/DeepStack-style PyTorch stack and pretrained model files.
- `3_Hand_Histories`: PHH/raw hand history data.
- `4_LLM_Bridge`: Python bridge for Docker-hosted LLM -> node-lock JSON.
- `libs`: Third-party native dependencies (including `libtorch`).

## Current App Status

- `shark.exe` (GUI) builds and launches on Windows.
- `shark_cli.exe` (headless) accepts JSON input/output for automated solves.
- Root node-locks are enforced in CFR (`node_id: "root"`).
- Python bridge server (`POST /solve`) runs a two-pass safety loop:
  - baseline no-lock solve,
  - legal-action-constrained lock generation,
  - locked solve,
  - automatic selection of better result (baseline if lock is not better than baseline by `EV_KEEP_MARGIN`, default `0.005`).
- Spot pack tooling is available via `4_LLM_Bridge/build_spot_pack.py` for bulk PHH -> tagged spot conversion with manifest/report output.
- LLM provider selection is supported in the bridge:
  - mock
  - OpenAI API (`gpt-4o-mini`, `gpt-4o`)
  - local OpenAI-compatible endpoints (default production model: `qwen3-coder:30b`)

## Current Limits

- Non-root node ids are parsed but not enforced yet.
- Hand-history ingestion from `3_Hand_Histories` into spot generation is not fully automated yet.
- LLM quality benchmarking and routing policy tuning are still in progress (current local front-runner: `qwen3-coder:30b`).

## Quick Start (Windows)

Run from `A:\PokeHerFace\Version1`:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\setup_windows.ps1
```

Optional tool install pass (uses `winget`):

```powershell
.\scripts\setup_windows.ps1 -InstallTools
```

Run preflight validation (toolchain + runtime DLL staging + shark launch smoke test):

```powershell
.\scripts\preflight_windows.ps1
```

For C++ builds you also need MSVC build tools (`cl.exe`, `nmake`) via Visual Studio Build Tools with the Desktop C++ workload.

## Quick Start (WSL / Linux)

```bash
cd /mnt/a/PokeHerFace/Version1
chmod +x ./scripts/setup_wsl.sh
./scripts/setup_wsl.sh
```

Optional package install pass:

```bash
./scripts/setup_wsl.sh --install-tools
```

## Required Manual Drops

1. Extract CUDA LibTorch into:
   `libs/libtorch`
2. Ensure models exist in:
   `2_Neural_Brain/data/models` (`.pt` or `.tar`)
3. Keep large neural artifacts out of Git history:
   `2_Neural_Brain/src/**` model assets (`.pt`, `.pkl`, `.sqlite`, `.tar`, `.model`) should be local-only.

## C++ GPU Bridge Configure Command

```powershell
cmake -S A:\PokeHerFace\Version1\1_Engine_Core `
      -B A:\PokeHerFace\Version1\1_Engine_Core\build `
      -DENABLE_LIBTORCH=ON `
      -DLIBTORCH_ROOT=A:\PokeHerFace\Version1\libs\libtorch
```

If CMake reports missing `nmake` or compiler, run from a Visual Studio Developer PowerShell/Command Prompt.

## Headless Solver Contract (`shark_cli`)

`shark_cli` now supports JSON-driven headless mode:

```powershell
A:\PokeHerFace\Version1\1_Engine_Core\build_ninja_vcpkg_rel\shark_cli.exe `
  --input A:\PokeHerFace\Version1\1_Engine_Core\testing\fixtures\spot.sample.json `
  --node-lock A:\PokeHerFace\Version1\1_Engine_Core\testing\fixtures\node_lock.sample.json `
  --output A:\PokeHerFace\Version1\1_Engine_Core\testing\fixtures\result.sample.json
```

- Input schema: `spot.json` (`hero_range`, `villain_range`, `board`, solve params).
- Optional input: `node_lock.json` (root-node locks are enforced in CFR; non-root ids are currently ignored).
- Output schema: `result.json` (timing, exploitability, tree stats, root action frequencies, warnings).

## Project Direction

This project combines:

- high-performance poker solving on RTX 4090 (especially compute-heavy turn/river spots), and
- a modern LLM-hybrid layer for strategy interpretation and node-lock generation.

### Near-Term Direction

1. Benchmark local LLMs (`gpt-oss:20b`, Llama, DeepSeek) vs OpenAI presets on lock quality, latency, and solve outcomes.
2. Keep `gpt-5-mini` as default API path and escalate difficult spots to `gpt-5.2`.
3. Expand node-lock support beyond root to node-path targeting.
4. Automate PHH -> spot JSON conversion and batch solve orchestration.
