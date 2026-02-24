#!/usr/bin/env python
"""Test client: POST spot payload to local bridge server and save solve result."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import requests

def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")

def main() -> int:
    parser = argparse.ArgumentParser(description="POST a spot payload to bridge_server and save solve response.")
    parser.add_argument("--input", required=True, help="Path to spot JSON input.")
    parser.add_argument("--output", required=True, help="Path to output server response JSON.")
    parser.add_argument(
        "--endpoint",
        default="http://127.0.0.1:8000/solve",
        help="Bridge solve endpoint URL (default: http://127.0.0.1:8000/solve).",
    )
    parser.add_argument("--timeout", type=float, default=600.0, help="HTTP timeout in seconds.")
    parser.add_argument("--solver-timeout", type=int, default=900, help="shark_cli timeout passed to server.")
    parser.add_argument("--verbose", action="store_true", help="Request non-quiet solver mode.")
    parser.add_argument(
        "--compute-baseline-delta",
        action="store_true",
        help="Request a second no-lock solve to compute exploitability delta.",
    )
    parser.add_argument(
        "--llm-preset",
        default="mock",
        help=(
            "LLM preset selector: mock | openai_fast | openai_mini | openai_52 | "
            "local_gpt_oss_20b | local_qwen3_coder_30b | local_deepseek_coder_33b"
        ),
    )
    parser.add_argument("--llm-provider", help="Override provider: mock | openai | local")
    parser.add_argument("--llm-model", help="Override model name for selected provider.")
    parser.add_argument("--llm-base-url", help="Override base URL for provider endpoint.")
    parser.add_argument("--llm-temperature", type=float, help="Override LLM temperature.")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        print(f"Input file not found: {input_path}", file=sys.stderr)
        return 2

    spot_payload = load_json(input_path)
    request_payload = {
        "spot": spot_payload,
        "timeout_sec": args.solver_timeout,
        "quiet": not args.verbose,
        "compute_baseline_delta": args.compute_baseline_delta,
        "llm": {
            "preset": args.llm_preset,
        },
    }
    if args.llm_provider:
        request_payload["llm"]["provider"] = args.llm_provider
    if args.llm_model:
        request_payload["llm"]["model"] = args.llm_model
    if args.llm_base_url:
        request_payload["llm"]["base_url"] = args.llm_base_url
    if args.llm_temperature is not None:
        request_payload["llm"]["temperature"] = args.llm_temperature

    response = requests.post(args.endpoint, json=request_payload, timeout=args.timeout)
    response.raise_for_status()

    payload = response.json()
    save_json(output_path, payload)

    print(f"Solve response JSON written: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
