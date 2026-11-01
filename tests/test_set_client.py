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
        for mode in ("shadowrocket", "sing-box", "flclash", "auto", "clash-verge"):
            result = self.run_set(mode)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.current_mode(), mode)

    def test_rejects_unknown_mode(self):
        before = self.current_mode()
        result = self.run_set("not-a-client")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.current_mode(), before)

    def test_flclash_bodyguard_recognizes_its_core(self):
        guard = (ROOT / "daemons" / "claude-bodyguard.sh").read_text(encoding="utf-8")
        guard = guard.replace("__HOME__", str(self.root)).replace("__PROXY_MODE__", "flclash")
        script = self.root / "installed-bodyguard.sh"
        script.write_text(guard, encoding="utf-8")
        (self.root / "Library" / "Logs").mkdir(parents=True)
        (self.fakebin / "ifconfig").write_text("#!/bin/sh\necho 'inet 198.18.0.1'\n", encoding="utf-8")
        (self.fakebin / "pgrep").write_text(
            "#!/bin/sh\ncase \"$*\" in *FlClashCore*|*Claude.app*) exit 0 ;; *) exit 1 ;; esac\n",
            encoding="utf-8")
        (self.fakebin / "pkill").write_text("#!/bin/sh\ntouch \"$CLAUDE_SWITCHER_TEST_ROOT/pkill-called\"\n", encoding="utf-8")
        for name in ("ifconfig", "pgrep", "pkill"):
            (self.fakebin / name).chmod(0o755)
        env = dict(os.environ, HOME=str(self.root), CLAUDE_SWITCHER_TEST_ROOT=str(self.root),
                   PATH=f"{self.fakebin}:/usr/bin:/bin")
        run = subprocess.run(["/bin/bash", str(script)], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse((self.root / "pkill-called").exists(),
                         "FlClash 在线时保镖不得按 Clash Verge 进程误杀 Claude")

    def install_guard(self, mode):
        guard = (ROOT / "daemons" / "claude-bodyguard.sh").read_text(encoding="utf-8")
        guard = guard.replace("__HOME__", str(self.root)).replace("__PROXY_MODE__", mode)
        script = self.root / "installed-bodyguard.sh"
        script.write_text(guard, encoding="utf-8")
        (self.root / "Library" / "Logs").mkdir(parents=True)
        return script

    def stub(self, name, body):
        path = self.fakebin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def run_guard(self, script):
        env = dict(os.environ, HOME=str(self.root), CLAUDE_SWITCHER_TEST_ROOT=str(self.root),
                   PATH=f"{self.fakebin}:/usr/bin:/bin")
        # enable -n kill: 让脚本的 kill 走 PATH 桩而不是内建,便于断言目标 PID
        return subprocess.run(["/bin/bash", "-c", 'enable -n kill\n. "$1"', "guard", str(script)],
                              env=env, capture_output=True, text=True, timeout=5)

    def test_bodyguard_offline_kills_only_install_user_cli(self):
        script = self.install_guard("clash-verge")
        self.stub("ifconfig", "#!/bin/sh\necho 'inet 192.168.1.2'\n")
        self.stub("pgrep", "#!/bin/sh\nexit 1\n")
        self.stub("pkill", "#!/bin/sh\ntouch \"$CLAUDE_SWITCHER_TEST_ROOT/pkill-called\"\n")
        self.stub("id", "#!/bin/sh\necho 0\n")  # 模拟 root 守护
        self.stub("stat", "#!/bin/sh\necho 4242\n")  # __HOME__ 属主 → 安装用户 UID
        self.stub("kill", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CLAUDE_SWITCHER_TEST_ROOT/kill-args\"\n")
        self.stub("ps", "#!/bin/sh\ncat <<'EOF'\n"
                        "  101  4242 claude          /usr/local/bin/claude --continue\n"
                        "  102  4242 node            node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js\n"
                        "  103  4242 bun             bun /Users/u/.bun/install/global/node_modules/@anthropic-ai/claude-code/cli.js\n"
                        "  104  4242 claude.exe      /Users/u/wine/drive_c/claude.exe\n"
                        "  105  4242 node            /Users/u/project/server.js\n"
                        "  110  4242 node            node /Users/u/project/server.js /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js\n"
                        "  106  4242 ClaudeSwitcher  /Applications/ClaudeSwitcher.app/Contents/MacOS/ClaudeSwitcher\n"
                        "  107     0 claude          /usr/local/bin/claude\n"
                        "  108  1050 node            /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js\n"
                        "  109  4242 bash            /Library/Application Support/claude-switcher/claude-bodyguard.sh\n"
                        "EOF\n")
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        kill_args = (self.root / "kill-args").read_text(encoding="utf-8").strip()
        self.assertEqual(kill_args, "-TERM 101 102 103 104",
                         "只许终止安装用户的 native/npm/bun CLI,不得波及他人、无关 node 或切换器自身")
        self.assertFalse((self.root / "pkill-called").exists(), "桌面版未在运行时不应调用 pkill")
        log = (self.root / "Library" / "Logs" / "claude-bodyguard.log").read_text(encoding="utf-8")
        self.assertIn("Claude Code CLI", log)

    def test_bodyguard_online_never_kills_cli(self):
        script = self.install_guard("clash-verge")
        self.stub("ifconfig", "#!/bin/sh\necho 'inet 198.18.0.1'\n")
        self.stub("pgrep", "#!/bin/sh\ncase \"$*\" in *Claude.app*) exit 1 ;; *) exit 0 ;; esac\n")
        self.stub("pkill", "#!/bin/sh\ntouch \"$CLAUDE_SWITCHER_TEST_ROOT/pkill-called\"\n")
        self.stub("id", "#!/bin/sh\necho 0\n")
        self.stub("stat", "#!/bin/sh\necho 4242\n")
        self.stub("kill", "#!/bin/sh\ntouch \"$CLAUDE_SWITCHER_TEST_ROOT/kill-called\"\n")
        self.stub("ps", "#!/bin/sh\ncat <<'EOF'\n"
                        "  101  4242 claude          /usr/local/bin/claude --continue\n"
                        "  102  4242 node            /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js\n"
                        "EOF\n")
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse((self.root / "kill-called").exists(), "代理在线时不得终止 CLI")
        self.assertFalse((self.root / "pkill-called").exists(), "代理在线时不得终止桌面版")

    def test_bodyguard_non_root_uses_own_uid(self):
        script = self.install_guard("clash-verge")
        self.stub("ifconfig", "#!/bin/sh\necho 'inet 192.168.1.2'\n")
        self.stub("pgrep", "#!/bin/sh\nexit 1\n")
        self.stub("id", "#!/bin/sh\necho 502\n")
        self.stub("stat", "#!/bin/sh\necho 9999\n")  # 非 root 下被采用即说明推导错了
        self.stub("kill", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CLAUDE_SWITCHER_TEST_ROOT/kill-args\"\n")
        self.stub("ps", "#!/bin/sh\ncat <<'EOF'\n"
                        "  201   502 claude          /usr/local/bin/claude\n"
                        "  202  9999 claude          /usr/local/bin/claude\n"
                        "  203   502 node            node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js\n"
                        "  204   502 bash            /Library/Application Support/claude-switcher/claude-bodyguard.sh\n"
                        "EOF\n")
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        kill_args = (self.root / "kill-args").read_text(encoding="utf-8").strip()
        self.assertEqual(kill_args, "-TERM 201 203", "非 root 下应以自身 UID 过滤,而非 __HOME__ 属主")

    def test_bodyguard_offline_still_kills_desktop_claude(self):
        script = self.install_guard("clash-verge")
        self.stub("ifconfig", "#!/bin/sh\necho 'inet 192.168.1.2'\n")
        self.stub("pgrep", "#!/bin/sh\ncase \"$*\" in *Claude.app*) exit 0 ;; *) exit 1 ;; esac\n")
        self.stub("pkill", "#!/bin/sh\ntouch \"$CLAUDE_SWITCHER_TEST_ROOT/pkill-called\"\n")
        self.stub("id", "#!/bin/sh\necho 502\n")
        self.stub("kill", "#!/bin/sh\ntouch \"$CLAUDE_SWITCHER_TEST_ROOT/kill-called\"\n")
        self.stub("ps", "#!/bin/sh\ncat <<'EOF'\n"
                        "  301   502 node            /Users/u/project/server.js\n"
                        "EOF\n")
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue((self.root / "pkill-called").exists(), "代理离线时仍须关闭桌面版 Claude")
        self.assertFalse((self.root / "kill-called").exists(), "没有 CLI 进程时不得调用 kill")

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
load_check_config() { return 0; }
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
