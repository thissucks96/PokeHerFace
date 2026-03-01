#!/usr/bin/env python3
"""Check DyypHoldem neural asset availability and emit a manifest report.

Usage:
  python scripts/check_neural_assets.py
  python scripts/check_neural_assets.py --root 2_Neural_Brain --out 5_Vision_Extraction/out/neural_shadow_reports
"""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


LFS_HEADER = "version https://git-lfs.github.com/spec/v1"


@dataclass
class AssetRow:
    file: str
    oid: str
    declared_size_bytes: int
    local_lfs_object_present: bool
    local_lfs_object_path: str


def _iter_files(root: Path) -> Iterable[Path]:
    for p in root.rglob("*"):
        if p.is_file():
            yield p


def _parse_pointer_file(path: Path) -> tuple[str, int] | None:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    if not lines or lines[0].strip() != LFS_HEADER:
        return None
    oid = ""
    size = 0
    for line in lines:
        line = line.strip()
        if line.startswith("oid sha256:"):
            oid = line.replace("oid sha256:", "", 1).strip()
        elif line.startswith("size "):
            raw = line.replace("size ", "", 1).strip()
            try:
                size = int(raw)
            except ValueError:
                size = 0
    if not oid:
        return None
    return oid, size


def _local_lfs_object_path(repo_root: Path, oid: str) -> Path:
    return repo_root / ".git" / "lfs" / "objects" / oid[:2] / oid[2:4] / oid


def main() -> int:
    parser = argparse.ArgumentParser(description="Check missing neural LFS assets and write a manifest.")
    parser.add_argument("--root", default="2_Neural_Brain", help="Neural root directory to scan.")
    parser.add_argument(
        "--out",
        default="5_Vision_Extraction/out/neural_shadow_reports",
        help="Output directory for JSON/CSV manifest.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    neural_root = (repo_root / args.root).resolve()
    out_dir = (repo_root / args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    rows: list[AssetRow] = []
    for path in _iter_files(neural_root):
        parsed = _parse_pointer_file(path)
        if not parsed:
            continue
        oid, size = parsed
        obj_path = _local_lfs_object_path(repo_root, oid)
        rows.append(
            AssetRow(
                file=str(path.relative_to(repo_root)).replace("\\", "/"),
                oid=oid,
                declared_size_bytes=size,
                local_lfs_object_present=obj_path.exists(),
                local_lfs_object_path=str(obj_path.relative_to(repo_root)).replace("\\", "/"),
            )
        )

    rows.sort(key=lambda r: r.file)
    manifest = [asdict(r) for r in rows]
    json_path = out_dir / "missing_neural_lfs_manifest.json"
    csv_path = out_dir / "missing_neural_lfs_manifest.csv"
    json_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "file",
                "oid",
                "declared_size_bytes",
                "local_lfs_object_present",
                "local_lfs_object_path",
            ],
        )
        writer.writeheader()
        writer.writerows(manifest)

    total_size = sum(r.declared_size_bytes for r in rows)
    present = sum(1 for r in rows if r.local_lfs_object_present)
    print(f"neural_root={neural_root}")
    print(f"files={len(rows)}")
    print(f"local_present={present}")
    print(f"declared_size_total_mb={round(total_size / (1024 * 1024), 2)}")
    print(f"manifest_json={json_path}")
    print(f"manifest_csv={csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
