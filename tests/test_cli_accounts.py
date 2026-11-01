"""macOS CLI account launcher and process-boundary tests; all state is synthetic."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


def function_source(name):
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}", SOURCE.read_text(encoding="utf-8"))
    if match is None:
        raise AssertionError(f"missing function: {name}")
    return match.group(0)


class CliAccountTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.home = self.fixture / "home"
        self.base = self.home / ".claude-switcher"
        self.base.mkdir(parents=True)
        self.fakebin = self.fixture / "bin"
        self.fakebin.mkdir()
        self.fake_cli = self.fakebin / "claude"
        self.fake_cli.write_text(
            "#!/bin/sh\n"
            "printf '%s' \"$CLAUDE_CONFIG_DIR\" > \"$FIXTURE/config-dir\"\n"
            "printf '%s\\n' \"$@\" > \"$FIXTURE/args\"\n"
            "touch \"$FIXTURE/cli-called\"\n"
            "echo CLI-RAN\n"
            "exit 37\n", encoding="utf-8")
        self.fake_cli.chmod(0o755)

    def run_shell(self, code, *, injection="none", extra_env=None):
        env = {
            "PATH": f"{self.fakebin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "BASE": str(self.base),
            "FIXTURE": str(self.fixture),
            "INJECT": injection,
            "LC_ALL": "C",
        }
        if extra_env:
            env.update(extra_env)
        harness = r'''
set -u
check() {
    if [ "$INJECT" = "check_error" ]; then echo 'FAIL:audit'; return 1; fi
    if [ "$INJECT" = "change_account" ]; then echo B > "$BASE/current"; fi
    echo 'AUDIT-OUTPUT'
    return 0
}
kill() {
    printf '%s\n' "$*" > "$FIXTURE/kill-args"
    : > "$FIXTURE/ps-output"
}
'''
        functions = "\n".join(function_source(name) for name in (
            "cli_config_dir", "cli_pids", "quit_cli", "cli_lock_acquire", "cli_lock_release", "run_cli"))
        return subprocess.run(
            ["/bin/bash", "-c", harness + "\n" + functions + "\n" + code],
            env=env, text=True, capture_output=True, timeout=10)

    def test_a_preserves_existing_directory_and_arguments(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        result = self.run_shell('run_cli --print "two words"')
        self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        self.assertEqual((self.fixture / "config-dir").read_text(), str(self.home / ".claude"))
        self.assertEqual((self.fixture / "args").read_text().splitlines(), ["--print", "two words"])
        self.assertNotIn("AUDIT-OUTPUT", result.stdout)

    def test_b_uses_private_mode_700_directory(self):
        (self.base / "current").write_text("B", encoding="utf-8")
        result = self.run_shell("run_cli")
        self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        config = self.base / "cli-accounts/B"
        self.assertEqual((self.fixture / "config-dir").read_text(), str(config))
        self.assertEqual(config.stat().st_mode & 0o777, 0o700)

    def test_symlinked_account_directory_is_rejected(self):
        (self.base / "current").write_text("B", encoding="utf-8")
        (self.home / ".claude").mkdir()
        (self.base / "cli-accounts").mkdir()
        (self.base / "cli-accounts/B").symlink_to(self.home / ".claude", target_is_directory=True)
        result = self.run_shell("run_cli")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / "cli-called").exists())

    def test_existing_operation_lock_blocks_launch(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        (self.base / "cli-operation.lock").mkdir()
        result = self.run_shell("run_cli")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / "cli-called").exists())

    def test_audit_failure_and_account_race_block_launch(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        for injection in ("check_error", "change_account"):
            with self.subTest(injection=injection):
                result = self.run_shell("run_cli", injection=injection)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.fixture / "cli-called").exists())
                (self.fixture / "cli-called").unlink(missing_ok=True)
                (self.base / "current").write_text("A", encoding="utf-8")

    def test_auth_override_and_uninitialized_state_block_launch(self):
        result = self.run_shell("run_cli")
        self.assertNotEqual(result.returncode, 0)
        (self.base / "current").write_text("A", encoding="utf-8")
        result = self.run_shell("run_cli", extra_env={"ANTHROPIC_API_KEY": "synthetic"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / "cli-called").exists())

    def test_process_matching_covers_native_and_npm_only_for_target_uid(self):
        (self.fixture / "ps-output").write_text(
            " 11 1000 /opt/claude.exe /opt/claude.exe\n"
            " 12 1000 node node /x/@anthropic-ai/claude-code/cli.js\n"
            " 13 1001 claude claude\n"
            " 14 1000 bash bash /x/claude-switch.sh cli\n"
            " 15 1000 node node /x/server.js /x/@anthropic-ai/claude-code/cli.js\n", encoding="utf-8")
        ps = self.fakebin / "ps"
        ps.write_text("#!/bin/sh\ncat \"$FIXTURE/ps-output\"\n", encoding="utf-8")
        ps.chmod(0o755)
        result = self.run_shell("cli_pids 1000")
        self.assertEqual(result.stdout.split(), ["11", "12"], result.stdout + result.stderr)
        result = self.run_shell("quit_cli 1000")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("-TERM", (self.fixture / "kill-args").read_text())


if __name__ == "__main__":
    unittest.main()
