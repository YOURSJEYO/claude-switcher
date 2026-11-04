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
