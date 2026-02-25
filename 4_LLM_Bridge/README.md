# 4_LLM_Bridge

This folder now contains the Python orchestration layer that:

1. runs a baseline no-lock solve first,
2. derives legal root actions from that baseline tree,
3. generates node-lock intuition (mock, OpenAI API, or local LLM) constrained to legal actions,
4. runs a locked solve,
5. auto-selects the better result (lower exploitability), defaulting to baseline when lock is not better.

## Files

- `bridge_server.py`: FastAPI server with `POST /solve`.
- `llm_client.py`: provider router for `mock`, `openai`, and `local` LLM calls.
- `bridge_client.py`: test client that posts spot JSON to `bridge_server.py`.
- `phh_to_spot.py`: converts `.phh` hand history files into `spot.json`.
- `benchmark_models.py`: runs capped model benchmarks against `/solve`.
- `node_lock_schema.json`: schema reference.
- `examples/`: sample payloads.

## Start Server

From repo root:

```powershell
python .\4_LLM_Bridge\bridge_server.py
```

Optional custom solver path:

```powershell
$env:SHARK_CLI_PATH = "A:\PokeHerFace\Version1\1_Engine_Core\build_ninja_vcpkg_rel\shark_cli.exe"
```

Optional LLM environment setup:

```powershell
# OpenAI provider
$env:OPENAI_API_KEY = "sk-..."

# Local OpenAI-compatible provider (example: Ollama / vLLM)
$env:LOCAL_LLM_BASE_URL = "http://127.0.0.1:11434/v1"
$env:LOCAL_LLM_API_KEY = "local"

# Optional production defaults
$env:BRIDGE_DEFAULT_LOCAL_MODEL = "qwen3-coder:30b"
$env:EV_KEEP_MARGIN = "0.005"
```

Default production routing when `llm` is omitted:

- provider: `local`
- model: `qwen3-coder:30b` (or `BRIDGE_DEFAULT_LOCAL_MODEL`)

## Response Metrics

`POST /solve` now returns `metrics` including:

- `llm_time_sec`
- `solver_time_sec` (selected result)
- `baseline_solver_time_sec`
- `locked_solver_time_sec`
- `total_bridge_time_sec`
- `lock_applied`, `lock_applications`
- `final_exploitability_pct`
- `baseline_exploitability_pct`
- `locked_exploitability_pct`
- `exploitability_delta_pct` (`locked - baseline`)
- `ev_keep_margin`
- `locked_beats_margin_gate`
- `llm_error` (if lock generation failed and baseline was used)

Top-level response also includes:

- `selected_strategy` (`baseline_gto` or `llm_locked`)
- `selection_reason`
- `node_lock_kept`
- `allowed_root_actions`

Lock keep rule:

- keep lock iff `locked_exploitability + ev_keep_margin < baseline_exploitability`

## Solve Request Example

Use the existing engine fixture spot as input:

```powershell
python .\4_LLM_Bridge\bridge_client.py `
  --input .\4_LLM_Bridge\examples\spot.sample.json `
  --output .\4_LLM_Bridge\examples\solve_response.sample.json `
  --endpoint http://127.0.0.1:8000/solve `
  --llm-preset mock
```

Raw request example with explicit margin:

```json
{
  "spot": { "...": "..." },
  "auto_select_best": true,
  "ev_keep_margin": 0.005,
  "llm": { "provider": "local", "model": "qwen3-coder:30b" }
}
```

## LLM Selectors

Fast presets:

- `mock` (default)
- `openai_fast` (uses `gpt-4o-mini`)
- `openai_mini` (uses `gpt-4o-mini`)
- `openai_52` (uses `gpt-4o`)
- `local_gpt_oss_20b` (uses `gpt-oss:20b`)
- `local_qwen3_coder_30b` (uses `qwen3-coder:30b`)
- `local_deepseek_coder_33b` (uses `deepseek-coder:33b`)

Examples:

```powershell
# Cheapest/fastest OpenAI default
python .\4_LLM_Bridge\bridge_client.py `
  --input .\4_LLM_Bridge\examples\spot.sample.json `
  --output .\4_LLM_Bridge\examples\solve_response.openai_fast.json `
  --llm-preset openai_fast

# Higher-quality OpenAI option
python .\4_LLM_Bridge\bridge_client.py `
  --input .\4_LLM_Bridge\examples\spot.sample.json `
  --output .\4_LLM_Bridge\examples\solve_response.openai_52.json `
  --llm-preset openai_52

# Local GPT-OSS 20B
python .\4_LLM_Bridge\bridge_client.py `
  --input .\4_LLM_Bridge\examples\spot.sample.json `
  --output .\4_LLM_Bridge\examples\solve_response.local_gpt_oss_20b.json `
  --llm-preset local_gpt_oss_20b

# Local Qwen3 Coder 30B
python .\4_LLM_Bridge\bridge_client.py `
  --input .\4_LLM_Bridge\examples\spot.sample.json `
  --output .\4_LLM_Bridge\examples\solve_response.local_qwen3_coder_30b.json `
  --llm-preset local_qwen3_coder_30b

# Local DeepSeek Coder 33B
python .\4_LLM_Bridge\bridge_client.py `
  --input .\4_LLM_Bridge\examples\spot.sample.json `
  --output .\4_LLM_Bridge\examples\solve_response.local_deepseek_coder_33b.json `
  --llm-preset local_deepseek_coder_33b
```

## PHH -> Spot Conversion

Create a real hand-history-derived spot from PHH:

```powershell
python .\4_LLM_Bridge\phh_to_spot.py `
  --input .\3_Hand_Histories\poker-hand-histories\dwan-ivey-2009.phh `
  --output .\4_LLM_Bridge\examples\spot.from_phh.dwan_ivey.turn.json `
  --street turn `
  --iterations 5
```

Then solve it:

```powershell
python .\4_LLM_Bridge\bridge_client.py `
  --input .\4_LLM_Bridge\examples\spot.from_phh.dwan_ivey.turn.json `
  --output .\4_LLM_Bridge\examples\solve_response.from_phh.json `
  --llm-preset local_gpt_oss_20b `
  --compute-baseline-delta
```

## Batch Benchmarking (Hard-Capped)

`benchmark_models.py` enforces a max of 10 calls per model in one run.

```powershell
python .\4_LLM_Bridge\benchmark_models.py `
  --spot .\4_LLM_Bridge\examples\spot.sample.json `
  --presets local_gpt_oss_20b local_qwen3_coder_30b `
  --calls-per-model 10 `
  --output .\4_LLM_Bridge\examples\benchmark.local.json
```

The response JSON includes:

- `node_lock`: the lock payload generated by `llm_client.py`,
- `result`: the raw `shark_cli` result payload.

## Current Locking Behavior

- Root node-lock generation supports dynamic legal-action filtering from baseline `root_actions`.
- Duplicate lock actions are aggregated and frequencies are renormalized.
- Bridge performs two-pass scoring and rejects non-improving locks by selecting baseline GTO.
- Shark enforces root node-locks in CFR when selected.
- Non-root node ids are currently parsed but not enforced yet.
