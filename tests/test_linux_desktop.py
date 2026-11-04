import os
import subprocess
import tempfile
import unittest
from pathlib import Path


CORE = Path(__file__).resolve().parents[1] / "linux/claude-switch.sh"


class LinuxDesktopTests(unittest.TestCase):
    def run_slot(self, slot, checks="ok"):
        with tempfile.TemporaryDirectory() as tmp:
            desktop = Path(tmp, "claude-desktop")
            desktop.write_text('#!/bin/sh\nprintf "%s\\n" "$CLAUDE_CONFIG_DIR" "$@"\n')
            desktop.chmod(0o755)
            script = '''
                set -- status
                source "$CORE"
                pgrep() { return 1; }
                checkdetail() {
                    for name in 代理内核 TUN网卡 出口IP IP一致 时区 地区 IPv6 DNS WebRTC 保镖 规则置顶 客户端语言 ASN属性 生态可达性; do
                        echo "$name=$CHECKS"
                    done
                }
                desktop_open "$SLOT"
            '''
            env = dict(os.environ, HOME=tmp, PATH=tmp + ":" + os.environ["PATH"],
                       CORE=str(CORE), CHECKS=checks, SLOT=slot, CLAUDE_CONFIG_DIR="")
            return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)

    def test_launch_profiles(self):
        for slot in ("A", "B"):
            result = self.run_slot(slot)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("claude://code/new?source=desktop_action", result.stdout)
            self.assertEqual("--user-data-dir=" in result.stdout, slot == "B")
            self.assertEqual("/desktop/B/code" in result.stdout, slot == "B")

    def test_blocked_launch(self):
        for slot, checks in [("A", "fail"), ("A", ""), ("C", "ok")]:
            result = self.run_slot(slot, checks)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("claude://code/new", result.stdout)

    def test_runtime_rule_check_via_installed_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            installed = root / ".claude-switcher"
            installed.mkdir()
            script = installed / "claude-switch.sh"
            script.write_bytes(CORE.read_bytes())
            entry = root / "claude-switch"
            entry.symlink_to(script)
            clash = root / ".local/share/io.github.clash-verge-rev.clash-verge-rev"
            clash.mkdir(parents=True)
            (clash / "clash-verge.yaml").touch()
            helper = installed / "clash-support.sh"
            helper.write_text('[[ "$1" = clash-rules && "$2" = verify && "$3" = "$EXPECTED_DIR" ]]')
            env = dict(os.environ, HOME=tmp, EXPECTED_DIR=str(clash), XDG_DATA_HOME=str(root / ".local/share"))
            command = ['bash', '-c', 'source "$1" status >/dev/null; merge_ok', 'bash', str(entry)]
            self.assertEqual(subprocess.run(command, env=env).returncode, 0)
            helper.write_text("exit 1")
            self.assertNotEqual(subprocess.run(command, env=env).returncode, 0)
