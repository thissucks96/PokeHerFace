#!/usr/bin/env python3
"""Inspect passive-action errors from a trained local neural checkpoint."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import torch

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from train_local_neural import (  # noqa: E402
    PASSIVE_ACTIONS,
    PolicyMLP,
    TeacherRowsDataset,
    _bucketize_action,
    _hierarchical_mappings,
    _hierarchical_reconstruct_logits,
    _load_rows,
    _predict_logits,
    _safe_float,
)


def _mapped_rows(rows: list[dict[str, Any]], action_to_index: dict[str, int]) -> list[dict[str, Any]]:
    kept: list[dict[str, Any]] = []
    for row in rows:
        source_row = row.get("source_row") if isinstance(row.get("source_row"), dict) else {}
        target = source_row.get("target") if isinstance(source_row.get("target"), dict) else {}
        features = source_row.get("features") if isinstance(source_row.get("features"), dict) else {}
        action_raw = target.get("selected_action")
        amount = target.get("selected_amount")
        pot = max(1.0, _safe_float(features.get("current_pot", features.get("starting_pot")), 1.0))
        action = _bucketize_action(action_raw, amount, pot)
        if action in action_to_index:
            kept.append(row)
    return kept


def _softmax_probs(logits: torch.Tensor) -> list[float]:
    return torch.softmax(logits, dim=0).detach().cpu().tolist()


def _record(
    row: dict[str, Any],
    target_label: str,
    predicted_label: str,
    final_logits: torch.Tensor,
    passive_probs: list[float] | None,
    posture_probs: list[float] | None,
) -> dict[str, Any]:
    source_row = row.get("source_row") if isinstance(row.get("source_row"), dict) else {}
    source = source_row.get("source") if isinstance(source_row.get("source"), dict) else {}
    features = source_row.get("features") if isinstance(source_row.get("features"), dict) else {}
    target = source_row.get("target") if isinstance(source_row.get("target"), dict) else {}
    return {
        "row_id": row.get("row_id"),
        "split_key": row.get("split_key"),
        "target_action": target_label,
        "predicted_action": predicted_label,
        "source": source,
        "features": features,
        "target": target,
        "final_action_probs": _softmax_probs(final_logits),
        "passive_head_probs": passive_probs,
        "posture_probs": posture_probs,
    }


def _write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze passive fold/call confusion on a holdout split.")
    parser.add_argument(
        "--dataset-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.holdout.jsonl"),
        help="Holdout JSONL to inspect.",
    )
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/artifacts/checkpoints/neural_policy_v1_last.pt"),
        help="Model checkpoint to load.",
    )
    parser.add_argument(
        "--report-json",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/passive_error_report.json"),
        help="Summary report output JSON.",
    )
    parser.add_argument(
        "--fold-miss-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/passive_fold_to_call_rows.jsonl"),
        help="Rows where target=fold and prediction=call.",
    )
    parser.add_argument(
        "--call-hit-jsonl",
        type=Path,
        default=Path("2_Neural_Brain/local_pipeline/reports/passive_call_to_call_rows.jsonl"),
        help="Rows where target=call and prediction=call.",
    )
    parser.add_argument(
        "--sample-limit",
        type=int,
        default=50,
        help="Maximum rows to dump per category.",
    )
    args = parser.parse_args()

    checkpoint_path = args.checkpoint.resolve()
    dataset_path = args.dataset_jsonl.resolve()
    report_path = args.report_json.resolve()
    fold_miss_path = args.fold_miss_jsonl.resolve()
    call_hit_path = args.call_hit_jsonl.resolve()

    if not checkpoint_path.exists():
        print(json.dumps({"ok": False, "error": f"missing_checkpoint:{checkpoint_path}"}))
        return 2

    rows = _load_rows(dataset_path)
    if not rows:
        print(json.dumps({"ok": False, "error": f"missing_or_empty_dataset:{dataset_path}"}))
        return 2

    checkpoint = torch.load(checkpoint_path, map_location="cpu")
    action_space = list(checkpoint.get("action_space") or ["fold", "check", "call", "raise_small", "raise_big", "all_in"])
    action_to_index = {name: idx for idx, name in enumerate(action_space)}
    architecture = str(checkpoint.get("architecture") or "flat").strip().lower()
    input_dim = int(checkpoint.get("input_dim") or 128)

    model = PolicyMLP(
        input_dim=input_dim,
        hidden_dim=256,
        num_layers=3,
        dropout=0.1,
        output_dim=len(action_space),
        architecture=architecture,
    )
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()

    mapped_rows = _mapped_rows(rows, action_to_index)
    dataset = TeacherRowsDataset(
        rows=mapped_rows,
        action_to_index=action_to_index,
        input_dim=input_dim,
        action_space=action_space,
        split_key_field="split_key",
    )
    if len(dataset) != len(mapped_rows):
        mapped_rows = mapped_rows[: len(dataset)]

    fold_to_call: list[dict[str, Any]] = []
    call_to_call: list[dict[str, Any]] = []
    passive_total = 0
    fold_support = 0
    call_support = 0

    with torch.no_grad():
        for idx, row in enumerate(mapped_rows):
            x, y, _dist, legal_mask = dataset[idx]
            x = x.unsqueeze(0)
            legal_mask_b = legal_mask.unsqueeze(0)
            logits, aux = _predict_logits(
                model=model,
                x=x,
                legal_mask=legal_mask_b,
                action_space=action_space,
                action_to_index=action_to_index,
                architecture=architecture,
            )
            pred_idx = int(torch.argmax(logits, dim=1).item())
            target_label = action_space[int(y)]
            pred_label = action_space[pred_idx]
            if target_label not in {"fold", "call"}:
                continue
            passive_total += 1
            if target_label == "fold":
                fold_support += 1
            if target_label == "call":
                call_support += 1

            passive_probs = None
            posture_probs = None
            if architecture == "hierarchical" and aux is not None:
                passive_probs = _softmax_probs(aux["passive_logits"][0])
                posture_probs = _softmax_probs(aux["posture_logits"][0])

            rec = _record(
                row=row,
                target_label=target_label,
                predicted_label=pred_label,
                final_logits=logits[0],
                passive_probs=passive_probs,
                posture_probs=posture_probs,
            )
            if target_label == "fold" and pred_label == "call" and len(fold_to_call) < args.sample_limit:
                fold_to_call.append(rec)
            if target_label == "call" and pred_label == "call" and len(call_to_call) < args.sample_limit:
                call_to_call.append(rec)

    _write_jsonl(fold_miss_path, fold_to_call)
    _write_jsonl(call_hit_path, call_to_call)

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "dataset_jsonl": str(dataset_path),
        "checkpoint": str(checkpoint_path),
        "architecture": architecture,
        "passive_total_rows": passive_total,
        "fold_support": fold_support,
        "call_support": call_support,
        "fold_to_call_dumped": len(fold_to_call),
        "call_to_call_dumped": len(call_to_call),
        "fold_to_call_jsonl": str(fold_miss_path),
        "call_to_call_jsonl": str(call_hit_path),
        "ok": True,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
