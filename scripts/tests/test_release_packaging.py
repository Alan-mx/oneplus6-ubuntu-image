from __future__ import annotations

import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
MAKE_SEGMENTS = SCRIPTS / "make_sparse_segments.py"
PACKAGE_RELEASE = SCRIPTS / "package_segmented_release.py"
WRITE_MANIFEST = SCRIPTS / "write_build_manifest.py"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        args,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class ReleasePackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def create_segments(self) -> tuple[Path, Path]:
        raw = self.root / "rootfs.raw"
        data = (b"orbital-rootfs!" * (2 * 1024 * 1024 // 15 + 1))[: 2 * 1024 * 1024]
        raw.write_bytes(data)
        segment_dir = self.root / "segments"
        run(
            sys.executable,
            str(MAKE_SEGMENTS),
            str(raw),
            str(segment_dir),
            "--segment-mib",
            "1",
            "--part-prefix",
            "rootfs",
        )
        return raw, segment_dir

    def test_sparse_segments_cover_raw_image_and_record_hashes(self) -> None:
        raw, segment_dir = self.create_segments()
        manifest = json.loads((segment_dir / "manifest.json").read_text(encoding="utf-8"))

        self.assertEqual(manifest["format"]["total_blocks"], 512)
        self.assertEqual(manifest["source_raw"]["sha256"], sha256(raw))
        self.assertEqual(len(manifest["segments"]), 2)
        self.assertEqual(sum(item["block_count"] for item in manifest["segments"]), 512)
        for item in manifest["segments"]:
            segment = segment_dir / item["file"]
            self.assertEqual(item["sha256"], sha256(segment))
            magic = struct.unpack("<I", segment.read_bytes()[:4])[0]
            self.assertEqual(magic, 0xED26FF3A)

    def test_zip_contains_verified_release_metadata(self) -> None:
        _raw, segment_dir = self.create_segments()
        (segment_dir / "README.md").write_text("flash instructions\n", encoding="utf-8")
        boot = self.root / "oneplus6-boot.img"
        boot.write_bytes(b"boot-image")
        flash = self.root / "flash.ps1"
        flash.write_text("Write-Host flash\n", encoding="utf-8")
        verification = self.root / "verification.json"
        verification.write_text('{"status":"verified"}\n', encoding="utf-8")
        output = self.root / "release.zip"
        report_path = self.root / "package-report.json"

        run(
            sys.executable,
            str(PACKAGE_RELEASE),
            str(segment_dir),
            str(boot),
            str(flash),
            str(verification),
            str(output),
            "--report",
            str(report_path),
            "--package-name",
            "oneplus6-segmented-flash",
        )

        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["status"], "verified")
        self.assertTrue(report["archive"]["zip64"])
        self.assertEqual(report["archive"]["sha256"], sha256(output))

        with zipfile.ZipFile(output) as archive:
            names = set(archive.namelist())
            root_name = "oneplus6-segmented-flash"
            release_name = f"{root_name}/release.json"
            sums_name = f"{root_name}/SHA256SUMS.txt"
            self.assertIn(release_name, names)
            self.assertIn(sums_name, names)
            release = json.loads(archive.read(release_name))
            self.assertEqual(release["device_id"], "oneplus-enchilada")
            manifest_path = segment_dir / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(
                release["rootfs_segment_manifest"]["sha256"],
                sha256(manifest_path),
            )
            checksum_lines = archive.read(sums_name).decode("ascii").splitlines()
            checksums = {
                name: digest
                for digest, name in (line.split("  ", 1) for line in checksum_lines)
            }
            self.assertEqual(checksums["oneplus6-boot.img"], sha256(boot))
            for segment in manifest["segments"]:
                self.assertEqual(checksums[segment["file"]], segment["sha256"])
                self.assertIn(f"{root_name}/{segment['file']}", names)

    def test_build_manifest_records_dirty_source_without_credentials(self) -> None:
        repository = self.root / "repo"
        config = repository / "config"
        prepared = repository / "prepared"
        state = repository / "state"
        work = repository / "work"
        out = repository / "out"
        segments = out / "oneplus6-rootfs-orbital-segments"
        for path in (config, prepared / "patches", state, work, segments):
            path.mkdir(parents=True, exist_ok=True)

        orbital_commit = "1" * 40
        kernel_commit = "2" * 40
        source_lock_text = (
            "component\trepository\tcommit\tversion\tlicense\n"
            f"kernel\thttps://example.invalid/kernel.git\t{kernel_commit}\t7.1.0\ttest\n"
            f"orbital\thttps://example.invalid/orbital.git\t{orbital_commit}\t1.0\ttest\n"
        )
        (config / "source-revisions.lock.tsv").write_text(source_lock_text, encoding="utf-8")
        (prepared / "source-revisions.lock.tsv").write_text(source_lock_text, encoding="utf-8")
        (prepared / "patches" / "0001-test.patch").write_text("patch\n", encoding="utf-8")
        (prepared / "prepared.sha256").write_text("digest\n", encoding="utf-8")
        (config / "build.env").write_text(
            "RELEASE_NAME=test\nRELEASE_VERSION=v-test\nDEVICE_ID=oneplus-enchilada\n"
            "UBUNTU_VERSION=test\nKERNEL_RELEASE=7.1.0\n",
            encoding="utf-8",
        )
        for name in (
            "apk-sha256.lock",
            "ubuntu-packages.lock.tsv",
            "builder-packages.lock.tsv",
            "kernel-builder-packages.lock.tsv",
        ):
            (config / name).write_text("locked\n", encoding="utf-8")
        for label in ("base", "orbital"):
            (state / f"ubuntu-packages-{label}.tsv").write_text(
                "locked\n", encoding="utf-8"
            )

        (work / "orbital-source-manifest.json").write_text(
            json.dumps(
                {
                    "commit": orbital_commit,
                    "dirty": True,
                    "tree_sha256": "3" * 64,
                }
            ),
            encoding="utf-8",
        )
        (state / "build-state.json").write_text(
            json.dumps(
                {
                    "phase": "complete",
                    "oneplus6_image_commit": "4" * 40,
                    "oneplus6_image_dirty": True,
                    "oneplus6_image_tree_sha256": "5" * 64,
                }
            ),
            encoding="utf-8",
        )
        (state / "verification.json").write_text(
            json.dumps(
                {
                    "boot": {"dtb_sha256_suffix_match": True},
                    "base_sparse": {"logical_size": 1024},
                    "orbital_sparse": {"logical_size": 1024},
                }
            ),
            encoding="utf-8",
        )
        (state / "package-report.json").write_text(
            json.dumps({"status": "verified", "archive": {"sha256": "6" * 64}}),
            encoding="utf-8",
        )
        (segments / "manifest.json").write_text('{"segments":[]}\n', encoding="utf-8")
        (out / "dummy-artifact.bin").write_bytes(b"artifact")

        run(
            sys.executable,
            str(WRITE_MANIFEST),
            "--root",
            str(repository),
            "--work",
            str(work),
            "--out",
            str(out),
            "--state",
            str(state),
            "--config",
            str(config / "build.env"),
            "--source-lock",
            str(config / "source-revisions.lock.tsv"),
            "--prepared",
            str(prepared),
            "--platform",
            "test-platform",
            "--builder-image",
            "sha256:builder",
            "--kernel-builder-image",
            "sha256:kernel-builder",
        )

        manifest = json.loads((out / "build-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["status"], "verified")
        self.assertFalse(manifest["build"]["publicly_reproducible"])
        orbital = next(item for item in manifest["sources"] if item["component"] == "orbital")
        self.assertTrue(orbital["dirty"])
        kernel = next(item for item in manifest["sources"] if item["component"] == "kernel")
        self.assertTrue(kernel["dirty"])
        artifact_names = {item["path"] for item in manifest["artifacts"]}
        self.assertIn("out/SHA256SUMS.txt", artifact_names)
        self.assertIn("out/dummy-artifact.bin", artifact_names)
        rendered = json.dumps(manifest).lower()
        for forbidden in (
            "ssh_password",
            "password_hash",
            "ssh_key_fingerprint",
            "orbital.diff",
        ):
            self.assertNotIn(forbidden, rendered)


if __name__ == "__main__":
    unittest.main()
