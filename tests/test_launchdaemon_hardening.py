"""LaunchDaemon 安装/修复的隔离标记与注册结果回归。"""
import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "installer" / "安装.command"
CORE = ROOT / "core" / "claude-switch.sh"


def function_body(text, name):
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}", text)
    if not match:
        raise AssertionError(f"missing shell function: {name}")
    return match.group(0)


class LaunchDaemonHardeningTests(unittest.TestCase):
    def test_installer_removes_quarantine_before_launchd_bootstrap(self):
        text = INSTALLER.read_text(encoding="utf-8")
        copy_line = next(
            line for line in text.splitlines()
            if "cp " in line and "local.claude-bodyguard.plist" in line
            and "/Library/LaunchDaemons/" in line
        )
        self.assertIn("cp -X", copy_line)
        self.assertIn("/usr/bin/xattr -d com.apple.quarantine", text)
        self.assertIn("/Library/LaunchDaemons/local.claude-bodyguard.plist", text)
        self.assertIn("/Library/LaunchDaemons/local.tz-watchdog.plist", text)
        self.assertLess(
            text.index("/usr/bin/xattr -d com.apple.quarantine /Library/LaunchDaemons/"),
            text.index("launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist"),
        )

    def test_installer_fails_when_either_daemon_is_not_registered(self):
        text = INSTALLER.read_text(encoding="utf-8")
        for label in ("local.claude-bodyguard", "local.tz-watchdog"):
            with self.subTest(label=label):
                self.assertRegex(
                    text,
                    rf"launchctl bootstrap system /Library/LaunchDaemons/{re.escape(label)}\.plist"
                    rf".*?launchctl print system/{re.escape(label)}"
                    rf".*?\|\| exit 1",
                )

    def test_fix_repairs_and_verifies_bodyguard_before_reporting_success(self):
        text = CORE.read_text(encoding="utf-8")
        fix = function_body(text, "fix")
        self.assertIn("cp -X $HOME/.local/bin/local.claude-bodyguard.plist", fix)
        self.assertIn("/usr/bin/xattr -d com.apple.quarantine", fix)
        self.assertIn("launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist", fix)
        self.assertLess(
            fix.index("/usr/bin/xattr -d com.apple.quarantine"),
            fix.index("launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist"),
        )
        self.assertIn("launchctl print system/local.claude-bodyguard", fix)
        self.assertRegex(fix, r"launchctl print system/local\.claude-bodyguard.*?\|\| exit 1")

    def test_installer_treats_copy_and_permission_errors_as_fatal(self):
        text = INSTALLER.read_text(encoding="utf-8")
        critical = (
            "cp '$STAGE/claude-bodyguard.sh'",
            "chown root:wheel '/Library/Application Support/claude-switcher/claude-bodyguard.sh'",
            "chmod 755 '/Library/Application Support/claude-switcher/claude-bodyguard.sh'",
            "cp -X '$H/.local/bin/local.claude-bodyguard.plist'",
            "chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist",
            "chmod 644 /Library/LaunchDaemons/local.claude-bodyguard.plist",
        )
        for needle in critical:
            with self.subTest(needle=needle):
                line = next(line for line in text.splitlines() if needle in line)
                self.assertIn("|| exit 1", line)

    def test_launchagent_copy_also_excludes_quarantine(self):
        text = INSTALLER.read_text(encoding="utf-8")
        copy_line = next(
            line for line in text.splitlines()
            if "cp " in line and "local.claude-update.plist" in line
            and "LaunchAgents" in line
        )
        self.assertIn("cp -X", copy_line)
        self.assertIn("/usr/bin/xattr -d com.apple.quarantine", text)


if __name__ == "__main__":
    unittest.main()