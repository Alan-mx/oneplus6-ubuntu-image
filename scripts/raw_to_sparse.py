#!/usr/bin/env python3
"""Convert ext4 raw images to Android sparse images with forced raw ranges."""

from __future__ import annotations

import argparse
import struct
import subprocess
from pathlib import Path


SPARSE_MAGIC = 0xED26FF3A
FILE_HEADER_SIZE = 28
CHUNK_HEADER_SIZE = 12
CHUNK_TYPE_RAW = 0xCAC1
CHUNK_TYPE_FILL = 0xCAC2
MAX_CHUNK_BLOCKS = 0xFFFF


def add_range(blocks: set[int], value: str) -> None:
    value = value.strip()
    if not value or value == "-1":
        return
    if "-" in value:
        start_text, end_text = value.split("-", 1)
        start = int(start_text)
        end = int(end_text)
        blocks.update(range(start, end + 1))
    elif value.isdigit():
        blocks.add(int(value))


def metadata_blocks(raw: Path) -> set[int]:
    output = subprocess.check_output(
        ["dumpe2fs", "-g", str(raw)],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    blocks: set[int] = set()
    for line in output.splitlines():
        fields = line.split(":")
        if len(fields) < 6 or not fields[0].isdigit():
            continue
        for value in fields[2:6]:
            add_range(blocks, value)

    inode = subprocess.check_output(
        ["debugfs", "-R", "stat <8>", str(raw)],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    for line in inode.splitlines():
        if line.startswith("(") and "):" in line:
            add_range(blocks, line.split(":", 1)[1])
    return blocks


def parse_ranges(values: list[str]) -> set[int]:
    blocks: set[int] = set()
    for value in values:
        start_text, count_text = value.split(":", 1)
        start = int(start_text, 0)
        count = int(count_text, 0)
        blocks.update(range(start, start + count))
    return blocks


def write_header(handle, block_size: int, total_blocks: int, chunks: int) -> None:
    handle.seek(0)
    handle.write(
        struct.pack(
            "<IHHHHIIII",
            SPARSE_MAGIC,
            1,
            0,
            FILE_HEADER_SIZE,
            CHUNK_HEADER_SIZE,
            block_size,
            total_blocks,
            chunks,
            0,
        )
    )


def write_fill(handle, value: int, blocks: int) -> None:
    handle.write(struct.pack("<HHII", CHUNK_TYPE_FILL, 0, blocks, 16))
    handle.write(value.to_bytes(4, "little"))


def write_raw(handle, data: bytes, blocks: int) -> None:
    handle.write(
        struct.pack(
            "<HHII",
            CHUNK_TYPE_RAW,
            0,
            blocks,
            CHUNK_HEADER_SIZE + len(data),
        )
    )
    handle.write(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("sparse", type=Path)
    parser.add_argument("block_size", type=int)
    parser.add_argument("--force-raw", action="append", default=[])
    args = parser.parse_args()

    total_bytes = args.raw.stat().st_size
    total_blocks = total_bytes // args.block_size
    forced = metadata_blocks(args.raw) | parse_ranges(args.force_raw)

    chunks = 0
    pending_kind: str | None = None
    pending_fill: int | None = None
    pending_blocks = 0
    pending_raw = bytearray()

    def flush() -> None:
        nonlocal chunks, pending_kind, pending_fill, pending_blocks, pending_raw
        if pending_kind == "fill" and pending_fill is not None:
            write_fill(handle, pending_fill, pending_blocks)
            chunks += 1
        elif pending_kind == "raw" and pending_raw:
            write_raw(handle, bytes(pending_raw), pending_blocks)
            chunks += 1
        pending_kind = None
        pending_fill = None
        pending_blocks = 0
        pending_raw.clear()

    with args.raw.open("rb") as source, args.sparse.open("wb") as handle:
        handle.write(b"\0" * FILE_HEADER_SIZE)
        for block_index in range(total_blocks):
            data = source.read(args.block_size)
            if len(data) != args.block_size:
                raise ValueError("raw image ended unexpectedly")

            if block_index in forced:
                kind = "raw"
                fill_value = None
            elif data == b"\0" * args.block_size:
                kind = "fill"
                fill_value = 0
            elif data == data[:1] * args.block_size:
                kind = "fill"
                fill_value = int.from_bytes(data[:1] * 4, "little")
            else:
                kind = "raw"
                fill_value = None

            if pending_blocks and (
                kind != pending_kind
                or fill_value != pending_fill
                or pending_blocks >= MAX_CHUNK_BLOCKS
            ):
                flush()

            pending_kind = kind
            pending_fill = fill_value
            pending_blocks += 1
            if kind == "raw":
                pending_raw.extend(data)

        flush()
        write_header(handle, args.block_size, total_blocks, chunks)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
