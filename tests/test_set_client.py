"""set-client 回归测试:隔离核心副本,不改动真实安装。"""
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"


@unittest.skipUnless(sys.platform == "darwin", "sed -i '' is macOS syntax")
class SetClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.copy = self.root / "core.sh"
        self.guard = self.root / "claude-bodyguard.sh"
        self.guard.write_text('MODE="clash-verge"\n', encoding="utf-8")
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        fake_launchctl = self.fakebin / "launchctl"
        fake_launchctl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_launchctl.chmod(0o755)
        source = SCRIPT.read_text(encoding="utf-8")
        source = source.replace("/Library/Application Support/claude-switcher/claude-bodyguard.sh", str(self.guard))
        self.copy.write_text(source, encoding="utf-8")

    def run_set(self, mode):
        env = dict(os.environ, CLAUDE_SWITCHER_CORE=str(self.copy),
                   HOME=str(self.root), PATH=f"{self.fakebin}:/usr/bin:/bin")
        return subprocess.run(["/bin/bash", str(self.copy), "set-client", mode],
                              env=env, text=True, capture_output=True, timeout=10)

    def current_mode(self):
        for line in self.copy.read_text(encoding="utf-8").splitlines():
            if line.startswith("PROXY_MODE="):
                return line.split('"')[1]
        return ""

    def test_switches_mode(self):
        for mode in ("shadowrocket", "sing-box", "auto", "clash-verge"):
            result = self.run_set(mode)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.current_mode(), mode)

    def test_rejects_unknown_mode(self):
        before = self.current_mode()
        result = self.run_set("not-a-client")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.current_mode(), before)


    def test_warns_when_installed_bodyguard_mode_stale(self):
        result = self.run_set("shadowrocket")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.current_mode(), "shadowrocket")
        self.assertIn("WARN:保镖", result.stdout)
        self.assertIn("重新运行安装器", result.stdout)
        self.assertIn('MODE="clash-verge"', self.guard.read_text(encoding="utf-8"))

    def test_no_stale_bodyguard_warning_when_mode_matches(self):
        self.guard.write_text('MODE="shadowrocket"\n', encoding="utf-8")
        result = self.run_set("shadowrocket")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("WARN:保镖", result.stdout)

    def test_guard_status_fails_closed_on_mode_mismatch(self):
        core = self.copy.read_text(encoding="utf-8")
        match = re.search(r"(?ms)^bodyguard_status\(\) \{\n.*?^\}", core)
        self.assertIsNotNone(match, "bodyguard status needs current installed MODE validation")
        self.assertIn('echo "保镖=$(bodyguard_status)"', core)
        cmd = match.group(0) + '\nlaunchctl() { return 0; }\nPROXY_MODE="shadowrocket"\nbodyguard_status\n'
        env = dict(os.environ, HOME=str(self.root), PATH=f"{self.fakebin}:/usr/bin:/bin")
        run = subprocess.run(["/bin/bash", "-c", cmd], cwd=self.root, env=env,
                             text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("fail:客户端不一致", run.stdout)
        self.guard.write_text('MODE="shadowrocket"\n', encoding="utf-8")
        ok = subprocess.run(["/bin/bash", "-c", cmd], cwd=self.root, env=env,
                            text=True, capture_output=True, timeout=5)
        self.assertIn("ok:", ok.stdout)


    def test_cli_check_blocks_stale_bodyguard_even_if_launchctl_is_alive(self):
        core = self.copy.read_text(encoding="utf-8")
        guard_fn = re.search(r"(?ms)^bodyguard_status\(\) \{\n.*?^\}", core).group(0)
        check_fn = re.search(r"(?ms)^check\(\) \{\n.*?^\}", core).group(0)
        harness = r"""
PROXY_MODE="shadowrocket"
COUNTRY_TARGET="US"; TZ_TARGET="America/New_York"; LOCALE_TARGET="en_US"
BASE="$HOME"
proxy_alive() { return 0; }
tun_up() { return 0; }
curl() { case "$*" in *cdn-cgi/trace*) printf 'ip=198.51.100.2\nloc=US\n' ;; *) printf '403' ;; esac; }
iphist_count() { echo 0; }
readlink() { echo /var/db/timezone/zoneinfo/America/New_York; }
defaults() { case "$*" in *AppleLocale*) echo en_US ;; *) echo en-US ;; esac; }
networksetup() { echo 'IPv6: off'; }
dig() { echo '198.18.0.1'; }
webrtc_status() { echo 'ok:fixture'; }
route_ok() { return 0; }
launchctl() { return 0; }
"""
        env = dict(os.environ, HOME=str(self.root), PATH=f"{self.fakebin}:/usr/bin:/bin")
        src = harness + '\n' + guard_fn + '\n' + check_fn + '\ncheck\n'
        fail = subprocess.run(["/bin/bash", "-c", src], env=env, cwd=self.root,
                              text=True, capture_output=True, timeout=6)
        self.assertNotEqual(fail.returncode, 0, fail.stdout + fail.stderr)
        self.assertIn("保镖:客户端不一致", fail.stdout)
        self.guard.write_text('MODE="shadowrocket"\n', encoding="utf-8")
        ok = subprocess.run(["/bin/bash", "-c", src], env=env, cwd=self.root,
                            text=True, capture_output=True, timeout=6)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("OK:", ok.stdout)


if __name__ == "__main__":
    unittest.main()
