#!/usr/bin/env python3
"""Create a provenance manifest after all image and package checks pass."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
from pathlib import Path
from typing import Any


BUFFER_SIZE = 4 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(BUFFER_SIZE), b""):
            digest.update(data)
    return digest.hexdigest()


def relative(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            continue
        parsed = shlex.split(value, comments=True, posix=True)
        values[key] = parsed[0] if parsed else ""
    return values


def read_tsv(path: Path) -> list[dict[str, str]]:
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line]
    headers = lines[0].split("\t")
    return [dict(zip(headers, line.split("\t"), strict=True)) for line in lines[1:]]


def write_exclusive(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def artifact(path: Path, root: Path) -> dict[str, Any]:
    return {
        "path": relative(path, root),
        "size_bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--source-lock", required=True, type=Path)
    parser.add_argument("--prepared", required=True, type=Path)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--builder-image", required=True)
    parser.add_argument("--kernel-builder-image", required=True)
    args = parser.parse_args()

    root = args.root.resolve()
    out = args.out.resolve()
    state = args.state.resolve()
    manifest_path = out / "build-manifest.json"
    if manifest_path.exists():
        raise FileExistsError(f"refusing to overwrite build manifest: {manifest_path}")

    config = read_env(args.config)
    build_state = json.loads((state / "build-state.json").read_text(encoding="utf-8"))
    orbital_snapshot = json.loads(
        (args.work / "orbital-source-manifest.json").read_text(encoding="utf-8")
    )
    verification = json.loads((state / "verification.json").read_text(encoding="utf-8"))
    package_report = json.loads((state / "package-report.json").read_text(encoding="utf-8"))
    segment_dir = out / "oneplus6-rootfs-orbital-segments"
    segment_manifest_path = segment_dir / "manifest.json"
    segment_manifest = json.loads(segment_manifest_path.read_text(encoding="utf-8"))

    if build_state.get("phase") != "complete":
        raise ValueError("build state is not complete")
    if package_report.get("status") != "verified":
        raise ValueError("segmented ZIP has not passed integrity verification")

    source_rows = read_tsv(args.source_lock)
    prepared_rows = read_tsv(args.prepared / "source-revisions.lock.tsv")
    if source_rows != prepared_rows:
        raise ValueError("prepared source revisions differ from the checked-in lock")

    patches = []
    for path in sorted((args.prepared / "patches").glob("*.patch")):
        patches.append({"file": f"kernel-patches/{path.name}", "sha256": sha256_file(path)})

    sources: list[dict[str, Any]] = []
    for row in source_rows:
        item: dict[str, Any] = {
            "component": row["component"],
            "repository": row["repository"],
            "version": row["version"],
            "commit": row["commit"],
            "license": row["license"],
            "dirty": False,
        }
        if row["component"] == "orbital":
            item["dirty"] = bool(orbital_snapshot.get("dirty"))
            item["working_tree_sha256"] = orbital_snapshot.get("tree_sha256")
            if orbital_snapshot.get("commit") != row["commit"]:
                raise ValueError("Orbital snapshot commit differs from the source lock")
        elif row["component"] == "kernel":
            item["dirty"] = bool(patches)
            item["patches"] = patches
        sources.append(item)

    lock_paths = [
        args.config,
        args.source_lock,
        root / "config" / "apk-sha256.lock",
        root / "config" / "ubuntu-packages.lock.tsv",
        root / "config" / "builder-packages.lock.tsv",
        root / "config" / "kernel-builder-packages.lock.tsv",
        args.prepared / "prepared.sha256",
    ]
    locks = [
        {"path": relative(path, root), "sha256": sha256_file(path)}
        for path in lock_paths
    ]

    package_sets = {}
    for label in ("base", "orbital"):
        package_path = state / f"ubuntu-packages-{label}.tsv"
        lines = package_path.read_text(encoding="utf-8").splitlines()
        if lines != (root / "config" / "ubuntu-packages.lock.tsv").read_text(
            encoding="utf-8"
        ).splitlines():
            raise ValueError(f"{label} Ubuntu package set differs from the lock")
        package_sets[label] = {
            "path": relative(package_path, root),
            "sha256": sha256_file(package_path),
            "count": len(lines),
        }

    sums_path = out / "SHA256SUMS.txt"
    deliverables = sorted(
        path
        for path in out.rglob("*")
        if path.is_file() and path.name not in {"build-manifest.json", "SHA256SUMS.txt"}
    )
    sums = "".join(f"{sha256_file(path)}  {relative(path, out)}\n" for path in deliverables)
    write_exclusive(sums_path, sums.encode("ascii"))

    artifact_paths = [*deliverables, sums_path]
    orbital = next(item for item in sources if item["component"] == "orbital")
    base_sparse = verification.get("base_sparse", {})
    orbital_sparse = verification["orbital_sparse"]
    boot_check = verification["boot"]
    if not base_sparse or not orbital_sparse.get("logical_size"):
        raise ValueError("rootfs sparse verification is incomplete")

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    manifest = {
        "schema_version": 1,
        "status": "verified",
        "release": {
            "name": config.get("RELEASE_NAME", ""),
            "version": config.get("RELEASE_VERSION", ""),
            "device_id": config.get("DEVICE_ID", ""),
            "ubuntu_version": config.get("UBUNTU_VERSION", ""),
            "kernel_release": config.get("KERNEL_RELEASE", ""),
        },
        "build": {
            "started_at": os.environ.get("BUILD_STARTED_AT", now),
            "finished_at": now,
            "platform": args.platform,
            "mode": build_state.get("build_mode"),
            "builder_image_id": args.builder_image,
            "kernel_builder_image_id": args.kernel_builder_image,
            "release_build": os.environ.get("BUILD_RELEASE", "0") == "1",
            "oneplus6_image_commit": build_state.get("oneplus6_image_commit"),
            "oneplus6_image_dirty": bool(build_state.get("oneplus6_image_dirty")),
            "oneplus6_image_tree_sha256": build_state.get("oneplus6_image_tree_sha256"),
            "publicly_reproducible": not orbital["dirty"]
            and not bool(build_state.get("oneplus6_image_dirty")),
        },
        "sources": sources,
        "locks": locks,
        "packages": package_sets,
        "validations": {
            "boot_header_and_root_partition": True,
            "boot_source": "prebuilt-input",
            "sparse_logical_size_bytes": {
                "base": base_sparse["logical_size"],
                "orbital": orbital_sparse["logical_size"],
            },
            "package_locks": True,
            "segment_manifest_sha256": sha256_file(segment_manifest_path),
            "zip_sha256": package_report["archive"]["sha256"],
            "zip_integrity": package_report["status"] == "verified",
        },
        "artifacts": [artifact(path, root) for path in artifact_paths],
    }

    rendered = (json.dumps(manifest, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    lowered = rendered.decode("utf-8").lower()
    forbidden = (
        "ssh_key_fingerprint",
        "password_hash",
        "password_sha256",
        "ssh_password",
        "orbital.diff",
    )
    if any(value in lowered for value in forbidden):
        raise ValueError("refusing to write credential-derived data to the build manifest")
    write_exclusive(manifest_path, rendered)
    print(json.dumps({"status": "verified", "manifest": relative(manifest_path, root)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
