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

    template = workspace / "configs" / "train_config.template.json"
    local_cfg = workspace / "configs" / "train_config.local.json"
    if template.exists() and not local_cfg.exists():
        local_cfg.write_text(template.read_text(encoding="utf-8"), encoding="utf-8")

    summary = {
        "workspace": str(workspace),
        "created_dirs": [str(d) for d in dirs],
        "local_config": str(local_cfg),
        "local_config_created": local_cfg.exists(),
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
