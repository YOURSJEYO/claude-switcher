"""Isolated CLI tests: no real proxy, account, app, or system changes."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core/claude-switch.sh"


class ProxyDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "_trash")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.home = self.folder / "home"
        self.bin = self.folder / "bin"
        self.capture = self.folder / "capture"
        for p in (self.home, self.bin, self.capture):
            p.mkdir()
        self.mode = self.folder / "mode"
        self.mode.write_text("normal")
        fake = self.bin / "curl"
        fake.write_text("#!/bin/sh\nbase=" + shlex.quote(str(self.folder)) + "\n" + r'''
for value do last=$value; done
case "$last" in *api.anthropic.com*) name=api; status=401;; *) name=web; status=403;; esac
printf '%s\n' "$@" > "$base/capture/$name.argv"
/bin/cat > "$base/capture/$name.config"
/usr/bin/env > "$base/capture/$name.env"
mode=$(/bin/cat "$base/mode")
case "$mode" in
  no_tls) printf '%s 200 0 0 0.01' "$status";;
  bad_time) printf '%s 200 0 nan 0.01' "$status";;
  socks) printf '%s 0 0 0.01 0.02' "$status";;
  malformed) printf 'invalid';;
  ssl_error) printf '%s 200 60 0.01 0.02' "$status"; printf 'secret-from-curl' >&2; exit 60;;
  timeout) exec /bin/sleep 30;;
  *) printf '%s 200 0 0.01 0.02' "$status";;
esac
''')
        fake.chmod(0o755)
        for name in ("open", "osascript", "defaults", "networksetup", "launchctl",
                     "pkill", "pgrep", "ifconfig", "dig"):
            trap = self.bin / name
            trap.write_text("#!/bin/sh\nprintf called >> " +
                            shlex.quote(str(self.folder / "unexpected-system-call")) + "\nexit 99\n")
            trap.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + os.pathsep + os.defpath,
                        CLAUDE_SWITCHER_PYTHON=sys.executable,
                        HTTP_PROXY="http://unselected.example:9999", NO_PROXY="*",
                        ANTHROPIC_AUTH_TOKEN="private-account-token")
        self.env.pop("CLAUDE_SWITCHER_PROXY_URL", None)

    def run_cli(self, *args, env=None, script=SCRIPT):
        result = subprocess.run(["/bin/bash", str(script), "diagnose-proxy", *args],
                                env=self.env if env is None else env,
                                capture_output=True, text=True, timeout=20)
        self.assertFalse((self.home / ".claude-switcher").exists(), "diagnostic created account state")
        self.assertFalse((self.folder / "unexpected-system-call").exists(), "diagnostic touched system tools")
        return result, json.loads(result.stdout)

    def test_401_and_403_are_transport_only_not_launch_approval(self):
        result, data = self.run_cli("--proxy", "http://127.0.0.1:18080")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(data["state"], "transport_reached")
        self.assertEqual([c["access"] for c in data["checks"]], ["unauthenticated", "access_restricted"])
        self.assertEqual(data["leak_protection"], "not_evaluated")
        self.assertEqual(data["account_status"], "not_evaluated")
        self.assertIsNone(data["launch_allowed"])
        self.assertFalse(data["system_modified"])

    def test_installed_single_script_needs_no_extra_helpers(self):
        installed = self.home / ".local/bin/claude-switch.sh"
        installed.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, installed)
        result, data = self.run_cli("--proxy", "http://127.0.0.1:18080", script=installed)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(data["state"], "transport_reached")

    def test_existing_status_command_retains_its_behavior(self):
        result = subprocess.run(["/bin/bash", str(SCRIPT), "status"], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(),
                         "current=none hasA=0 hasB=0 hasC=0 hasD=0 accounts=none")
        self.assertTrue((self.home / ".claude-switcher/accounts").is_dir())

    def test_private_config_and_credentials_do_not_enter_output_or_argv(self):
        private = self.home / "private-proxy.json"
        private.write_text(json.dumps({"proxy_url": "socks5h://user:private-password@remote.example:18080"}))
        result, data = self.run_cli("--config", str(private))
        self.assertEqual(result.returncode, 0)
        self.assertTrue(data["proxy"]["authentication_configured"])
        self.assertEqual(data["proxy"]["source"], "config")
        for target in ("api", "web"):
            argv = (self.capture / (target + ".argv")).read_text()
            self.assertNotIn("private-password", argv)
            self.assertEqual(argv.splitlines()[0], "-q")
            self.assertIn("socks5h://user:private-password@remote.example:18080",
                          (self.capture / (target + ".config")).read_text())
            child_env = (self.capture / (target + ".env")).read_text()
            self.assertNotIn("HTTP_PROXY=", child_env)
            self.assertNotIn("NO_PROXY=", child_env)
            self.assertNotIn("ANTHROPIC_AUTH_TOKEN=", child_env)
        for secret in ("private-password", "remote.example", str(private)):
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_no_implicit_system_proxy_or_direct_fallback(self):
        result, data = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(data["state"], "configuration_error")
        self.assertEqual(list(self.capture.iterdir()), [])

    def test_explicit_environment_proxy_is_supported(self):
        env = dict(self.env, CLAUDE_SWITCHER_PROXY_URL="http://127.0.0.1:18080")
        result, data = self.run_cli(env=env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(data["proxy"]["source"], "environment")

    def test_socks_ipv6_does_not_require_an_http_connect_status(self):
        self.mode.write_text("socks")
        result, data = self.run_cli("--proxy", "socks5h://[::1]:18080")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(data["proxy"]["host_scope"], "loopback")
        self.assertEqual(data["proxy"]["scheme"], "socks5h")
        self.assertTrue(all(c["proxy_connect_status"] == 0 for c in data["checks"]))

    def test_invalid_proxy_never_probes_or_echoes_secrets(self):
        for proxy in ("file:///secret", "http://user:secret@host:bad", "http://host:80/path",
                      "http://host:80\nproxy-user=secret", "http://host", "http://host:0"):
            with self.subTest(proxy=proxy):
                result, data = self.run_cli("--proxy", proxy)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(data["state"], "configuration_error")
                self.assertNotIn("secret", result.stdout + result.stderr)
        self.assertEqual(list(self.capture.iterdir()), [])

    def test_argument_error_does_not_echo_unknown_secret(self):
        result, data = self.run_cli("--unknown", "private-secret")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("private-secret", result.stdout + result.stderr)

    def test_invalid_config_reports_no_private_path_or_contents(self):
        private = self.home / "secret-path.json"
        private.write_text('{"proxy_url":"private-password"')
        result, data = self.run_cli("--config", str(private))
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("private-password", result.stdout + result.stderr)
        self.assertNotIn(str(private), result.stdout + result.stderr)

    def test_bad_metrics_and_tls_failure_never_pass(self):
        for mode in ("no_tls", "malformed", "ssl_error", "bad_time"):
            with self.subTest(mode=mode):
                self.mode.write_text(mode)
                result, data = self.run_cli("--proxy", "http://127.0.0.1:18080")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(data["state"], "transport_failed")
                self.assertTrue(all(not c["transport_reached"] for c in data["checks"]))
                self.assertNotIn("secret-from-curl", result.stdout + result.stderr)

    def test_missing_curl_reports_unknown_without_fallback(self):
        env = dict(self.env, PATH="")
        result, data = self.run_cli("--proxy", "http://127.0.0.1:18080", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(all(c["error"] == "curl_unavailable" for c in data["checks"]))

    def test_timeouts_stay_unknown(self):
        self.mode.write_text("timeout")
        result, data = self.run_cli("--proxy", "http://127.0.0.1:18080")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(all(c["error"] == "probe_timeout" for c in data["checks"]))
        self.assertTrue(all(c["access"] == "unknown" for c in data["checks"]))


if __name__ == "__main__":
    unittest.main()
