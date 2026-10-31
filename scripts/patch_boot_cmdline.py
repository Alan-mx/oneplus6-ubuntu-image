#!/usr/bin/env python3
"""Replace the command line in an Android boot image v0."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


BOOT_MAGIC = b"ANDROID!"
CMDLINE_OFFSET = 64
CMDLINE_SIZE = 512


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("cmdline")
    args = parser.parse_args()

    encoded = args.cmdline.encode("ascii")
    if len(encoded) >= CMDLINE_SIZE:
        raise ValueError("kernel command line is too long for Android boot v0")

    data = bytearray(args.image.read_bytes())
    if len(data) < CMDLINE_OFFSET + CMDLINE_SIZE or data[:8] != BOOT_MAGIC:
        raise ValueError("invalid Android boot image")

    header_version = struct.unpack_from("<I", data, 40)[0]
    if header_version != 0:
        raise ValueError(f"unsupported boot header version: {header_version}")

    data[CMDLINE_OFFSET : CMDLINE_OFFSET + CMDLINE_SIZE] = encoded.ljust(
        CMDLINE_SIZE, b"\0"
    )
    args.image.write_bytes(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
