# 4_LLM_Bridge

This folder now contains the Python orchestration layer that:

1. runs a baseline no-lock solve first,
2. derives legal root actions from that baseline tree,
3. generates node-lock intuition (mock, OpenAI API, or local LLM) constrained to legal actions,
4. runs a locked solve,
5. auto-selects the better result (lower exploitability), defaulting to baseline when lock is not better.

Production local policy defaults to `qwen3-coder:30b` only; challenger local models must set `llm.mode="benchmark"`.

## Files

- `bridge_server.py`: FastAPI server with `POST /solve`.
- `llm_client.py`: provider router for `mock`, `openai`, and `local` LLM calls.
- `bridge_client.py`: test client that posts spot JSON to `bridge_server.py`.
- `phh_to_spot.py`: converts `.phh` hand history files into `spot.json`.
- `build_spot_pack.py`: bulk PHH -> spot pack builder with tags + validation + report.
- `extract_opponent_features.py`: PHH -> smoothed opponent profile extraction (`fold_to_turn_probe`, `fold_to_river_bigbet`).
- `phh_features/`: parser + feature + aggregation modules used by extraction and spot-pack enrichment.
- `build_canonical_pack.py`: deterministic stratified canonical pack builder (e.g., fixed turn-20 set).
- `benchmark_models.py`: runs capped model benchmarks against `/solve`.
- `run_acceptance_gate.py`: CI-style acceptance gate with preflight filtering and pass/fail thresholds.
- `tag_spot_classes.py`: rollout class tagger for controlled multi-node experiments.
- `run_true_backtest.py`: A/B/C routing comparison runner with bb/100 proxy, EV delta, fallback/keep, and p50/p95 latency.
- `analyze_shadow_dumps.py`: compares shadow vs challenger backtest records and surfaces per-spot River failure patterns.
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
$env:EV_KEEP_MARGIN = "0.001"
$env:ENFORCE_PRIMARY_LOCAL_ONLY = "1"
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
- `lock_confidence`, `lock_confidence_tag`, `lock_quality_score`, `node_lock_target_count`

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
  "ev_keep_margin": 0.001,
  "opponent_profile": {"vpip": 35, "pfr": 25, "agg": 1.8},
  "enable_multi_node_locks": false,
  "llm": { "provider": "local", "model": "qwen3-coder:30b" }
}
```

Notes:

- `enable_multi_node_locks=false` keeps strict root-only generation/validation (recommended production default).
- `enable_multi_node_locks=true` allows multiple `node_locks` targets when the model and spot support it.

## LLM Selectors

Fast presets:

- `mock` (default)
- `openai_fast` (uses `gpt-5-mini` by default)
- `openai_mini` (uses `gpt-5-mini` by default)
- `openai_5mini` (explicit alias for `gpt-5-mini`)
- `openai_52` (uses `gpt-5.2` by default)
- `local_gpt_oss_20b` (uses `gpt-oss:20b`)
- `local_qwen3_coder_30b` (uses `qwen3-coder:30b`)
- `local_deepseek_coder_33b` (uses `deepseek-coder:33b`)
- `local_llama3_8b` (uses `llama3.1:8b`)

OpenAI model defaults can be overridden with env vars:

- `OPENAI_MODEL_FAST`
- `OPENAI_MODEL_MINI`
- `OPENAI_MODEL_52`

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

## Build Spot Pack

Bulk-build a tagged spot pack from a PHH directory:

```powershell
python .\4_LLM_Bridge\build_spot_pack.py `
  --phh-dir .\3_Hand_Histories\poker-hand-histories `
  --output-dir .\4_LLM_Bridge\examples\spot_pack\spots `
  --street turn `
  --opponent-profile-mode pool `
  --benchmark-mode `
  --report .\4_LLM_Bridge\examples\spot_pack\spot_pack_report.json `
  --output-manifest .\4_LLM_Bridge\examples\spot_pack\spot_pack_manifest.jsonl
```

With explicit tags/metadata via manifest (`.json`, `.jsonl`, or `.csv`):

```powershell
python .\4_LLM_Bridge\build_spot_pack.py `
  --phh-dir .\3_Hand_Histories\poker-hand-histories `
  --manifest .\4_LLM_Bridge\examples\spot_pack\manifest.jsonl `
  --output-dir .\4_LLM_Bridge\examples\spot_pack\spots `
  --report .\4_LLM_Bridge\examples\spot_pack\spot_pack_report.json `
  --output-manifest .\4_LLM_Bridge\examples\spot_pack\spot_pack_manifest.jsonl
```

Example manifest entry:

```json
{
  "id": "dwan_ivey_2009_turn",
  "phh": "dwan-ivey-2009.phh",
  "street": "turn",
  "texture": "rainbow",
  "depth": "deep_3bp",
  "position": "ip"
}
```

Tag values:

- `texture`: `monotone | paired | connected | rainbow | two_tone | unknown`
- `depth`: `shallow_srp | deep_3bp | unknown`
- `position`: `ip | oop | unknown`

`--benchmark-mode` forces `remove_donk_bets=false` to keep benchmark action spaces non-trivial.

Opponent-profile enrichment options:

- `--opponent-profile-mode off|pool` (default `pool`)
- `--opponent-alpha` / `--opponent-beta` (default `2.0`, `2.0`)
- `--opponent-big-bet-threshold` (default `0.75`)
- Generated spots include `meta.opponent_profile` with smoothed fold metrics.

## Extract Opponent Features

```powershell
python .\4_LLM_Bridge\extract_opponent_features.py `
  --phh-dir .\3_Hand_Histories\poker-hand-histories `
  --output .\4_LLM_Bridge\examples\opponent_features.summary.json `
  --profiles-jsonl .\4_LLM_Bridge\examples\opponent_features.players.jsonl
```

This computes smoothed baseline metrics:

- `fold_to_turn_probe`
- `fold_to_river_bigbet`
- `river_bluff_rate` (river big-bets shown at showdown with no pair+ on 7-card hand)

## Build Canonical Turn-20 Pack

Create a fixed, stratified pack for repeatable acceptance runs:

```powershell
python .\4_LLM_Bridge\build_canonical_pack.py `
  --spot-dir .\3_Hand_Histories\spot_pack_runs\20260224_202331\spots `
  --output-dir .\4_LLM_Bridge\examples\canonical_turn20 `
  --count 20 `
  --streets turn `
  --seed 4090 `
  --benchmark-mode
```

Mixed-street canonical example:

```powershell
python .\4_LLM_Bridge\build_canonical_pack.py `
  --spot-dir .\3_Hand_Histories\spot_pack_runs\20260224_202331\spots `
  --output-dir .\4_LLM_Bridge\examples\canonical_turn_river20 `
  --count 20 `
  --streets turn river `
  --min-per-street 6 `
  --seed 4090 `
  --benchmark-mode
```

Outputs:

- `canonical_manifest.json`
- `canonical_report.json`
- `spots/spot_XX.*.json`

## Acceptance Gate (CI-Style)

Run one command for preflight filtering, lock benchmarking, EV margin calibration, and pass/fail:

```powershell
python .\4_LLM_Bridge\run_acceptance_gate.py `
  --canonical-manifest .\4_LLM_Bridge\examples\canonical_turn20\canonical_manifest.json `
  --preset local_qwen3_coder_30b `
  --calls-per-spot 1 `
  --ev-keep-margin 0.001 `
  --calibrate-noise-runs 3 `
  --output .\4_LLM_Bridge\examples\canonical_turn20\acceptance_summary.json
```

Profile-conditioned run (inject `spot.meta.opponent_profile`):

```powershell
python .\4_LLM_Bridge\run_acceptance_gate.py `
  --spot-dir .\4_LLM_Bridge\examples\canonical_turn20\profiled_spots `
  --preset local_qwen3_coder_30b `
  --ev-keep-margin 0.001 `
  --use-spot-opponent-profile `
  --output .\4_LLM_Bridge\examples\canonical_turn20\acceptance_summary.profiled.json
```

Conditional multi-node run (enable only when rollout class tags match):

```powershell
python .\4_LLM_Bridge\run_acceptance_gate.py `
  --spot-dir .\4_LLM_Bridge\examples\canonical_turn20\spots `
  --preset local_qwen3_coder_30b `
  --ev-keep-margin 0.001 `
  --use-spot-opponent-profile `
  --multi-node-classes turn_probe_punish `
  --output .\4_LLM_Bridge\examples\canonical_turn20\acceptance_summary.multinode.json
```

## Phase 10 Backtest Runner (A/B/C)

Run routing comparison modes on the same spot set:

- `baseline_gto`: direct `shark_cli` baseline solve (no LLM lock).
- `class1_live_shadow23`: production routing policy (Class 1 live, Class 2/3 shadow).
- `full_multi_node_benchmark`: benchmark override with full multi-node enabled.

```powershell
python .\4_LLM_Bridge\run_true_backtest.py `
  --spot-dir .\4_LLM_Bridge\examples\canonical_turn20\multinode_class1_spots `
  --spot-dir .\4_LLM_Bridge\examples\canonical_river20\spots `
  --preset local_qwen3_coder_30b `
  --modes baseline_gto class1_live_shadow23 full_multi_node_benchmark `
  --ev-keep-margin 0.001 `
  --seed 4090 `
  --output .\4_LLM_Bridge\examples\backtest.abc.json
```

Primary outputs in `summaries`:

- `bb100_avg`
- `ev_delta_avg_pct`
- `fallback_rate`
- `keep_rate`
- `latency_p50_sec`
- `latency_p95_sec`

Analyze River shadow dumps vs full multi-node challenger:

```powershell
python .\4_LLM_Bridge\analyze_shadow_dumps.py `
  --backtest-report .\4_LLM_Bridge\examples\backtest.abc.ps1.json `
  --output .\4_LLM_Bridge\examples\backtest.shadow_diagnostics.json
```

Key outputs:

- `challenger_worse_count` / `challenger_worse_rate`
- `top_worse_spots` with delta and bb/100 gaps
- `texture_summary` to identify board classes where challenger leaks EV

Gate criteria defaults:

- `fallback_rate <= 0.05`
- `lock_applied_rate >= 0.95`
- `keep_rate > 0`

The script exits non-zero on failure and writes a summary JSON with criteria, metrics, and preflight details.

Repository-level CI helper (PowerShell):

```powershell
.\scripts\test_ci.ps1 `
  -Preset local_qwen3_coder_30b `
  -EvKeepMargin 0.001
```

`test_ci.ps1` starts missing local services (Ollama + bridge), runs the acceptance gate, and exits `1` if any gate criterion fails.

## Tag Rollout Classes

Tag spots into the three rollout classes:

```powershell
python .\4_LLM_Bridge\tag_spot_classes.py `
  --spot-dir .\4_LLM_Bridge\examples\canonical_turn20\profiled_spots `
  --write-spot-meta `
  --output-manifest .\4_LLM_Bridge\examples\canonical_turn20\tagged_manifest.profiled.json `
  --summary .\4_LLM_Bridge\examples\canonical_turn20\tagged_summary.profiled.json
```

Classes:

- `turn_probe_punish`
- `river_bigbet_overfold_punish`
- `river_underbluff_defense`

## Batch Benchmarking (Provider-Aware Caps)

`benchmark_models.py` uses provider-aware call caps:

- Cloud/OpenAI presets: hard cap `10`
- Local presets: higher configurable cap via `--max-calls-local`

```powershell
python .\4_LLM_Bridge\benchmark_models.py `
  --spot .\4_LLM_Bridge\examples\spot.sample.json `
  --presets local_gpt_oss_20b local_qwen3_coder_30b `
  --calls-per-model 50 `
  --max-calls-local 200 `
  --output .\4_LLM_Bridge\examples\benchmark.local.json
```

The response JSON includes:

- `node_lock`: the lock payload generated by `llm_client.py`,
- `result`: the raw `shark_cli` result payload.

## Current Locking Behavior

- Root node-lock generation supports dynamic legal-action filtering from baseline `root_actions`.
- Duplicate lock actions are aggregated and frequencies are renormalized.
- Bridge performs two-pass scoring and rejects non-improving locks by selecting baseline GTO.
- Shark enforces node-lock targets by `node_id` + `street` in CFR (root and non-root).
- Baseline solve exposes `node_lock_catalog` so prompts can target known action nodes.
