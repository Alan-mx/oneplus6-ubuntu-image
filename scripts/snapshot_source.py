#!/usr/bin/env python3
"""Snapshot a Git worktree and record a content digest for build provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
from pathlib import Path


BUFFER_SIZE = 4 * 1024 * 1024


def run_git(source: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout


def update_tree_digest(digest, root: Path, path: Path) -> None:
    relative = path.relative_to(root).as_posix()
    metadata = path.lstat()
    digest.update(relative.encode("utf-8", "surrogateescape"))
    digest.update(b"\0")
    digest.update(str(stat.S_IMODE(metadata.st_mode)).encode("ascii"))
    digest.update(b"\0")
    if stat.S_ISLNK(metadata.st_mode):
        digest.update(b"link\0")
        digest.update(os.readlink(path).encode("utf-8", "surrogateescape"))
    elif stat.S_ISREG(metadata.st_mode):
        digest.update(b"file\0")
        with path.open("rb") as handle:
            for data in iter(lambda: handle.read(BUFFER_SIZE), b""):
                digest.update(data)
    elif stat.S_ISDIR(metadata.st_mode):
        digest.update(b"directory")
    else:
        digest.update(b"other")
    digest.update(b"\0")


def tree_digest(root: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    entries = sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())
    for path in entries:
        update_tree_digest(digest, root, path)
    return digest.hexdigest(), len(entries)


def git_tree_digest(source: Path) -> tuple[str, int]:
    raw_paths = subprocess.run(
        ["git", "-C", str(source), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    paths = sorted({Path(os.fsdecode(value)) for value in raw_paths.split(b"\0") if value})
    digest = hashlib.sha256()
    count = 0
    for relative in paths:
        path = source / relative
        name = relative.as_posix()
        digest.update(name.encode("utf-8", "surrogateescape"))
        digest.update(b"\0")
        if not path.exists() and not path.is_symlink():
            digest.update(b"deleted\0")
            count += 1
            continue
        update_tree_digest(digest, source, path)
        count += 1
    return digest.hexdigest(), count


def copy_git_tree(source: Path, destination: Path) -> None:
    raw_paths = subprocess.run(
        ["git", "-C", str(source), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    for raw_path in raw_paths.split(b"\0"):
        if not raw_path:
            continue
        relative = Path(os.fsdecode(raw_path))
        source_path = source / relative
        if not source_path.exists() and not source_path.is_symlink():
            continue
        destination_path = destination / relative
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        if source_path.is_symlink():
            os.symlink(os.readlink(source_path), destination_path)
        elif source_path.is_file():
            shutil.copy2(source_path, destination_path)
        else:
            raise ValueError(f"unsupported source entry: {relative}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()

    source = args.source.resolve(strict=True)
    destination = args.destination.resolve()
    if destination.exists():
        raise FileExistsError(f"snapshot destination already exists: {destination}")

    commit = run_git(source, "rev-parse", "HEAD").strip()
    if commit != args.expected_commit:
        raise ValueError(f"source commit mismatch: expected {args.expected_commit}, found {commit}")
    status = run_git(source, "status", "--porcelain=v1", "--untracked-files=all")
    dirty = bool(status.strip())
    if args.require_clean and dirty:
        raise ValueError("release builds require a clean source worktree")

    destination.mkdir(parents=True)
    copy_git_tree(source, destination)
    digest, file_count = tree_digest(destination)
    manifest = {
        "schema_version": 1,
        "commit": commit,
        "dirty": dirty,
        "tree_sha256": digest,
        "entry_count": file_count,
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
