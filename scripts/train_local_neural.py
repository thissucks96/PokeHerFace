#!/usr/bin/env python3
"""Train local neural policy model from frozen reference-label rows.

Safe default: validation-only. Use --train to run training.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, Dataset

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from shared_feature_contract import (
    FEATURE_CONTRACT_HASH,
    FEATURE_SCHEMA_VERSION,
    feature_contract_metadata,
    feature_vector,
)


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _normalize_action(raw: Any) -> str:
    token = str(raw or "").strip().lower()
    if not token:
        return ""
    if token.startswith("bet:"):
        token = "raise:" + token.split(":", 1)[1]
    if token == "bet":
        return "raise_small"
    if token == "all_in":
        return "all_in"
    if token.startswith("raise:"):
        return "raise"
    return token


class TeacherRowsDataset(Dataset):
    def __init__(
        self,
        rows: list[dict[str, Any]],
        action_to_index: dict[str, int],
        input_dim: int,
        split_key_field: str = "split_key",
    ) -> None:
        self.samples: list[tuple[torch.Tensor, int]] = []
        self.split_tokens: list[str] = []
        self.contract_total_rows = 0
        self.contract_matching_rows = 0
        self.contract_mismatch_rows = 0
        for row in rows:
            source_row = row.get("source_row") if isinstance(row.get("source_row"), dict) else {}
            target = source_row.get("target") if isinstance(source_row.get("target"), dict) else {}
            features = source_row.get("features") if isinstance(source_row.get("features"), dict) else {}
            source = source_row.get("source") if isinstance(source_row.get("source"), dict) else {}

            action_raw = _normalize_action(target.get("selected_action"))
            amount = _safe_float(target.get("selected_amount"), 0.0)
            pot = max(1.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 1.0))
            if action_raw == "raise":
                ratio = amount / pot if pot > 0 else 0.0
                if ratio >= 1.0:
                    action = "raise_big"
                else:
                    action = "raise_small"
            elif action_raw == "raise_small" or action_raw == "raise_big":
                action = action_raw
            else:
                action = action_raw

            if action not in action_to_index:
                continue

            self.contract_total_rows += 1
            expected_contract = feature_contract_metadata(
                source=source,
                features=features,
                input_dim=input_dim,
            )
            row_contract = row.get("feature_contract") if isinstance(row.get("feature_contract"), dict) else {}
            if row_contract:
                schema_ok = str(row_contract.get("schema_version") or "") == FEATURE_SCHEMA_VERSION
                contract_ok = str(row_contract.get("contract_hash") or "") == FEATURE_CONTRACT_HASH
                key_ok = str(row_contract.get("feature_key_hash") or "") == str(expected_contract.get("feature_key_hash") or "")
                if schema_ok and contract_ok and key_ok:
                    self.contract_matching_rows += 1
                else:
                    self.contract_mismatch_rows += 1
            x = torch.tensor(feature_vector(source=source, features=features, input_dim=input_dim), dtype=torch.float32)
            y = action_to_index[action]
            self.samples.append((x, y))
            split_token = str(row.get(split_key_field) or row.get("split_key") or row.get("row_id") or "").strip()
            if not split_token:
                split_token = hashlib.sha256(json.dumps(row, sort_keys=True).encode("utf-8")).hexdigest()
            self.split_tokens.append(split_token)

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, int]:
        return self.samples[idx]

class PolicyMLP(nn.Module):
    def __init__(self, input_dim: int, hidden_dim: int, num_layers: int, dropout: float, output_dim: int) -> None:
        super().__init__()
        layers: list[nn.Module] = []
        in_dim = input_dim
        for _ in range(max(1, num_layers)):
            layers.append(nn.Linear(in_dim, hidden_dim))
            layers.append(nn.ReLU())
            if dropout > 0:
                layers.append(nn.Dropout(dropout))
            in_dim = hidden_dim
        layers.append(nn.Linear(in_dim, output_dim))
        self.net = nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


def _load_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.exists():
        return rows
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                rows.append(item)
    return rows


def _split_indices_random(total: int, train_split: float, seed: int) -> tuple[list[int], list[int]]:
    idx = list(range(total))
    keyed = []
    for i in idx:
        key = f"rnd|{seed}|{i}"
        value = int(hashlib.sha256(key.encode("utf-8")).hexdigest()[:8], 16)
        keyed.append((value, i))
    keyed.sort(key=lambda x: x[0])
    ordered = [i for _, i in keyed]
    pivot = int(max(1, min(total - 1, round(total * train_split)))) if total >= 2 else total
    return ordered[:pivot], ordered[pivot:]


def _split_indices_hash(split_tokens: list[str], train_split: float, seed: int) -> tuple[list[int], list[int]]:
    train_idx: list[int] = []
    val_idx: list[int] = []
    ratio = max(0.0, min(1.0, float(train_split)))
    for i, token in enumerate(split_tokens):
        digest = hashlib.sha256(f"split|{seed}|{token}".encode("utf-8")).hexdigest()
        bucket = int(digest[:8], 16) / float(0xFFFFFFFF)
        if bucket < ratio:
            train_idx.append(i)
        else:
            val_idx.append(i)

    total = len(split_tokens)
    if total >= 2:
        if not train_idx and val_idx:
            train_idx.append(val_idx.pop(0))
        if not val_idx and train_idx:
            val_idx.append(train_idx.pop(-1))
    return train_idx, val_idx


def _accuracy(model: nn.Module, loader: DataLoader, device: torch.device) -> float:
    total = 0
    correct = 0
    model.eval()
    with torch.no_grad():
        for x, y in loader:
            x = x.to(device)
            y = y.to(device)
            logits = model(x)
            pred = torch.argmax(logits, dim=1)
            total += int(y.numel())
            correct += int((pred == y).sum().item())
    return (correct / total) if total > 0 else 0.0


def main() -> int:
    parser = argparse.ArgumentParser(description="Train local neural policy from frozen reference-label rows.")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/configs/train_config.local.json"),
        help="Path to train config JSON.",
    )
    parser.add_argument(
        "--dataset-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"),
        help="Input JSONL of frozen reference labels.",
    )
    parser.add_argument("--train", action="store_true", help="Run training. Default is validation-only.")
    args = parser.parse_args()

    cfg_path = args.config.resolve()
    if not cfg_path.exists():
        print(json.dumps({"ok": False, "error": f"missing_config:{cfg_path}"}))
        return 2
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))

    data_cfg = cfg.get("data", {}) if isinstance(cfg.get("data"), dict) else {}
    model_cfg = cfg.get("model", {}) if isinstance(cfg.get("model"), dict) else {}
    train_cfg = cfg.get("training", {}) if isinstance(cfg.get("training"), dict) else {}
    out_cfg = cfg.get("outputs", {}) if isinstance(cfg.get("outputs"), dict) else {}

    dataset_path = args.dataset_jsonl.resolve()
    rows = _load_rows(dataset_path)
    action_space = model_cfg.get("output_actions", ["fold", "check", "call", "raise_small", "raise_big", "all_in"])
    action_to_index = {str(a): i for i, a in enumerate(action_space)}
    input_dim = max(16, _safe_int(model_cfg.get("input_dim"), 128))
    split_key_field = str(data_cfg.get("split_key_field") or "split_key").strip() or "split_key"
    split_method = str(data_cfg.get("split_method") or "hash_split_key").strip().lower()

    summary: dict[str, Any] = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "config_path": str(cfg_path),
        "dataset_path": str(dataset_path),
        "rows_total": len(rows),
        "action_space": action_space,
        "mode": "train" if args.train else "validate_only",
        "feature_contract_expected": {
            "schema_version": FEATURE_SCHEMA_VERSION,
            "contract_hash": FEATURE_CONTRACT_HASH,
            "input_dim": input_dim,
        },
    }

    if not rows:
        summary.update({"ok": False, "ready_for_training": False, "reason": "dataset_missing_or_empty"})
        print(json.dumps(summary, indent=2))
        return 0

    dataset_full = TeacherRowsDataset(
        rows=rows,
        action_to_index=action_to_index,
        input_dim=input_dim,
        split_key_field=split_key_field,
    )
    if len(dataset_full) == 0:
        summary.update({"ok": False, "ready_for_training": False, "reason": "no_rows_with_mapped_actions"})
        print(json.dumps(summary, indent=2))
        return 0

    train_split = _safe_float(data_cfg.get("train_split"), 0.9)
    split_seed = _safe_int(data_cfg.get("seed"), 4090)
    if split_method == "random":
        train_idx, val_idx = _split_indices_random(
            total=len(dataset_full),
            train_split=train_split,
            seed=split_seed,
        )
    else:
        train_idx, val_idx = _split_indices_hash(
            split_tokens=dataset_full.split_tokens,
            train_split=train_split,
            seed=split_seed,
        )
    train_set = torch.utils.data.Subset(dataset_full, train_idx)
    val_set = torch.utils.data.Subset(dataset_full, val_idx) if val_idx else None
    batch_size = max(8, _safe_int(train_cfg.get("batch_size"), 512))
    train_loader = DataLoader(train_set, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_set, batch_size=batch_size, shuffle=False) if val_set else None

    summary.update(
        {
            "ok": True,
            "ready_for_training": True,
            "rows_mapped": len(dataset_full),
            "feature_contract_rows_checked": int(dataset_full.contract_total_rows),
            "feature_contract_rows_matching": int(dataset_full.contract_matching_rows),
            "feature_contract_rows_mismatching": int(dataset_full.contract_mismatch_rows),
            "train_rows": len(train_set),
            "val_rows": len(val_set) if val_set else 0,
            "split_method": split_method,
            "split_key_field": split_key_field,
            "split_seed": split_seed,
        }
    )

    if not args.train:
        print(json.dumps(summary, indent=2))
        return 0

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = PolicyMLP(
        input_dim=input_dim,
        hidden_dim=max(16, _safe_int(model_cfg.get("hidden_dim"), 256)),
        num_layers=max(1, _safe_int(model_cfg.get("num_layers"), 3)),
        dropout=max(0.0, min(0.8, _safe_float(model_cfg.get("dropout"), 0.1))),
        output_dim=len(action_space),
    ).to(device)
    optimizer = optim.AdamW(
        model.parameters(),
        lr=max(1e-6, _safe_float(train_cfg.get("learning_rate"), 3e-4)),
        weight_decay=max(0.0, _safe_float(train_cfg.get("weight_decay"), 1e-5)),
    )
    criterion = nn.CrossEntropyLoss()
    epochs = max(1, _safe_int(train_cfg.get("epochs"), 30))
    clip_norm = max(0.0, _safe_float(train_cfg.get("gradient_clip_norm"), 1.0))

    history: list[dict[str, Any]] = []
    for epoch in range(1, epochs + 1):
        model.train()
        epoch_loss = 0.0
        batches = 0
        for x, y in train_loader:
            x = x.to(device)
            y = y.to(device)
            optimizer.zero_grad(set_to_none=True)
            logits = model(x)
            loss = criterion(logits, y)
            loss.backward()
            if clip_norm > 0:
                nn.utils.clip_grad_norm_(model.parameters(), clip_norm)
            optimizer.step()
            epoch_loss += float(loss.item())
            batches += 1
        train_loss = epoch_loss / max(1, batches)
        train_acc = _accuracy(model, train_loader, device)
        val_acc = _accuracy(model, val_loader, device) if val_loader else 0.0
        history.append(
            {
                "epoch": epoch,
                "train_loss": train_loss,
                "train_acc": train_acc,
                "val_acc": val_acc,
            }
        )

    checkpoints_dir = Path(str(out_cfg.get("checkpoints_dir", "2_Neural_Brain/local_pipeline/artifacts/checkpoints"))).resolve()
    reports_dir = Path(str(out_cfg.get("reports_dir", "2_Neural_Brain/local_pipeline/reports"))).resolve()
    checkpoints_dir.mkdir(parents=True, exist_ok=True)
    reports_dir.mkdir(parents=True, exist_ok=True)
    model_name = str(model_cfg.get("name") or "neural_policy_v1")
    ckpt_path = checkpoints_dir / f"{model_name}_last.pt"
    report_path = reports_dir / f"{model_name}_train_report.json"

    torch.save(
        {
            "model_state_dict": model.state_dict(),
            "action_space": action_space,
            "input_dim": input_dim,
            "feature_schema_version": FEATURE_SCHEMA_VERSION,
            "feature_contract_hash": FEATURE_CONTRACT_HASH,
            "history": history,
        },
        ckpt_path,
    )
    summary.update(
        {
            "device": str(device),
            "epochs": epochs,
            "checkpoint_path": str(ckpt_path),
            "report_path": str(report_path),
            "final_train_acc": history[-1]["train_acc"] if history else 0.0,
            "final_val_acc": history[-1]["val_acc"] if history else 0.0,
        }
    )
    report_path.write_text(json.dumps({"summary": summary, "history": history}, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
