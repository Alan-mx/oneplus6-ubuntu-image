#!/usr/bin/env python3
"""Resolve a small APK dependency closure from an APKINDEX file."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def parse_index(path: Path) -> dict[str, dict[str, str]]:
    packages: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip("\n")
        if not line:
            if current:
                packages.append(current)
                current = {}
            continue
        if len(line) < 2 or line[1] != ":":
            continue
        current[line[0]] = line[2:]
    if current:
        packages.append(current)

    by_name: dict[str, dict[str, str]] = {}
    provides: dict[str, str] = {}
    for package in packages:
        name = package.get("P")
        if not name:
            continue
        previous = by_name.get(name)
        if previous is None or str(package.get("V", "")) > str(previous.get("V", "")):
            by_name[name] = package
        for provided in package.get("p", "").split():
            provides.setdefault(strip_dependency(provided), name)
    for name, package in by_name.items():
        provides.setdefault(name, name)
    return {"packages": by_name, "provides": provides}


def strip_dependency(value: str) -> str:
    return re.split(r"[<>=~]", value, maxsplit=1)[0]


def package_name(dependency: str, provides: dict[str, str]) -> str | None:
    name = strip_dependency(dependency)
    if name.startswith(("so:", "cmd:", "pc:")):
        return None
    return provides.get(name)


def resolve(
    index: dict[str, dict[str, dict[str, str]]],
    roots: list[str],
    metadata_only: set[str],
) -> dict[str, dict[str, str]]:
    packages = index["packages"]
    provides = index["provides"]
    selected: dict[str, dict[str, str]] = {}
    queue = list(roots)

    while queue:
        requested = queue.pop(0)
        name = package_name(requested, provides)
        if name is None:
            continue
        if name in selected:
            continue
        package = packages.get(name)
        if package is None:
            raise KeyError(f"package not found: {requested}")
        selected[name] = package
        if name in metadata_only:
            continue
        for dependency in package.get("D", "").split():
            queue.append(dependency)

    return selected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--root", action="append", required=True)
    parser.add_argument("--metadata", action="append", default=[])
    args = parser.parse_args()

    index = parse_index(args.index)
    selected = resolve(index, args.root, set(args.metadata))
    output = {
        "schema_version": 1,
        "packages": [
            {
                "name": name,
                "version": package.get("V", ""),
                "arch": package.get("A", ""),
                "filename": f"{name}-{package.get('V', '')}.apk",
                "dependencies": package.get("D", "").split(),
                "role": "metadata" if name in args.metadata else "runtime",
            }
            for name, package in sorted(selected.items())
        ],
    }
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
