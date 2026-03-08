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
import torch.nn.functional as F
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

PASSIVE_ACTIONS = ["fold", "call", "check"]
AGGRESSIVE_ACTIONS = ["raise_small", "raise_big", "all_in"]


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
        action_space: list[str],
        split_key_field: str = "split_key",
    ) -> None:
        self.samples: list[tuple[torch.Tensor, int, torch.Tensor, torch.Tensor]] = []
        self.split_tokens: list[str] = []
        self.contract_total_rows = 0
        self.contract_matching_rows = 0
        self.contract_mismatch_rows = 0
        self.distribution_rows = 0
        self.fallback_one_hot_rows = 0
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
            distribution_tensor, used_distribution, legal_mask = _distribution_tensor(
                target=target,
                features=features,
                action_to_index=action_to_index,
                action_space=action_space,
                selected_action_index=y,
            )
            if used_distribution:
                self.distribution_rows += 1
            else:
                self.fallback_one_hot_rows += 1
            self.samples.append((x, y, distribution_tensor, legal_mask))
            split_token = str(row.get(split_key_field) or row.get("split_key") or row.get("row_id") or "").strip()
            if not split_token:
                split_token = hashlib.sha256(json.dumps(row, sort_keys=True).encode("utf-8")).hexdigest()
            self.split_tokens.append(split_token)

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, int, torch.Tensor, torch.Tensor]:
        return self.samples[idx]

class PolicyMLP(nn.Module):
    def __init__(
        self,
        input_dim: int,
        hidden_dim: int,
        num_layers: int,
        dropout: float,
        output_dim: int,
        architecture: str = "flat",
    ) -> None:
        super().__init__()
        self.architecture = architecture
        layers: list[nn.Module] = []
        in_dim = input_dim
        for _ in range(max(1, num_layers)):
            layers.append(nn.Linear(in_dim, hidden_dim))
            layers.append(nn.ReLU())
            if dropout > 0:
                layers.append(nn.Dropout(dropout))
            in_dim = hidden_dim
        self.trunk = nn.Sequential(*layers)
        if architecture == "hierarchical":
            self.head_posture = nn.Linear(in_dim, 2)
            self.head_passive = nn.Linear(in_dim, len(PASSIVE_ACTIONS))
            self.head_aggro = nn.Linear(in_dim, len(AGGRESSIVE_ACTIONS))
            self.head = None
        else:
            self.head = nn.Linear(in_dim, output_dim)
            self.head_posture = None
            self.head_passive = None
            self.head_aggro = None

    def forward(self, x: torch.Tensor) -> torch.Tensor | dict[str, torch.Tensor]:
        hidden = self.trunk(x)
        if self.architecture == "hierarchical":
            return {
                "posture": self.head_posture(hidden),
                "passive": self.head_passive(hidden),
                "aggressive": self.head_aggro(hidden),
            }
        return self.head(hidden)


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


def _bucketize_action(action_raw: Any, amount: Any, pot: float) -> str:
    action_token = _normalize_action(action_raw)
    amt = _safe_float(amount, 0.0)
    if action_token == "raise":
        ratio = amt / pot if pot > 0 else 0.0
        return "raise_big" if ratio >= 1.0 else "raise_small"
    if action_token in {"raise_small", "raise_big"}:
        return action_token
    return action_token


def _distribution_tensor(
    target: dict[str, Any],
    features: dict[str, Any],
    action_to_index: dict[str, int],
    action_space: list[str],
    selected_action_index: int,
) -> tuple[torch.Tensor, bool, torch.Tensor]:
    probs = [0.0 for _ in action_space]
    legal = [False for _ in action_space]
    pot = max(1.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 1.0))
    distribution = target.get("distribution")
    used_distribution = False

    if isinstance(distribution, list) and distribution:
        for item in distribution:
            if not isinstance(item, dict):
                continue
            mapped = _bucketize_action(item.get("action"), item.get("amount"), pot)
            if mapped not in action_to_index:
                continue
            legal[action_to_index[mapped]] = True
            freq = max(0.0, _safe_float(item.get("frequency"), 0.0))
            probs[action_to_index[mapped]] += freq
        total = sum(probs)
        if total > 0.0:
            probs = [p / total for p in probs]
            used_distribution = True

    if not used_distribution:
        probs[selected_action_index] = 1.0
    if not any(legal):
        legal = [True for _ in action_space]
    return (
        torch.tensor(probs, dtype=torch.float32),
        used_distribution,
        torch.tensor(legal, dtype=torch.bool),
    )


def _apply_legal_action_mask(logits: torch.Tensor, legal_mask: torch.Tensor) -> torch.Tensor:
    if legal_mask.dtype != torch.bool:
        legal_mask = legal_mask.to(dtype=torch.bool)
    all_illegal = ~legal_mask.any(dim=1, keepdim=True)
    effective_mask = torch.where(all_illegal, torch.ones_like(legal_mask, dtype=torch.bool), legal_mask)
    return logits.masked_fill(~effective_mask, -1e9)


def _hierarchical_mappings(action_to_index: dict[str, int]) -> dict[str, Any]:
    passive_global = [action_to_index[name] for name in PASSIVE_ACTIONS if name in action_to_index]
    aggressive_global = [action_to_index[name] for name in AGGRESSIVE_ACTIONS if name in action_to_index]
    return {
        "passive_global": passive_global,
        "aggressive_global": aggressive_global,
        "passive_local": {global_idx: local_idx for local_idx, global_idx in enumerate(passive_global)},
        "aggressive_local": {global_idx: local_idx for local_idx, global_idx in enumerate(aggressive_global)},
    }


def _hierarchical_targets(
    targets: torch.Tensor,
    mappings: dict[str, Any],
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    posture_targets = torch.ones_like(targets)
    passive_mask = torch.zeros_like(targets, dtype=torch.bool)
    aggressive_mask = torch.zeros_like(targets, dtype=torch.bool)
    passive_local = torch.zeros_like(targets)
    aggressive_local = torch.zeros_like(targets)

    for global_idx, local_idx in mappings["passive_local"].items():
        rows = targets == global_idx
        posture_targets = torch.where(rows, torch.zeros_like(posture_targets), posture_targets)
        passive_mask |= rows
        passive_local = torch.where(rows, torch.full_like(passive_local, local_idx), passive_local)

    for global_idx, local_idx in mappings["aggressive_local"].items():
        rows = targets == global_idx
        aggressive_mask |= rows
        aggressive_local = torch.where(rows, torch.full_like(aggressive_local, local_idx), aggressive_local)

    return posture_targets, passive_mask, aggressive_mask, passive_local, aggressive_local


def _hierarchical_legal_masks(
    legal_mask: torch.Tensor,
    mappings: dict[str, Any],
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    passive_global = mappings["passive_global"]
    aggressive_global = mappings["aggressive_global"]
    passive_mask = legal_mask[:, passive_global]
    aggressive_mask = legal_mask[:, aggressive_global]
    posture_mask = torch.stack(
        [
            passive_mask.any(dim=1),
            aggressive_mask.any(dim=1),
        ],
        dim=1,
    )
    return posture_mask, passive_mask, aggressive_mask


def _weighted_ce_loss(
    logits: torch.Tensor,
    targets: torch.Tensor,
    class_weight_tensor: torch.Tensor | None,
) -> torch.Tensor:
    losses = F.cross_entropy(logits, targets, reduction="none")
    if class_weight_tensor is None:
        return losses.mean()
    sample_weights = class_weight_tensor.gather(0, targets)
    denom = sample_weights.sum().clamp_min(1e-12)
    return (losses * sample_weights).sum() / denom


def _hierarchical_reconstruct_logits(
    outputs: dict[str, torch.Tensor],
    legal_mask: torch.Tensor,
    action_space: list[str],
    action_to_index: dict[str, int],
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    mappings = _hierarchical_mappings(action_to_index)
    posture_mask, passive_mask, aggressive_mask = _hierarchical_legal_masks(legal_mask, mappings)
    posture_logits = _apply_legal_action_mask(outputs["posture"], posture_mask)
    passive_logits = _apply_legal_action_mask(outputs["passive"], passive_mask)
    aggressive_logits = _apply_legal_action_mask(outputs["aggressive"], aggressive_mask)

    posture_pred = torch.argmax(posture_logits, dim=1)
    final_logits = torch.full(
        (legal_mask.shape[0], len(action_space)),
        -1e9,
        dtype=posture_logits.dtype,
        device=posture_logits.device,
    )

    passive_rows = posture_pred == 0
    aggressive_rows = posture_pred == 1
    if passive_rows.any():
        for local_idx, global_idx in enumerate(mappings["passive_global"]):
            final_logits[passive_rows, global_idx] = passive_logits[passive_rows, local_idx]
    if aggressive_rows.any():
        for local_idx, global_idx in enumerate(mappings["aggressive_global"]):
            final_logits[aggressive_rows, global_idx] = aggressive_logits[aggressive_rows, local_idx]
    return final_logits, {
        "posture_logits": posture_logits,
        "passive_logits": passive_logits,
        "aggressive_logits": aggressive_logits,
        "posture_pred": posture_pred,
        "mappings": mappings,
    }


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


def _predict_logits(
    model: nn.Module,
    x: torch.Tensor,
    legal_mask: torch.Tensor,
    action_space: list[str],
    action_to_index: dict[str, int],
    architecture: str,
) -> tuple[torch.Tensor, dict[str, Any] | None]:
    outputs = model(x)
    if architecture == "hierarchical":
        logits, aux = _hierarchical_reconstruct_logits(
            outputs=outputs,
            legal_mask=legal_mask,
            action_space=action_space,
            action_to_index=action_to_index,
        )
        return logits, aux
    return _apply_legal_action_mask(outputs, legal_mask), None


def _accuracy(
    model: nn.Module,
    loader: DataLoader,
    device: torch.device,
    action_space: list[str],
    action_to_index: dict[str, int],
    architecture: str,
) -> float:
    total = 0
    correct = 0
    model.eval()
    with torch.no_grad():
        for x, y, _dist, legal_mask in loader:
            x = x.to(device)
            y = y.to(device)
            legal_mask = legal_mask.to(device)
            logits, _aux = _predict_logits(
                model=model,
                x=x,
                legal_mask=legal_mask,
                action_space=action_space,
                action_to_index=action_to_index,
                architecture=architecture,
            )
            pred = torch.argmax(logits, dim=1)
            total += int(y.numel())
            correct += int((pred == y).sum().item())
    return (correct / total) if total > 0 else 0.0


def _collect_class_metrics(
    model: nn.Module,
    loader: DataLoader | None,
    device: torch.device,
    action_space: list[str],
    action_to_index: dict[str, int],
    architecture: str,
) -> dict[str, Any]:
    labels = list(action_space)
    num_classes = len(labels)
    confusion = [[0 for _ in range(num_classes)] for _ in range(num_classes)]
    support = [0 for _ in range(num_classes)]
    predicted = [0 for _ in range(num_classes)]
    total = 0
    correct = 0

    if loader is None:
        return {
            "overall_acc": 0.0,
            "per_class": [],
            "prediction_distribution": {label: 0 for label in labels},
            "confusion_matrix": {"labels": labels, "rows": confusion},
        }

    model.eval()
    with torch.no_grad():
        for x, y, _dist, legal_mask in loader:
            x = x.to(device)
            y = y.to(device)
            legal_mask = legal_mask.to(device)
            logits, _aux = _predict_logits(
                model=model,
                x=x,
                legal_mask=legal_mask,
                action_space=action_space,
                action_to_index=action_to_index,
                architecture=architecture,
            )
            preds = torch.argmax(logits, dim=1)
            for y_i, p_i in zip(y.tolist(), preds.tolist()):
                total += 1
                support[y_i] += 1
                predicted[p_i] += 1
                confusion[y_i][p_i] += 1
                if y_i == p_i:
                    correct += 1

    per_class: list[dict[str, Any]] = []
    prediction_distribution: dict[str, int] = {}
    for idx, label in enumerate(labels):
        true_positive = confusion[idx][idx]
        row_support = support[idx]
        predicted_total = predicted[idx]
        recall = (true_positive / row_support) if row_support else None
        precision = (true_positive / predicted_total) if predicted_total else None
        per_class.append(
            {
                "label": label,
                "support": row_support,
                "predicted": predicted_total,
                "true_positive": true_positive,
                "recall": recall,
                "precision": precision,
            }
        )
        prediction_distribution[label] = predicted_total

    return {
        "overall_acc": (correct / total) if total > 0 else 0.0,
        "per_class": per_class,
        "prediction_distribution": prediction_distribution,
        "confusion_matrix": {"labels": labels, "rows": confusion},
    }


def _weighted_kl_divergence(
    log_probs: torch.Tensor,
    target_dist: torch.Tensor,
    class_weights: torch.Tensor | None,
) -> torch.Tensor:
    safe_target = target_dist.clamp_min(1e-12)
    kl_terms = target_dist * (safe_target.log() - log_probs)
    if class_weights is not None:
        kl_terms = kl_terms * class_weights.unsqueeze(0)
    return kl_terms.sum(dim=1).mean()


def _passive_fold_call_rows(
    legal_mask: torch.Tensor,
    action_to_index: dict[str, int],
) -> torch.Tensor:
    fold_idx = action_to_index.get("fold")
    call_idx = action_to_index.get("call")
    if fold_idx is None or call_idx is None:
        return torch.zeros(legal_mask.shape[0], dtype=torch.bool, device=legal_mask.device)
    allowed = legal_mask.sum(dim=1) == 2
    fold_legal = legal_mask[:, fold_idx]
    call_legal = legal_mask[:, call_idx]
    return allowed & fold_legal & call_legal


def _scalar_loss(
    logits: torch.Tensor,
    targets: torch.Tensor,
    legal_mask: torch.Tensor,
    action_to_index: dict[str, int],
    class_weight_tensor: torch.Tensor | None,
    passive_subset_weighting: str,
) -> torch.Tensor:
    losses = F.cross_entropy(logits, targets, reduction="none")
    sample_weights = torch.ones_like(losses)
    if class_weight_tensor is not None:
        sample_weights = class_weight_tensor.gather(0, targets)
    if passive_subset_weighting == "balanced_fold_call":
        passive_rows = _passive_fold_call_rows(legal_mask=legal_mask, action_to_index=action_to_index)
        sample_weights = torch.where(passive_rows, torch.ones_like(sample_weights), sample_weights)
    denom = sample_weights.sum().clamp_min(1e-12)
    return (losses * sample_weights).sum() / denom


def _dataset_targets(dataset: Dataset[Any]) -> list[int]:
    if isinstance(dataset, torch.utils.data.Subset):
        base = dataset.dataset
        indices = list(dataset.indices)
        if hasattr(base, "samples"):
            return [int(base.samples[i][1]) for i in indices]
    if hasattr(dataset, "samples"):
        return [int(sample[1]) for sample in dataset.samples]
    targets: list[int] = []
    for i in range(len(dataset)):
        _, y, _dist, _mask = dataset[i]
        targets.append(int(y))
    return targets


def _build_class_weights(
    targets: list[int],
    num_classes: int,
    mode: str,
    cap: float,
) -> list[float] | None:
    normalized_mode = str(mode or "none").strip().lower()
    if normalized_mode in {"", "none", "off", "disabled"}:
        return None
    if normalized_mode != "inverse_frequency":
        raise ValueError(f"unsupported_class_weighting:{mode}")

    counts = [0 for _ in range(num_classes)]
    for target in targets:
        if 0 <= target < num_classes:
            counts[target] += 1

    positive_counts = [count for count in counts if count > 0]
    if not positive_counts:
        return None

    max_count = max(positive_counts)
    weights: list[float] = []
    for count in counts:
        if count <= 0:
            weights.append(0.0)
            continue
        weight = max_count / float(count)
        if cap > 0:
            weight = min(weight, cap)
        weights.append(weight)
    return weights


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
        default=None,
        help="Input JSONL for the training split. Defaults to config data.train_jsonl or the frozen corpus.",
    )
    parser.add_argument(
        "--holdout-jsonl",
        type=Path,
        default=None,
        help="Optional holdout JSONL for explicit evaluation. Defaults to config data.holdout_jsonl when present.",
    )
    parser.add_argument(
        "--class-weighting",
        default=None,
        help="Class weighting mode for scalar CE training. Supported: none, inverse_frequency.",
    )
    parser.add_argument(
        "--passive-subset-weighting",
        default=None,
        help="Optional scalar-loss override for legal passive subsets. Supported: none, balanced_fold_call.",
    )
    parser.add_argument(
        "--target-mode",
        default=None,
        help="Training target mode. Supported: scalar, distribution.",
    )
    parser.add_argument(
        "--architecture",
        default=None,
        help="Model architecture. Supported: flat, hierarchical.",
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

    dataset_default = Path(
        str(
            data_cfg.get("train_jsonl")
            or "2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl"
        )
    )
    holdout_default_raw = str(data_cfg.get("holdout_jsonl") or "").strip()
    dataset_path = (args.dataset_jsonl or dataset_default).resolve()
    holdout_path = (args.holdout_jsonl or Path(holdout_default_raw)).resolve() if holdout_default_raw or args.holdout_jsonl else None
    rows = _load_rows(dataset_path)
    holdout_rows = _load_rows(holdout_path) if holdout_path else []
    action_space = model_cfg.get("output_actions", ["fold", "check", "call", "raise_small", "raise_big", "all_in"])
    action_to_index = {str(a): i for i, a in enumerate(action_space)}
    input_dim = max(16, _safe_int(model_cfg.get("input_dim"), 128))
    split_key_field = str(data_cfg.get("split_key_field") or "split_key").strip() or "split_key"
    split_method = str(data_cfg.get("split_method") or "hash_split_key").strip().lower()
    target_mode = str(args.target_mode or train_cfg.get("target_mode") or "scalar").strip().lower()
    architecture = str(args.architecture or model_cfg.get("architecture") or "flat").strip().lower()
    if target_mode not in {"scalar", "distribution"}:
        print(json.dumps({"ok": False, "ready_for_training": False, "reason": f"unsupported_target_mode:{target_mode}"}))
        return 2
    if architecture not in {"flat", "hierarchical"}:
        print(json.dumps({"ok": False, "ready_for_training": False, "reason": f"unsupported_architecture:{architecture}"}))
        return 2
    if architecture == "hierarchical" and target_mode != "scalar":
        print(json.dumps({"ok": False, "ready_for_training": False, "reason": "hierarchical_requires_scalar_targets"}))
        return 2

    summary: dict[str, Any] = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "config_path": str(cfg_path),
        "dataset_path": str(dataset_path),
        "holdout_path": str(holdout_path) if holdout_path else None,
        "rows_total": len(rows),
        "holdout_rows_total": len(holdout_rows),
        "action_space": action_space,
        "mode": "train" if args.train else "validate_only",
        "target_mode": target_mode,
        "architecture": architecture,
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
        action_space=action_space,
        split_key_field=split_key_field,
    )
    if len(dataset_full) == 0:
        summary.update({"ok": False, "ready_for_training": False, "reason": "no_rows_with_mapped_actions"})
        print(json.dumps(summary, indent=2))
        return 0

    train_split = _safe_float(data_cfg.get("train_split"), 0.9)
    split_seed = _safe_int(data_cfg.get("seed"), 4090)
    if holdout_rows:
        train_set = dataset_full
        val_dataset = TeacherRowsDataset(
            rows=holdout_rows,
            action_to_index=action_to_index,
            input_dim=input_dim,
            action_space=action_space,
            split_key_field=split_key_field,
        )
        val_set = val_dataset if len(val_dataset) > 0 else None
        effective_split_method = "explicit_holdout_jsonl"
    else:
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
        effective_split_method = split_method
    batch_size = max(8, _safe_int(train_cfg.get("batch_size"), 512))
    train_loader = DataLoader(train_set, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_set, batch_size=batch_size, shuffle=False) if val_set else None
    class_weighting_mode = str(
        args.class_weighting
        or train_cfg.get("class_weighting")
        or "none"
    ).strip().lower()
    passive_subset_weighting = str(
        args.passive_subset_weighting
        or train_cfg.get("passive_subset_weighting")
        or "none"
    ).strip().lower()
    if passive_subset_weighting not in {"none", "balanced_fold_call"}:
        raise ValueError(f"unsupported_passive_subset_weighting:{passive_subset_weighting}")
    class_weight_cap = max(0.0, _safe_float(train_cfg.get("class_weight_cap"), 50.0))
    train_targets = _dataset_targets(train_set)
    class_weights = _build_class_weights(
        targets=train_targets,
        num_classes=len(action_space),
        mode=class_weighting_mode,
        cap=class_weight_cap,
    )

    summary.update(
        {
            "ok": True,
            "ready_for_training": True,
            "rows_mapped": len(dataset_full),
            "feature_contract_rows_checked": int(dataset_full.contract_total_rows),
            "feature_contract_rows_matching": int(dataset_full.contract_matching_rows),
            "feature_contract_rows_mismatching": int(dataset_full.contract_mismatch_rows),
            "distribution_rows": int(dataset_full.distribution_rows),
            "fallback_one_hot_rows": int(dataset_full.fallback_one_hot_rows),
            "train_rows": len(train_set),
            "val_rows": len(val_set) if val_set else 0,
            "holdout_feature_contract_rows_checked": int(val_dataset.contract_total_rows) if holdout_rows else 0,
            "holdout_feature_contract_rows_matching": int(val_dataset.contract_matching_rows) if holdout_rows else 0,
            "holdout_feature_contract_rows_mismatching": int(val_dataset.contract_mismatch_rows) if holdout_rows else 0,
            "holdout_distribution_rows": int(val_dataset.distribution_rows) if holdout_rows else 0,
            "holdout_fallback_one_hot_rows": int(val_dataset.fallback_one_hot_rows) if holdout_rows else 0,
            "split_method": effective_split_method,
            "split_key_field": split_key_field,
            "split_seed": split_seed,
            "class_weighting": class_weighting_mode,
            "passive_subset_weighting": passive_subset_weighting,
            "class_weight_cap": class_weight_cap,
            "class_weights": class_weights or [],
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
        architecture=architecture,
    ).to(device)
    optimizer = optim.AdamW(
        model.parameters(),
        lr=max(1e-6, _safe_float(train_cfg.get("learning_rate"), 3e-4)),
        weight_decay=max(0.0, _safe_float(train_cfg.get("weight_decay"), 1e-5)),
    )
    class_weight_tensor = (
        torch.tensor(class_weights, dtype=torch.float32, device=device)
        if class_weights
        else None
    )
    posture_class_weights = None
    passive_class_weights = None
    aggressive_class_weights = None
    hierarchical_mappings = _hierarchical_mappings(action_to_index)
    if architecture == "hierarchical":
        posture_targets_train, passive_mask_train, aggressive_mask_train, passive_local_train, aggressive_local_train = _hierarchical_targets(
            targets=torch.tensor(train_targets, dtype=torch.long),
            mappings=hierarchical_mappings,
        )
        posture_weight_values = _build_class_weights(
            targets=posture_targets_train.tolist(),
            num_classes=2,
            mode=class_weighting_mode,
            cap=class_weight_cap,
        )
        passive_weight_values = _build_class_weights(
            targets=passive_local_train[passive_mask_train].tolist(),
            num_classes=len(PASSIVE_ACTIONS),
            mode=class_weighting_mode,
            cap=class_weight_cap,
        )
        aggressive_weight_values = _build_class_weights(
            targets=aggressive_local_train[aggressive_mask_train].tolist(),
            num_classes=len(AGGRESSIVE_ACTIONS),
            mode=class_weighting_mode,
            cap=class_weight_cap,
        )
        posture_class_weights = (
            torch.tensor(posture_weight_values, dtype=torch.float32, device=device)
            if posture_weight_values
            else None
        )
        passive_class_weights = (
            torch.tensor(passive_weight_values, dtype=torch.float32, device=device)
            if passive_weight_values
            else None
        )
        aggressive_class_weights = (
            torch.tensor(aggressive_weight_values, dtype=torch.float32, device=device)
            if aggressive_weight_values
            else None
        )
        summary["hierarchical_class_weights"] = {
            "posture": posture_weight_values or [],
            "passive": passive_weight_values or [],
            "aggressive": aggressive_weight_values or [],
        }
    epochs = max(1, _safe_int(train_cfg.get("epochs"), 30))
    clip_norm = max(0.0, _safe_float(train_cfg.get("gradient_clip_norm"), 1.0))

    history: list[dict[str, Any]] = []
    for epoch in range(1, epochs + 1):
        model.train()
        epoch_loss = 0.0
        batches = 0
        for x, y, dist, legal_mask in train_loader:
            x = x.to(device)
            y = y.to(device)
            dist = dist.to(device)
            legal_mask = legal_mask.to(device)
            optimizer.zero_grad(set_to_none=True)
            outputs = model(x)
            if architecture == "hierarchical":
                posture_targets, passive_rows, aggressive_rows, passive_targets, aggressive_targets = _hierarchical_targets(
                    targets=y,
                    mappings=hierarchical_mappings,
                )
                posture_mask, passive_mask, aggressive_mask = _hierarchical_legal_masks(legal_mask, hierarchical_mappings)
                posture_logits = _apply_legal_action_mask(outputs["posture"], posture_mask)
                passive_logits = _apply_legal_action_mask(outputs["passive"], passive_mask)
                aggressive_logits = _apply_legal_action_mask(outputs["aggressive"], aggressive_mask)
                loss = _weighted_ce_loss(posture_logits, posture_targets, posture_class_weights)
                if passive_rows.any():
                    loss = loss + _weighted_ce_loss(
                        passive_logits[passive_rows],
                        passive_targets[passive_rows],
                        passive_class_weights,
                    )
                if aggressive_rows.any():
                    loss = loss + _weighted_ce_loss(
                        aggressive_logits[aggressive_rows],
                        aggressive_targets[aggressive_rows],
                        aggressive_class_weights,
                    )
            else:
                logits = _apply_legal_action_mask(outputs, legal_mask)
                if target_mode == "distribution":
                    log_probs = torch.log_softmax(logits, dim=1)
                    loss = _weighted_kl_divergence(log_probs, dist, class_weight_tensor)
                else:
                    loss = _scalar_loss(
                        logits=logits,
                        targets=y,
                        legal_mask=legal_mask,
                        action_to_index=action_to_index,
                        class_weight_tensor=class_weight_tensor,
                        passive_subset_weighting=passive_subset_weighting,
                    )
            loss.backward()
            if clip_norm > 0:
                nn.utils.clip_grad_norm_(model.parameters(), clip_norm)
            optimizer.step()
            epoch_loss += float(loss.item())
            batches += 1
        train_loss = epoch_loss / max(1, batches)
        train_acc = _accuracy(model, train_loader, device, action_space, action_to_index, architecture)
        val_acc = _accuracy(model, val_loader, device, action_space, action_to_index, architecture) if val_loader else 0.0
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
            "target_mode": target_mode,
            "architecture": architecture,
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
    train_metrics = _collect_class_metrics(model, train_loader, device, action_space, action_to_index, architecture)
    val_metrics = _collect_class_metrics(model, val_loader, device, action_space, action_to_index, architecture) if val_loader else None
    summary.update(
        {
            "train_per_class": train_metrics["per_class"],
            "val_per_class": val_metrics["per_class"] if val_metrics else [],
        }
    )
    report_path.write_text(
        json.dumps(
            {
                "summary": summary,
                "history": history,
                "train_metrics": train_metrics,
                "val_metrics": val_metrics,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
