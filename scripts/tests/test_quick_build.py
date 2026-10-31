from __future__ import annotations

import hashlib
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def config_values() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in (ROOT / "config" / "build.env").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values


class QuickBuildTests(unittest.TestCase):
    def test_default_full_build_uses_locked_prebuilt_inputs(self) -> None:
        build = (ROOT / "scripts" / "build.sh").read_text(encoding="utf-8")
        build_ps1 = (ROOT / "build.ps1").read_text(encoding="utf-8")

        self.assertIn('BUILD_MODE="${BUILD_MODE:-quick}"', build)
        self.assertIn('"-e", "BUILD_MODE=quick"', build_ps1)
        self.assertIn("prepare_quick_inputs", build)
        self.assertIn("copy_prebuilt_boot", build)
        self.assertNotIn("PREPARED_DIR/qrtr", build)

        main = build.split("main() {", 1)[1].split("\n}\n\npackage_release()", 1)[0]
        self.assertIn("prepare_quick_inputs", main)
        self.assertIn("copy_prebuilt_boot", main)
        self.assertNotIn("build_initramfs", main)
        self.assertNotIn("build_boot_image", main)
        self.assertNotIn("prepare-inputs.sh", main)

    def test_checked_in_prebuilt_inputs_match_build_lock(self) -> None:
        values = config_values()
        expected = {
            "inputs/boot/oneplus6-boot-gpu-fix.img": values["BOOT_IMAGE_OVERRIDE_SHA256"],
            "inputs/tqftpserv/tqftpserv": values["TQFPSERV_SHA256"],
            "inputs/pd-mapper/pd-mapper": values["PD_MAPPER_SHA256"],
            "inputs/rmtfs/rmtfs": values["RMTFS_SHA256"],
        }
        for relative_path, digest in expected.items():
            path = ROOT / relative_path
            with self.subTest(path=relative_path):
                self.assertTrue(path.is_file(), f"missing quick-build input: {path}")
                self.assertEqual(sha256(path), digest)

    def test_quick_build_inputs_are_trackable_and_local_caches_ignored(self) -> None:
        ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("/inputs/*", ignore)
        for path in (
            "inputs/boot/oneplus6-boot-gpu-fix.img",
            "inputs/tqftpserv/tqftpserv",
            "inputs/pd-mapper/pd-mapper",
            "inputs/rmtfs/rmtfs",
        ):
            with self.subTest(path=path):
                result = subprocess.run(
                    ["git", "-C", str(ROOT), "check-ignore", "--quiet", path],
                    check=False,
                )
                self.assertEqual(result.returncode, 1, f"quick-build input is ignored: {path}")


if __name__ == "__main__":
    unittest.main()
