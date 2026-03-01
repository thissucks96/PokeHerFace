#!/usr/bin/env python3
"""Bootstrap local train-your-own neural workspace directories/config.

This script is intentionally lightweight and local-only. It does not download
external models and it does not call cloud APIs.
"""

from __future__ import annotations

import json
from pathlib import Path


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    workspace = repo_root / "2_Neural_Brain" / "local_pipeline"

    dirs = [
        workspace / "configs",
        workspace / "data" / "raw_spots",
        workspace / "data" / "processed",
        workspace / "artifacts" / "checkpoints",
        workspace / "artifacts" / "exports",
        workspace / "reports",
        workspace / "tensorboard",
    ]
    for d in dirs:
        d.mkdir(parents=True, exist_ok=True)

    config_pairs = [
        ("train_config.template.json", "train_config.local.json"),
        ("dataset_config.template.json", "dataset_config.local.json"),
        ("eval_gates.template.json", "eval_gates.local.json"),
    ]
    created_configs: list[str] = []
    for template_name, local_name in config_pairs:
        template = workspace / "configs" / template_name
        local_cfg = workspace / "configs" / local_name
        if template.exists() and not local_cfg.exists():
            local_cfg.write_text(template.read_text(encoding="utf-8"), encoding="utf-8")
            created_configs.append(str(local_cfg))

    summary = {
        "workspace": str(workspace),
        "created_dirs": [str(d) for d in dirs],
        "created_local_configs": created_configs,
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
