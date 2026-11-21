"""Isolated regression tests for macOS multi-source ASN lookup and quit-claude."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


class AsnAndQuitClaudeTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="asn-quit-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        (self.home / "Library/Logs").mkdir(parents=True)
        self.base = self.home / ".claude-switcher"
        self.base.mkdir()
        self.core = Path(self.tmp.name) / "claude-switch.sh"
        text = SOURCE.read_text(encoding="utf-8")
        text = text.replace('PROXY_MODE="clash-verge"', 'PROXY_MODE="sing-box"', 1)
        self.core.write_text(text, encoding="utf-8")
        self.core.chmod(0o755)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.calls = Path(self.tmp.name) / "calls"
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            CLAUDE_SWITCHER_PYTHON=sys.executable,
            PYTHONUTF8="1",
        )

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(
            "#!/bin/bash\nprintf '%s %s\\n' '" + name + "' \"$*\" >>'"
            + str(self.calls) + "'\n" + body + "\n",
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def prepare_base_stubs(self, curl_body):
        self.stub("pgrep", "exit 0")
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", curl_body)
        self.stub("dig", "echo 198.18.0.2")
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/America/New_York")
        self.stub("defaults", '''if [[ "$*" == *AppleLocale* ]]; then echo en_US; else printf '(\\n    en-US,\\n)'; fi''')
        self.stub("networksetup", "echo 'IPv6: Off'")
        self.stub("python3", "echo RESULT:203.0.113.10")
        self.stub("launchctl", "exit 1")

    def run_core(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.core), *args],
            text=True,
            encoding="utf-8",
            capture_output=True,
            env=self.env,
            timeout=15,
        )

    def test_asn_falls_back_across_providers_and_detects_hosting(self):
        self.prepare_base_stubs('''case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '{"status":429,"error":"rate limit"}\\n429\\n' ;;
  *ipapi.co*) exit 28 ;;
  *api.ip.sb*) printf '{"ip":"203.0.113.10","asn":15169,"asn_organization":"Google LLC"}\\n200\\n' ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
esac''')
        res = self.run_core("checkdetail")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("ASN属性=warn:疑似机房(AS15169 Google LLC)", res.stdout)
        calls = self.calls.read_text(encoding="utf-8")
        self.assertIn("api.ip.sb/geoip", calls)
        self.assertNotIn("ipwho.is", calls, "命中 ip.sb 后不应继续探测后续源")

    def test_asn_supports_ipwhois_nested_connection_object(self):
        self.prepare_base_stubs('''case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '{}\\n200\\n' ;;
  *ipapi.co*) printf '{"error":true}\\n200\\n' ;;
  *api.ip.sb*) printf '\\n503\\n' ;;
  *ipwho.is*) printf '{"success":true,"connection":{"asn":7922,"org":"Comcast Cable Communications"}}\\n200\\n' ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
esac''')
        res = self.run_core("checkdetail")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("ASN属性=ok:AS7922 Comcast Cable Communications", res.stdout)

    def test_asn_all_sources_failed_reports_sanitized_reason_without_ip(self):
        self.prepare_base_stubs('''case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '{"ip":"203.0.113.10","error":"quota"}\\n429\\n' ;;
  *ipapi.co*) exit 28 ;;
  *api.ip.sb*) printf '' ;;
  *ipwho.is*) printf '{"success":false,"message":"203.0.113.10 blocked"}\\n200\\n' ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
esac''')
        res = self.run_core("checkdetail")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        line = next(l for l in res.stdout.splitlines() if l.startswith("ASN属性="))
        self.assertTrue(line.startswith("ASN属性=warn:未获取("), line)
        self.assertIn("ipinfo:HTTP 429", line)
        self.assertIn("ipapi:超时/不可达", line)
        self.assertIn("ip.sb:空响应", line)
        self.assertIn("ipwho.is:无ASN字段", line)
        self.assertNotIn("203.0.113.10", line)
        log = (self.home / "Library/Logs/claude-switcher/client.log").read_text(encoding="utf-8")
        self.assertIn("ASN属性=warn", log)
        self.assertNotIn("203.0.113.10", log)
        self.assertNotIn("HTTP 429", log)

    def test_asn_skips_external_probes_when_proxy_path_down(self):
        self.prepare_base_stubs('''case "$*" in
  *cdn-cgi/trace*) printf '' ;;
  *claude.ai*|*api.anthropic.com*) printf '000' ;;
esac''')
        self.stub("pgrep", "exit 1")
        self.stub("ifconfig", "printf ''")
        res = self.run_core("checkdetail")
        self.assertIn("ASN属性=warn:未获取(代理路径未就绪)", res.stdout)
        calls = self.calls.read_text(encoding="utf-8")
        for host in ("ipinfo.io", "ipapi.co", "api.ip.sb", "ipwho.is"):
            self.assertNotIn(host, calls)

    def test_quit_claude_gracefully_closes_desktop_and_cli(self):
        desktop_flag = Path(self.tmp.name) / "desktop_alive"
        desktop_flag.write_text("1", encoding="utf-8")
        proc = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(lambda: (proc.kill(), proc.wait()) if proc.poll() is None else None)
        uid = str(os.getuid())
        self.stub("pgrep", f'if [ -f "{desktop_flag}" ]; then exit 0; else exit 1; fi')
        self.stub("osascript", f'rm -f "{desktop_flag}"; exit 0')
        # 真实 kill -TERM 后被子进程退出,Python 回收前处于僵尸态,因此用 ps 核对进程状态不为 Z。
        self.stub(
            "ps",
            f'state=$(/bin/ps -o stat= -p {proc.pid} 2>/dev/null | tr -d " "); '
            f'if [ -n "$state" ] && [ "${{state#Z}}" = "$state" ]; then '
            f'echo "{proc.pid} {uid} claude claude --resume"; fi',
        )
        res = self.run_core("quit-claude")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("OK:已退出 Claude 桌面版与 Claude Code CLI", res.stdout)
        self.assertFalse(desktop_flag.exists())
        proc.wait(timeout=5)
        self.assertIsNotNone(proc.returncode)

    def test_quit_claude_fails_if_cli_does_not_exit_or_locked(self):
        (self.base / "cli-operation.lock").mkdir()
        locked = self.run_core("quit-claude")
        self.assertNotEqual(locked.returncode, 0)
        self.assertIn("FAIL:", locked.stdout)
        (self.base / "cli-operation.lock").rmdir()

        uid = str(os.getuid())
        self.stub("pgrep", "exit 1")
        self.stub("ps", f'echo "99999 {uid} claude claude"')
        self.stub("kill", "exit 0")
        self.stub("sleep", "exit 0")
        res = self.run_core("quit-claude")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("FAIL:Claude Code CLI 未能退出", res.stdout)


if __name__ == "__main__":
    unittest.main()
