from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "snapshot_source.py"


def run(*args: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        args,
        cwd=cwd,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class SnapshotSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "source"
        self.root.mkdir()
        run("git", "init", str(self.root))
        run("git", "-C", str(self.root), "config", "user.name", "Snapshot Test")
        run("git", "-C", str(self.root), "config", "user.email", "snapshot@example.invalid")
        (self.root / ".gitignore").write_text("local.secret\nbuild/\n", encoding="utf-8")
        (self.root / "tracked.txt").write_text("committed\n", encoding="utf-8")
        (self.root / "build").mkdir()
        (self.root / "build" / "generated.txt").write_text("ignored build\n", encoding="utf-8")
        run("git", "-C", str(self.root), "add", ".gitignore", "tracked.txt")
        run("git", "-C", str(self.root), "commit", "-m", "initial")
        self.commit = run("git", "-C", str(self.root), "rev-parse", "HEAD").stdout.strip()

    def invoke(self, name: str, *extra: str) -> tuple[subprocess.CompletedProcess, Path, Path]:
        destination = self.root.parent / f"snapshot-{name}"
        manifest = self.root.parent / f"{name}.json"
        result = run(
            sys.executable,
            str(SCRIPT),
            str(self.root),
            str(destination),
            "--expected-commit",
            self.commit,
            "--manifest",
            str(manifest),
            *extra,
            check=False,
        )
        return result, destination, manifest

    def test_dirty_worktree_snapshot_includes_only_build_inputs(self) -> None:
        (self.root / "tracked.txt").write_text("modified\n", encoding="utf-8")
        (self.root / "new-source.txt").write_text("untracked source\n", encoding="utf-8")
        (self.root / "local.secret").write_text("must not be copied\n", encoding="utf-8")

        result, destination, manifest_path = self.invoke("dirty")

        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertTrue(manifest["dirty"])
        self.assertEqual(manifest["commit"], self.commit)
        self.assertEqual((destination / "tracked.txt").read_text(encoding="utf-8"), "modified\n")
        self.assertEqual((destination / "new-source.txt").read_text(encoding="utf-8"), "untracked source\n")
        self.assertFalse((destination / "local.secret").exists())
        self.assertFalse((destination / ".git").exists())
        self.assertFalse((destination / "build").exists())

    def test_release_snapshot_refuses_dirty_source_without_creating_destination(self) -> None:
        (self.root / "tracked.txt").write_text("modified\n", encoding="utf-8")

        result, destination, _manifest_path = self.invoke("release", "--require-clean")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean source worktree", result.stderr)
        self.assertFalse(destination.exists())

    def test_clean_snapshot_is_repeatable(self) -> None:
        first, first_destination, first_manifest = self.invoke("first")
        second, second_destination, second_manifest = self.invoke("second")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        one = json.loads(first_manifest.read_text(encoding="utf-8"))
        two = json.loads(second_manifest.read_text(encoding="utf-8"))
        self.assertFalse(one["dirty"])
        self.assertEqual(one["tree_sha256"], two["tree_sha256"])
        self.assertEqual((first_destination / "tracked.txt").read_bytes(), (second_destination / "tracked.txt").read_bytes())


if __name__ == "__main__":
    unittest.main()
