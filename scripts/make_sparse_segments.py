#!/usr/bin/env python3
"""Build and verify contiguous Android sparse segments from a raw image."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import struct
from pathlib import Path


SPARSE_MAGIC = 0xED26FF3A
FILE_HEADER_SIZE = 28
CHUNK_HEADER_SIZE = 12
CHUNK_TYPE_RAW = 0xCAC1
CHUNK_TYPE_DONT_CARE = 0xCAC3
MAX_CHUNK_BLOCKS = 32768
COPY_BUFFER_SIZE = 4 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(COPY_BUFFER_SIZE), b""):
            digest.update(data)
    return digest.hexdigest()


def append_chunks(
    chunks: list[tuple[int, int, int]], chunk_type: int, start: int, count: int
) -> None:
    while count:
        current = min(count, MAX_CHUNK_BLOCKS)
        chunks.append((chunk_type, start, current))
        start += current
        count -= current


def sparse_header(block_size: int, total_blocks: int, total_chunks: int) -> bytes:
    return struct.pack(
        "<IHHHHIIII",
        SPARSE_MAGIC,
        1,
        0,
        FILE_HEADER_SIZE,
        CHUNK_HEADER_SIZE,
        block_size,
        total_blocks,
        total_chunks,
        0,
    )


def chunk_header(chunk_type: int, blocks: int, total_size: int) -> bytes:
    return struct.pack("<HHII", chunk_type, 0, blocks, total_size)


def copy_exact(source, destination, byte_count: int) -> None:
    remaining = byte_count
    while remaining:
        data = source.read(min(COPY_BUFFER_SIZE, remaining))
        if not data:
            raise ValueError("raw image ended unexpectedly")
        destination.write(data)
        remaining -= len(data)


def build_segment(
    raw_path: Path,
    output_path: Path,
    block_size: int,
    total_blocks: int,
    start_block: int,
    block_count: int,
) -> list[tuple[int, int, int]]:
    chunks: list[tuple[int, int, int]] = []
    append_chunks(chunks, CHUNK_TYPE_DONT_CARE, 0, start_block)
    append_chunks(chunks, CHUNK_TYPE_RAW, start_block, block_count)
    after_start = start_block + block_count
    append_chunks(chunks, CHUNK_TYPE_DONT_CARE, after_start, total_blocks - after_start)

    temporary = output_path.with_suffix(output_path.suffix + ".tmp")
    with raw_path.open("rb") as source, temporary.open("wb") as destination:
        destination.write(sparse_header(block_size, total_blocks, len(chunks)))
        for chunk_type, logical_start, blocks in chunks:
            if chunk_type == CHUNK_TYPE_DONT_CARE:
                destination.write(chunk_header(chunk_type, blocks, CHUNK_HEADER_SIZE))
                continue

            byte_count = blocks * block_size
            source.seek(logical_start * block_size)
            destination.write(
                chunk_header(
                    chunk_type,
                    blocks,
                    CHUNK_HEADER_SIZE + byte_count,
                )
            )
            copy_exact(source, destination, byte_count)
        destination.flush()
        os.fsync(destination.fileno())
    os.replace(temporary, output_path)
    return chunks


def parse_and_verify_segment(
    raw_path: Path,
    segment_path: Path,
    part: int,
    block_size: int,
    total_blocks: int,
    expected_start: int,
    expected_blocks: int,
) -> dict[str, object]:
    with segment_path.open("rb") as segment, raw_path.open("rb") as raw:
        header = segment.read(FILE_HEADER_SIZE)
        if len(header) != FILE_HEADER_SIZE:
            raise ValueError(f"{segment_path}: truncated sparse header")
        (
            magic,
            major,
            _minor,
            file_header_size,
            chunk_header_size,
            actual_block_size,
            actual_total_blocks,
            total_chunks,
            _checksum,
        ) = struct.unpack("<IHHHHIIII", header)
        if magic != SPARSE_MAGIC:
            raise ValueError(f"{segment_path}: invalid sparse magic")
        if major != 1:
            raise ValueError(f"{segment_path}: unsupported sparse version {major}")
        if (file_header_size, chunk_header_size) != (
            FILE_HEADER_SIZE,
            CHUNK_HEADER_SIZE,
        ):
            raise ValueError(f"{segment_path}: unexpected sparse header sizes")
        if (actual_block_size, actual_total_blocks) != (block_size, total_blocks):
            raise ValueError(f"{segment_path}: logical geometry mismatch")

        logical_block = 0
        chunk_types: set[int] = set()
        raw_ranges: list[tuple[int, int]] = []
        expected_end = expected_start + expected_blocks
        for chunk_number in range(total_chunks):
            raw_header = segment.read(CHUNK_HEADER_SIZE)
            if len(raw_header) != CHUNK_HEADER_SIZE:
                raise ValueError(f"{segment_path}: truncated chunk {chunk_number}")
            chunk_type, _reserved, blocks, total_size = struct.unpack(
                "<HHII", raw_header
            )
            if blocks == 0:
                raise ValueError(f"{segment_path}: empty chunk {chunk_number}")
            if chunk_type == CHUNK_TYPE_DONT_CARE:
                if total_size != CHUNK_HEADER_SIZE:
                    raise ValueError(
                        f"{segment_path}: malformed DONT_CARE chunk {chunk_number}"
                    )
                chunk_end = logical_block + blocks
                if logical_block < expected_end and expected_start < chunk_end:
                    raise ValueError(
                        f"{segment_path}: DONT_CARE overlaps this segment's RAW range"
                    )
            elif chunk_type == CHUNK_TYPE_RAW:
                expected_size = CHUNK_HEADER_SIZE + blocks * block_size
                if total_size != expected_size:
                    raise ValueError(
                        f"{segment_path}: malformed RAW chunk {chunk_number}"
                    )
                chunk_end = logical_block + blocks
                if logical_block < expected_start or chunk_end > expected_end:
                    raise ValueError(
                        f"{segment_path}: RAW chunk escapes this segment's range"
                    )
                raw_ranges.append((logical_block, chunk_end))
                raw.seek(logical_block * block_size)
                remaining = blocks * block_size
                while remaining:
                    expected = raw.read(min(COPY_BUFFER_SIZE, remaining))
                    actual = segment.read(min(COPY_BUFFER_SIZE, remaining))
                    if not expected or expected != actual:
                        raise ValueError(
                            f"{segment_path}: RAW data mismatch at logical block "
                            f"{logical_block}"
                        )
                    remaining -= len(expected)
            else:
                raise ValueError(
                    f"{segment_path}: unsupported chunk type "
                    f"0x{chunk_type:04X}; only RAW and DONT_CARE are allowed"
                )
            chunk_types.add(chunk_type)
            logical_block += blocks

        if logical_block != total_blocks:
            raise ValueError(
                f"{segment_path}: logical block coverage {logical_block} "
                f"!= {total_blocks}"
            )
        if segment.read(1):
            raise ValueError(f"{segment_path}: trailing data after sparse chunks")

    if chunk_types != {CHUNK_TYPE_RAW, CHUNK_TYPE_DONT_CARE}:
        raise ValueError(f"{segment_path}: expected both RAW and DONT_CARE chunks")

    cursor = expected_start
    for raw_start, raw_end in raw_ranges:
        if raw_start != cursor:
            raise ValueError(f"{segment_path}: RAW range has a gap or overlap")
        cursor = raw_end
    if cursor != expected_end:
        raise ValueError(f"{segment_path}: RAW range does not cover this segment")

    return {
        "part": part,
        "file": segment_path.name,
        "start_block": expected_start,
        "block_count": expected_blocks,
        "start_byte": expected_start * block_size,
        "size_bytes": expected_blocks * block_size,
        "file_size_bytes": segment_path.stat().st_size,
        "sha256": sha256_file(segment_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--block-size", type=int, default=4096)
    parser.add_argument("--segment-mib", type=int, default=384)
    parser.add_argument("--reuse-existing", action="store_true")
    parser.add_argument(
        "--part-prefix",
        default="oneplus6-rootfs-orbital-v15-part",
    )
    args = parser.parse_args()

    if args.block_size != 4096:
        raise ValueError("only 4096-byte blocks are supported")
    if args.segment_mib < 1:
        raise ValueError("segment size must be positive")
    raw_size = args.raw.stat().st_size
    if raw_size == 0 or raw_size % args.block_size:
        raise ValueError("raw image size must be a positive multiple of block size")
    if args.output_dir.exists() and not args.reuse_existing:
        raise FileExistsError(f"output directory already exists: {args.output_dir}")

    total_blocks = raw_size // args.block_size
    segment_bytes = args.segment_mib * 1024 * 1024
    segment_blocks = segment_bytes // args.block_size
    part_count = (total_blocks + segment_blocks - 1) // segment_blocks
    args.output_dir.mkdir(parents=True, exist_ok=True)

    segments: list[dict[str, object]] = []
    for part_index in range(part_count):
        start_block = part_index * segment_blocks
        block_count = min(segment_blocks, total_blocks - start_block)
        path = args.output_dir / (
            f"{args.part_prefix}-"
            f"{part_index + 1:03d}-of-{part_count:03d}.img"
        )
        if args.reuse_existing:
            if not path.is_file():
                raise FileNotFoundError(f"existing segment not found: {path}")
        else:
            build_segment(
                args.raw,
                path,
                args.block_size,
                total_blocks,
                start_block,
                block_count,
            )
        segments.append(
            parse_and_verify_segment(
                args.raw,
                path,
                part_index + 1,
                args.block_size,
                total_blocks,
                start_block,
                block_count,
            )
        )

    expected_start = 0
    for segment in segments:
        if segment["start_block"] != expected_start:
            raise ValueError("segment coverage has a gap or overlap")
        expected_start += int(segment["block_count"])
    if expected_start != total_blocks:
        raise ValueError("segments do not cover the complete raw image")
    if max(int(segment["file_size_bytes"]) for segment in segments) > 512 * 1024 * 1024:
        raise ValueError("a sparse segment exceeds the 512 MiB safety limit")

    manifest = {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "format": {
            "sparse_magic": f"0x{SPARSE_MAGIC:08X}",
            "block_size": args.block_size,
            "total_blocks": total_blocks,
            "logical_size_bytes": raw_size,
            "segment_mib": args.segment_mib,
            "chunk_types": ["RAW", "DONT_CARE"],
        },
        "source_raw": {
            "file": args.raw.name,
            "size_bytes": raw_size,
            "sha256": sha256_file(args.raw),
        },
        "segments": segments,
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
