#!/usr/bin/env python3
"""Validate Android sparse and boot image structures."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import struct
from pathlib import Path


SPARSE_MAGIC = 0xED26FF3A
BOOT_MAGIC = b"ANDROID!"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_sparse(path: Path, expected_size: int | None) -> dict[str, object]:
    with path.open("rb") as handle:
        header = handle.read(28)
    if len(header) != 28:
        raise ValueError(f"{path}: sparse header too short")
    magic, major, _minor, _file_hdr, _chunk_hdr, block_size, total_blocks, *_rest = struct.unpack(
        "<IHHHHIIII", header
    )
    if magic != SPARSE_MAGIC:
        raise ValueError(f"{path}: invalid sparse magic 0x{magic:08X}")
    logical_size = block_size * total_blocks
    if expected_size is not None and logical_size != expected_size:
        raise ValueError(f"{path}: logical size {logical_size} != {expected_size}")
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "magic": f"0x{magic:08X}",
        "major": major,
        "block_size": block_size,
        "total_blocks": total_blocks,
        "logical_size": logical_size,
    }


def verify_boot(path: Path, dtb: Path | None) -> dict[str, object]:
    data = path.read_bytes()
    if len(data) < 64 or data[:8] != BOOT_MAGIC:
        raise ValueError(f"{path}: invalid Android boot magic")
    (
        kernel_size,
        kernel_addr,
        ramdisk_size,
        ramdisk_addr,
        second_size,
        second_addr,
        tags_addr,
        page_size,
        header_version,
        os_version,
    ) = struct.unpack("<10I", data[8:48])
    name = data[48:64].split(b"\0", 1)[0].decode("ascii", errors="replace")
    cmdline = data[64:576].split(b"\0", 1)[0].decode("ascii", errors="replace")
    if page_size != 4096:
        raise ValueError(f"{path}: page size {page_size} != 4096")
    if header_version != 0:
        raise ValueError(f"{path}: header version {header_version} != 0")
    if "root=/dev/sda17" not in cmdline:
        raise ValueError(f"{path}: missing root=/dev/sda17 in cmdline")
    if ramdisk_size <= 0:
        raise ValueError(f"{path}: empty ramdisk")
    dtb_suffix_match = None
    if dtb is not None:
        payload = data[page_size : page_size + kernel_size]
        dtb_data = dtb.read_bytes()
        if not payload.endswith(dtb_data):
            raise ValueError(f"{path}: kernel payload does not end with expected DTB")
        dtb_suffix_match = True
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "page_size": page_size,
        "header_version": header_version,
        "kernel_size": kernel_size,
        "ramdisk_size": ramdisk_size,
        "second_size": second_size,
        "kernel_addr": kernel_addr,
        "ramdisk_addr": ramdisk_addr,
        "second_addr": second_addr,
        "tags_addr": tags_addr,
        "os_version": os_version,
        "name": name,
        "cmdline": cmdline,
        "dtb_sha256_suffix_match": dtb_suffix_match,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--boot", required=True, type=Path)
    parser.add_argument("--dtb", type=Path)
    parser.add_argument("--base-sparse", type=Path)
    parser.add_argument("--orbital-sparse", required=True, type=Path)
    parser.add_argument("--expected-size", type=int)
    parser.add_argument("--note", action="append", default=[])
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    result = {
        "schema_version": 2,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "boot": verify_boot(args.boot, args.dtb),
        "orbital_sparse": verify_sparse(args.orbital_sparse, args.expected_size),
        "notes": args.note,
    }
    if args.base_sparse is not None:
        result["base_sparse"] = verify_sparse(args.base_sparse, args.expected_size)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
