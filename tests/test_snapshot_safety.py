"""Regression tests for macOS snapshot archive and account-switch failure boundaries.

No Claude installation, login, launchd, credentials or network is accessed.
Only named functions extracted from the project source run with isolated _trash
fixtures. Tests intentionally simulate filesystem failures.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "core" / "claude-switch.sh"
TRASH = PROJECT / "_trash"


def function_source(name):
    text = SOURCE.read_text(encoding="utf-8")
    pattern = rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}"
    match = re.search(pattern, text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


class SnapshotSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)
        cls.archive = function_source("archive_current")
        cls.switch = function_source("switch_to")
        cls.valid = function_source("valid_account")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(
            prefix="snapshot-safety-", dir=str(TRASH)
        )
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.base = self.fixture / "state"
        self.data = self.fixture / "live"
        (self.base / "accounts" / "A").mkdir(parents=True)
        (self.base / "accounts" / "B").mkdir()
        self.data.mkdir()
        (self.base / "accounts" / "A" / "marker").write_text("old-A")
        (self.base / "accounts" / "B" / "marker").write_text("saved-B")
        (self.data / "marker").write_text("live-A")

    def run_shell(self, code, *, injection="none"):
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.fixture),
            "BASE": str(self.base),
            "DATA": str(self.data),
            "FIXTURE": str(self.fixture),
            "INJECT": injection,
            "LC_ALL": "C",
        }
        harness = r'''
set -u
log() { :; }
copy_tree() {
    if [ "$INJECT" = "copy_error" ]; then return 43; fi
    mkdir -p "$2" && cp -R "$1/." "$2/"
}
quit_claude() { return 0; }
open() { printf 'called' > "$FIXTURE/launched"; }
mv() {
    if [ "$INJECT" = "first_move_error" ] && [ "$1" = "$DATA" ]; then
        return 23
    fi
    if [ "$INJECT" = "copy_error" ] && [ "$1" = "$DATA" ]; then
        return 23
    fi
    if [ "$INJECT" = "final_rename_error" ] &&
       [ "$1" = "$BASE/accounts/A.new" ] &&
       [ "$2" = "$BASE/accounts/A" ]; then
        return 23
    fi
    if [ "$INJECT" = "old_rename_error" ] &&
       [ "$1" = "$BASE/accounts/A" ] &&
       [ "$2" = "$BASE/accounts/A.previous" ]; then
        return 23
    fi
    command mv "$@"
}
'''
        return subprocess.run(
            ["/bin/bash", "-c", harness + "\n" + self.valid + "\n" + code],
            env=env,
            cwd=self.fixture,
            text=True,
            capture_output=True,
            check=False,
            timeout=8,
        )

    def assert_data(self, expected_live="live-A", expected_old="old-A"):
        if expected_live is not None:
            self.assertEqual((self.data / "marker").read_text(), expected_live)
        if expected_old is not None:
            self.assertEqual(
                (self.base / "accounts" / "A" / "marker").read_text(),
                expected_old,
            )

    def test_final_rename_failure_rolls_back_and_fails(self):
        run = self.run_shell(
            self.archive + "\narchive_current A",
            injection="final_rename_error",
        )
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assert_data()
        self.assertFalse((self.base / "accounts" / "A.previous").exists())
        self.assertFalse((self.base / "accounts" / "A.new").exists())

    def test_existing_staging_is_not_deleted(self):
        staged = self.base / "accounts" / "A.new"
        staged.mkdir()
        (staged / "marker").write_text("pending-only-copy")
        run = self.run_shell(self.archive + "\narchive_current A")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertEqual((staged / "marker").read_text(), "pending-only-copy")

    def test_existing_recovery_archive_is_not_deleted(self):
        previous = self.base / "accounts" / "A.previous"
        previous.mkdir()
        (previous / "marker").write_text("recovery-only-copy")
        run = self.run_shell(self.archive + "\narchive_current A")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertEqual((previous / "marker").read_text(), "recovery-only-copy")

    def test_failure_to_preserve_old_snapshot_stops_and_restores_live(self):
        run = self.run_shell(
            self.archive + "\narchive_current A",
            injection="old_rename_error",
        )
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()

    def test_copy_fallback_failure_is_not_reported_as_success(self):
        run = self.run_shell(
            self.archive + "\narchive_current A",
            injection="copy_error",
        )
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()

    def test_successfully_archives_new_snapshot_and_retires_previous(self):
        run = self.run_shell(self.archive + "\narchive_current A")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(
            (self.base / "accounts" / "A" / "marker").read_text(), "live-A"
        )
        self.assertFalse(self.data.exists())
        self.assertFalse((self.base / "accounts" / "A.new").exists())
        self.assertFalse((self.base / "accounts" / "A.previous").exists())

    def test_switch_does_not_advance_if_archive_fails(self):
        (self.base / "current").write_text("A")
        code = (
            "archive_current() { return 23; }\n"
            + self.switch
            + "\nswitch_to B"
        )
        run = self.run_shell(code)
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertFalse((self.fixture / "launched").exists())

    def test_first_enrollment_does_not_advance_if_archive_fails(self):
        code = (
            "archive_current() { return 23; }\n"
            + self.switch
            + "\nswitch_to B"
        )
        run = self.run_shell(code)
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertFalse((self.base / "current").exists())
        self.assertFalse((self.fixture / "launched").exists())


if __name__ == "__main__":
    unittest.main()
