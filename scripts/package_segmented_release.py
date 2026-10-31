#!/usr/bin/env python3
"""Create and verify a ZIP64 share package for segmented OnePlus 6 images."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import zipfile
from pathlib import Path


COPY_BUFFER_SIZE = 4 * 1024 * 1024
EXPECTED_BOOT_SHA256 = (
    "215f7bd5fd5deb7a3257dba893ce9eaad514ef1d29e346580852a7d8db3948b5"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(COPY_BUFFER_SIZE), b""):
            digest.update(data)
    return digest.hexdigest()


def add_file(
    archive: zipfile.ZipFile, source: Path, archive_name: str
) -> None:
    with source.open("rb") as source_handle, archive.open(
        archive_name,
        "w",
        force_zip64=True,
    ) as destination:
        shutil.copyfileobj(source_handle, destination, length=COPY_BUFFER_SIZE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("segment_dir", type=Path)
    parser.add_argument("boot_image", type=Path)
    parser.add_argument("flash_script", type=Path)
    parser.add_argument("device_verification", type=Path)
    parser.add_argument("output_zip", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--package-name",
        default="oneplus6-v15-segmented",
    )
    args = parser.parse_args()

    if args.output_zip.exists():
        raise FileExistsError(f"output ZIP already exists: {args.output_zip}")
    manifest_path = args.segment_dir / "manifest.json"
    readme_path = args.segment_dir / "README.md"
    for required in (
        manifest_path,
        readme_path,
        args.boot_image,
        args.flash_script,
        args.device_verification,
    ):
        if not required.is_file():
            raise FileNotFoundError(required)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if sha256_file(args.boot_image) != EXPECTED_BOOT_SHA256:
        raise ValueError("boot image SHA-256 does not match V14")

    files: list[tuple[Path, str]] = [
        (readme_path, "README.md"),
        (manifest_path, "manifest.json"),
        (args.device_verification, "verification.json"),
        (args.flash_script, "flash.ps1"),
        (args.boot_image, "oneplus6-boot.img"),
    ]
    for segment in manifest["segments"]:
        source = args.segment_dir / segment["file"]
        if not source.is_file():
            raise FileNotFoundError(source)
        if source.stat().st_size != segment["file_size_bytes"]:
            raise ValueError(f"segment size mismatch: {source}")
        if sha256_file(source) != segment["sha256"]:
            raise ValueError(f"segment SHA-256 mismatch: {source}")
        files.append((source, segment["file"]))

    checksums = "".join(
        f"{sha256_file(path)}  {archive_name}\n" for path, archive_name in files
    )
    package_root = args.package_name
    args.output_zip.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(
        args.output_zip,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=6,
        allowZip64=True,
    ) as archive:
        for path, archive_name in files:
            add_file(archive, path, f"{package_root}/{archive_name}")
        archive.writestr(
            f"{package_root}/SHA256SUMS.txt",
            checksums.encode("ascii"),
            compress_type=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        )

    with zipfile.ZipFile(args.output_zip, mode="r") as archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            raise ValueError(f"ZIP integrity check failed at {bad_member}")
        names = sorted(archive.namelist())
        uncompressed_size = sum(item.file_size for item in archive.infolist())
    compressed_size = args.output_zip.stat().st_size

    report = {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "status": "verified",
        "archive": {
            "path": str(args.output_zip),
            "size_bytes": compressed_size,
            "sha256": sha256_file(args.output_zip),
            "zip64": True,
            "compression": "deflate",
            "uncompressed_size_bytes": uncompressed_size,
            "entry_count": len(names),
        },
        "contents": names,
        "boot_sha256": EXPECTED_BOOT_SHA256,
        "segment_count": len(manifest["segments"]),
        "logical_image_size_bytes": manifest["format"]["logical_size_bytes"],
    }
    if args.report is not None:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
