"""macOS menu-bar regression tests. Only fake scripts under _trash are executed."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SCENARIOS = (
    "startup_once", "multi_account_status", "first_use_cd_note", "legacy_status_fallback",
    "invalid_multi_account_status", "warnings_allowed", "local_status_refresh", "fresh_audit", "failed_check",
    "incomplete_check", "duplicate_check", "duplicate_overwrite", "empty_check",
    "unknown_check_code", "empty_check_code", "nonzero_check", "timeout_check",
    "invalid_status", "nonzero_status", "switch_note_then_failure", "empty_switch",
    "nonzero_switch", "timeout_switch", "busy_guard", "fix_guard", "failed_fix",
    "checking_allows_quit", "hide_after_success", "reopen_cancels_hide",
    "window_lifecycle", "termination_guard",
)


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"),
                     "SwiftUI menu-bar tests require macOS and swiftc")
class MenuBarModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        trash = PROJECT / "_trash"
        trash.mkdir(exist_ok=True)
        cls.build = tempfile.TemporaryDirectory(prefix="menu-bar-tests-", dir=trash)
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = Path(cls.build.name) / "MenuBarModelTests"
        result = subprocess.run(
            ["swiftc", "-parse-as-library", "-warnings-as-errors", "-D", "CLAUDE_SWITCHER_TESTS",
             "-target", f"{platform.machine()}-apple-macos13.0",
             "-module-cache-path", str(Path(cls.build.name) / "module-cache"),
             str(PROJECT / "app/main.swift"),
             str(PROJECT / "tests/MenuBarModelTests.swift"),
             "-o", str(cls.binary), "-framework", "SwiftUI", "-framework", "AppKit"],
            cwd=PROJECT, capture_output=True, text=True, timeout=180,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)


def scenario_test(name):
    def test(self):
        result = subprocess.run(
            [str(self.binary), name], cwd=PROJECT,
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"PASS {name}", result.stdout)
    return test


for scenario in SCENARIOS:
    setattr(MenuBarModelTests, f"test_{scenario}", scenario_test(scenario))
