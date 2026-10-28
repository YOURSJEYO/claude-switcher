"""Multi-account (A-D) and optional keep-in-workspace regression tests.

Only named functions extracted from the core script run against isolated _trash
fixtures. No Claude installation, login state, launchd, credentials or network is
accessed. quit_claude/open/copy_tree/ditto are stubbed for the failure boundaries.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "core" / "claude-switch.sh"
TRASH = PROJECT / "_trash"

FUNCTIONS = (
    "valid_account",
    "status",
    "keep_path_safe",
    "stage_keep_paths",
    "restore_keep_paths",
    "archive_current",
    "switch_to",
)


def function_source(name):
    text = SOURCE.read_text(encoding="utf-8")
    pattern = rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}"
    match = re.search(pattern, text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


class MultiAccountTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise unittest.SkipTest("core status and keep staging use macOS du/date/ditto")
        TRASH.mkdir(exist_ok=True)
        cls.functions = "\n\n".join(
            function_source(name) for name in FUNCTIONS
        )

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(
            prefix="multi-account-", dir=str(TRASH)
        )
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.base = self.fixture / "state"
        self.data = self.fixture / "live"
        (self.base / "accounts").mkdir(parents=True)
        self.data.mkdir()

    def account(self, name):
        path = self.base / "accounts" / name
        path.mkdir(parents=True, exist_ok=True)
        return path

    def write_keep(self, *lines):
        (self.base / "keep-in-workspace.txt").write_text(
            "".join(line + "\n" for line in lines), encoding="utf-8"
        )

    def run_shell(self, code, *, injection="none"):
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.fixture),
            "BASE": str(self.base),
            "DATA": str(self.data),
            "LOG": str(self.fixture / "switch.log"),
            "FIXTURE": str(self.fixture),
            "INJECT": injection,
            "LC_ALL": "C",
        }
        harness = r'''
set -u
log() { printf '%s\n' "$1" >> "$LOG"; }
copy_tree() {
    if [ "$INJECT" = "copy_error" ]; then return 43; fi
    mkdir -p "$2" && cp -R "$1/." "$2/"
}
quit_claude() { return 0; }
open() { printf 'called' > "$FIXTURE/launched"; }
ditto() {
    if [ "$INJECT" = "stage_error" ]; then
        case "$1 $2" in *keep-stage*) return 44 ;; esac
    fi
    if [ "$INJECT" = "restore_error" ]; then
        case "$2" in "$DATA"|"$DATA/") return 45 ;; esac
    fi
    command ditto "$@"
}
'''
        return subprocess.run(
            ["/bin/bash", "-c", harness + "\n" + self.functions + "\n" + code],
            env=env,
            cwd=self.fixture,
            text=True,
            capture_output=True,
            check=False,
            timeout=20,
        )

    def fields(self, result):
        return dict(
            field.split("=", 1)
            for field in result.stdout.split()
            if field.count("=") == 1
        )

    def log_text(self):
        return (self.fixture / "switch.log").read_text(encoding="utf-8")

    def test_status_lists_three_archives_and_details(self):
        for name in ("A", "B", "C"):
            folder = self.account(name)
            (folder / "marker").write_text(name, encoding="utf-8")
        (self.base / "current").write_text("B", encoding="utf-8")
        result = self.run_shell("status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("\n"), 1)
        values = self.fields(result)
        self.assertEqual(values["current"], "B")
        self.assertEqual(values["hasA"], "1")
        self.assertEqual(values["hasB"], "1")
        self.assertEqual(values["hasC"], "1")
        self.assertEqual(values["hasD"], "0")
        self.assertEqual(values["accounts"], "A,B,C")
        self.assertNotIn("accD", values)
        for name in ("A", "B", "C"):
            self.assertRegex(values[f"acc{name}"], r"^\S+@\d{4}-\d{2}-\d{2}$")
            folder = str(self.base / "accounts" / name)
            expected_size = subprocess.run(
                ["du", "-sh", folder], capture_output=True, text=True, check=True,
            ).stdout.split()[0]
            expected_date = subprocess.run(
                ["date", "-r", folder, "+%Y-%m-%d"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
            size, date = values[f"acc{name}"].split("@", 1)
            self.assertEqual(size, expected_size)
            self.assertEqual(date, expected_date)

    def test_switch_creates_and_uses_new_account_c(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.data / "marker").write_text("live-A", encoding="utf-8")

        result = self.run_shell("switch_to C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK:已切换到账号C", result.stdout)
        self.assertEqual((self.base / "current").read_text().strip(), "C")
        self.assertTrue((self.fixture / "launched").exists())
        self.assertFalse((self.base / "accounts" / "C").exists())
        self.assertEqual(
            (self.base / "accounts" / "A" / "marker").read_text(), "live-A"
        )
        self.assertEqual(
            (self.base / "accounts" / "B" / "marker").read_text(), "saved-B"
        )
        self.assertFalse((self.data / "marker").exists())

    def test_switch_rejects_unknown_account(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.data / "marker").write_text("live-A", encoding="utf-8")

        result = self.run_shell("switch_to E")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("FAIL:"), result.stdout)
        self.assertEqual((self.base / "current").read_text().strip(), "A")
        self.assertEqual((self.data / "marker").read_text(), "live-A")
        self.assertFalse((self.base / "accounts" / "E").exists())
        self.assertFalse((self.fixture / "launched").exists())

    def test_keep_file_carries_only_listed_files_across_accounts(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        self.account("B").joinpath("settings.json").write_text("from-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.data / "settings.json").write_text("from-A", encoding="utf-8")
        (self.data / "other.txt").write_text("not-kept", encoding="utf-8")
        (self.data / "skills").mkdir()
        (self.data / "skills" / "one.txt").write_text("skill-A", encoding="utf-8")
        self.write_keep("settings.json", "skills/")

        result = self.run_shell("switch_to B")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "current").read_text().strip(), "B")
        self.assertEqual((self.data / "settings.json").read_text(), "from-A")
        self.assertEqual((self.data / "skills" / "one.txt").read_text(), "skill-A")
        self.assertFalse((self.data / "other.txt").exists())
        self.assertEqual((self.data / "marker").read_text(), "saved-B")
        self.assertEqual(
            (self.base / "accounts" / "A" / "settings.json").read_text(), "from-A"
        )
        self.assertEqual(
            (self.base / "accounts" / "A" / "skills" / "one.txt").read_text(), "skill-A"
        )
        self.assertTrue((self.base / "accounts" / "A" / "other.txt").exists())
        self.assertEqual(
            (self.base / "accounts" / "B" / "settings.json").read_text(), "from-B"
        )
        self.assertFalse((self.base / "keep-stage").exists())
        self.assertIn("已收起 2 条路径", self.log_text())

    def test_invalid_keep_entries_are_skipped_without_breaking_switch(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.data / "settings.json").write_text("from-A", encoding="utf-8")
        (self.fixture / "evil.txt").write_text("outside", encoding="utf-8")
        self.write_keep("../evil.txt", "/etc/hosts", ".", "settings.json")

        result = self.run_shell("switch_to B")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "current").read_text().strip(), "B")
        self.assertEqual((self.data / "settings.json").read_text(), "from-A")
        self.assertFalse((self.data / "evil.txt").exists())
        self.assertFalse((self.data / "hosts").exists())
        self.assertFalse((self.base / "keep-stage").exists())
        log = self.log_text()
        self.assertIn("WARN:", log)
        self.assertIn("../evil.txt", log)
        self.assertIn("已收起 1 条路径", log)

    def test_symlink_keep_entries_are_rejected(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.fixture / "outside.txt").write_text("outside", encoding="utf-8")
        (self.data / "link.txt").symlink_to(self.fixture / "outside.txt")
        self.write_keep("link.txt")

        result = self.run_shell("switch_to B")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.data / "link.txt").exists())
        self.assertFalse((self.base / "keep-stage").exists())
        self.assertIn("符号链接", self.log_text())

    def test_keep_path_through_symlinked_directory_is_rejected(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        outside = self.fixture / "outside"
        outside.mkdir()
        (outside / "secret.txt").write_text("outside", encoding="utf-8")
        (self.data / "linked").symlink_to(outside, target_is_directory=True)
        self.write_keep("linked/secret.txt")

        result = self.run_shell("switch_to B")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.data / "linked").exists())
        self.assertFalse((self.base / "keep-stage").exists())
        self.assertIn("符号链接", self.log_text())

    def test_stage_failure_aborts_without_touching_live_data(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.data / "settings.json").write_text("from-A", encoding="utf-8")
        (self.data / "marker").write_text("live-A", encoding="utf-8")
        self.write_keep("settings.json")

        result = self.run_shell("switch_to B", injection="stage_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL:", result.stdout)
        self.assertEqual((self.base / "current").read_text().strip(), "A")
        self.assertEqual((self.data / "settings.json").read_text(), "from-A")
        self.assertEqual((self.data / "marker").read_text(), "live-A")
        self.assertFalse((self.base / "keep-stage").exists())
        self.assertFalse((self.fixture / "launched").exists())

    def test_restore_failure_keeps_stage_for_recovery(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.data / "settings.json").write_text("from-A", encoding="utf-8")
        self.write_keep("settings.json")

        result = self.run_shell("switch_to B", injection="restore_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL:", result.stdout)
        self.assertEqual((self.base / "current").read_text().strip(), "B")
        self.assertTrue((self.base / "keep-stage" / "settings.json").exists())
        self.assertEqual(
            (self.base / "keep-stage" / "settings.json").read_text(), "from-A"
        )
        self.assertEqual(
            (self.base / "accounts" / "A" / "settings.json").read_text(), "from-A"
        )
        self.assertFalse((self.fixture / "launched").exists())

    def test_empty_keep_file_is_a_noop(self):
        self.account("A").joinpath("marker").write_text("old-A", encoding="utf-8")
        self.account("B").joinpath("marker").write_text("saved-B", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.data / "marker").write_text("live-A", encoding="utf-8")
        (self.base / "keep-in-workspace.txt").write_text("", encoding="utf-8")

        result = self.run_shell("switch_to B")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "current").read_text().strip(), "B")
        self.assertEqual((self.data / "marker").read_text(), "saved-B")
        self.assertFalse((self.base / "keep-stage").exists())
        self.assertNotIn("已收起", self.log_text())

    def test_same_account_restores_missing_live_data(self):
        self.account("A").joinpath("marker").write_text("saved-A", encoding="utf-8")
        (self.base / "current").write_text("A", encoding="utf-8")
        self.data.rmdir()

        result = self.run_shell("switch_to A")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("INFO:当前已是账号A", result.stdout)
        self.assertEqual((self.data / "marker").read_text(), "saved-A")
        self.assertTrue((self.fixture / "launched").exists())

    def test_first_enrollment_also_carries_keep_paths(self):
        (self.data / "settings.json").write_text("first-run", encoding="utf-8")
        self.write_keep("settings.json")

        result = self.run_shell("switch_to B")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "current").read_text().strip(), "B")
        self.assertEqual(
            (self.base / "accounts" / "A" / "settings.json").read_text(),
            "first-run",
        )
        self.assertEqual((self.data / "settings.json").read_text(), "first-run")
        self.assertFalse((self.base / "keep-stage").exists())

    def test_first_enrollment_into_a_restores_keep_paths(self):
        (self.data / "settings.json").write_text("first-run", encoding="utf-8")
        self.write_keep("settings.json")

        result = self.run_shell("switch_to A")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NOTE:已将当前登录收编为账号A", result.stdout)
        self.assertEqual((self.base / "current").read_text().strip(), "A")
        self.assertEqual((self.data / "settings.json").read_text(), "first-run")
        self.assertEqual(
            (self.base / "accounts" / "A" / "settings.json").read_text(),
            "first-run",
        )
        self.assertFalse((self.base / "keep-stage").exists())


if __name__ == "__main__":
    unittest.main()
