"""地区模板回归测试：隔离配置和系统命令，不修改真实网络或系统设置。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class TemplateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        source = Path(__file__).with_name("claude-switch.sh").read_text()
        for old, new in [
            ('BASE="$HOME/.claude-switcher"', f'BASE="{self.state}"'),
            ('LOG="$HOME/Library/Logs/claude-switch.log"', f'LOG="{self.root}/log"'),
            ('CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"',
             f'CLASH_DIR="{self.root}"'),
        ]:
            self.assertIn(old, source)
            source = source.replace(old, new)
        self.script = self.root / "core.sh"
        self.script.write_text(source)
        (self.root / "tz").write_text("/var/db/timezone/zoneinfo/Asia/Taipei\n")
        (self.root / "locale").write_text("zh_TW\n")
        (self.root / "clash-verge.yaml").write_text("DOMAIN-SUFFIX,claude.ai,IpEqual\n")
        mocks = {
            "readlink": 'cat "$TEST_ROOT/tz"',
            "osascript": """
                cat >/dev/null
                [ "${TEST_CANCEL:-0}" = 0 ] || exit 1
                printf '/var/db/timezone/zoneinfo/%s\\n' "$2" > "$TEST_ROOT/tz"
            """,
            "defaults": """
                if [ "$1" = write ]; then
                    printf '%s\\n' "$4" > "$TEST_ROOT/locale"
                elif [ "$3" = AppleLocale ]; then
                    cat "$TEST_ROOT/locale"
                else
                    echo en-US
                fi
            """,
            "curl": """
                case "$*" in
                  *cdn-cgi/trace*) printf 'ip=192.0.2.1\\nloc=%s\\n' "$TEST_EXIT" ;;
                  *ipinfo.io*) echo '{"org":"Singtel"}' ;;
                  *) echo 200 ;;
                esac
            """,
            "pgrep": "exit 0",
            "ifconfig": "echo 'inet 198.18.0.1'",
            "networksetup": "echo 'IPv6: Off'",
            "dig": "echo 198.18.0.2",
            "python3": "echo RESULT:NONE",
            "launchctl": "exit 0",
        }
        for name, body in mocks.items():
            command = self.bin / name
            command.write_text("#!/bin/bash\n" + body + "\n")
            command.chmod(0o700)
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                        TEST_ROOT=str(self.root), TEST_EXIT="TW")

    def run_core(self, *args, success=True):
        result = subprocess.run(["/bin/bash", str(self.script), *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout

    def test_all_templates_and_persistence(self):
        for code, tz, locale in [
            ("US", "America/Los_Angeles", "en_US"),
            ("TW", "Asia/Taipei", "zh_TW"),
            ("SG", "Asia/Singapore", "en_SG"),
        ]:
            with self.subTest(code=code):
                self.assertEqual(self.run_core("apply-template", code).strip(), f"OK:template={code}")
                self.assertEqual((self.state / "template").read_text().strip(), code)
                self.assertIn(tz, (self.root / "tz").read_text())
                self.assertEqual((self.root / "locale").read_text().strip(), locale)
                self.env["TEST_EXIT"] = code
                out = self.run_core("checkdetail")
                self.assertIn("出口IP=ok:", out)
                self.assertIn(f"时区=ok:{tz}", out)
                self.assertIn(f"地区=ok:{locale}", out)
                self.assertIn(f"template={code} templateMode=manual", self.run_core("status"))

    def test_mismatching_exit_does_not_override_selected_template(self):
        self.run_core("apply-template", "SG")
        out = self.run_core("checkdetail")  # 出口仍为 TW
        self.assertIn("出口IP=fail:", out)
        self.assertIn("时区=ok:Asia/Singapore", out)
        self.assertIn("地区=ok:en_SG", out)
        self.assertIn("template=SG", self.run_core("status"))

    def test_cancel_and_invalid_template_preserve_existing_settings(self):
        self.run_core("apply-template", "TW")
        self.env["TEST_CANCEL"] = "1"
        for code in ["US", "INVALID"]:
            self.assertIn("FAIL:", self.run_core("apply-template", code, success=False))
            self.assertEqual((self.state / "template").read_text().strip(), "TW")
            self.assertEqual((self.root / "locale").read_text().strip(), "zh_TW")
            self.assertIn("Asia/Taipei", (self.root / "tz").read_text())

    def test_old_install_detects_exit_until_template_is_applied(self):
        self.assertIn("出口IP=ok:", self.run_core("checkdetail"))
        self.assertIn("template=TW templateMode=auto", self.run_core("status"))


if __name__ == "__main__":
    unittest.main()
