"""No accounts, installed applications or external network are accessed.

The embedded Python runs against a fake loopback Mihomo API. Generated global
scripts run in Node with synthetic Clash configuration only.
"""
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"
DOMAINS = ("claude.ai claude.com anthropic.com claudeusercontent.com "
           "challenges.cloudflare.com datadoghq.com segment.io stripe.com "
           "stripe.network stripecdn.com intercom.io intercomcdn.com "
           "intercomassets.com").split()
PORTS = (3478, 5349, 19302)


def expected_rules(group, policy="proxy"):
    target = "REJECT" if policy == "reject" else group
    return ([{"type": "AND", "payload": f"((Network,udp) && (DstPort,{p}))",
              "proxy": target} for p in PORTS] +
            [{"type": "DomainSuffix", "payload": d, "proxy": group}
             for d in DOMAINS])


class WebRTCRulesTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="webrtc-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.clash = self.folder / "clash"
        self.base = self.folder / "state"
        self.profiles = self.clash / "profiles"
        self.profiles.mkdir(parents=True)
        self.base.mkdir()
        self.group = "My proxy"
        self.responses = {
            "/configs": {"mode": "rule"},
            "/rules": {"rules": expected_rules(self.group)},
            "/proxies": {"proxies": {
                self.group: {"type": "Selector", "now": "node", "all": ["node"]},
                "node": {"type": "Shadowsocks", "udp": True},
            }},
        }
        self.requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.requests.append((self.path, self.headers.get("Authorization")))
                response = fixture.responses[self.path]
                if isinstance(response, int):
                    self.send_error(response)
                    return
                data = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.config = self.clash / "clash-verge.yaml"
        self.config.write_text(
            f'external-controller: "127.0.0.1:{self.server.server_port}"\n'
            'secret: "fixture-secret"\n', encoding="utf-8")

    def run_helper(self, action="verify", policy="", *extra, service_sock=None):
        text = SOURCE.read_text(encoding="utf-8")
        match = re.search(r"<<'PY_CLASH_RULES'\n(.*?)\nPY_CLASH_RULES", text, re.S)
        self.assertIsNotNone(match, "core must provide runtime rule verification")
        code = match.group(1)
        if service_sock:
            code = code.replace(
                '"/var/run/clash-verge-service/users/%d/verge-mihomo.sock" % os.getuid()',
                repr(service_sock))
        env = dict(os.environ, PYTHONUTF8="1", HTTP_PROXY="http://unselected.invalid:9",
                   HTTPS_PROXY="http://unselected.invalid:9", NO_PROXY="")
        run = subprocess.run(
            [sys.executable, "-", action, str(self.clash), str(self.base), self.group, policy, *extra],
            input=code, text=True, encoding="utf-8", capture_output=True,
            env=env, timeout=12)
        self.assertNotIn("fixture-secret", run.stdout + run.stderr)
        return run

    def evaluate_script(self, config=None):
        node = shutil.which("node")
        if not node:
            self.skipTest("Node is required to exercise generated global scripts")
        js = (self.profiles / "Script.js").read_text(encoding="utf-8")
        config = config or {"rules": ["DOMAIN-SUFFIX,example.test,DIRECT"],
                            "proxy-groups": [{"name": self.group}], "proxies": []}
        run = subprocess.run([node, "-e", js + "\nconsole.log(JSON.stringify(main(" +
                              json.dumps(config) + ', "fixture")));'],
                             capture_output=True, text=True, encoding="utf-8", timeout=5)
        self.assertEqual(run.returncode, 0, run.stderr)
        return json.loads(run.stdout)

    def test_text_in_merge_is_not_loaded_runtime_rule(self):
        (self.profiles / "Merge.yaml").write_text(
            "prepend-rules:\n  - DST-PORT,3478,My proxy\n", encoding="utf-8")
        self.responses["/rules"] = {"rules": []}
        self.assertNotEqual(self.run_helper().returncode, 0)

    def test_valid_runtime_rules_pass_without_using_environment_proxy(self):
        run = self.run_helper()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue(self.requests)
        self.assertTrue(all(auth == "Bearer fixture-secret" for _, auth in self.requests))

    def test_default_writer_generates_udp_only_rules_for_real_group(self):
        run = self.run_helper("write")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        rules = self.evaluate_script()["rules"]
        self.assertEqual(rules[:3], [f"AND,((NETWORK,UDP),(DST-PORT,{p})),{self.group}"
                                     for p in PORTS])
        self.assertIn("DOMAIN-SUFFIX,claude.ai," + self.group, rules)
        self.assertEqual(rules[-1], "DOMAIN-SUFFIX,example.test,DIRECT")

    def test_reject_policy_persists_across_future_invocations(self):
        run = self.run_helper("write", "reject")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual((self.base / "webrtc-policy").read_text().strip(), "reject")
        self.assertTrue(all(rule.endswith(",REJECT")
                            for rule in self.evaluate_script()["rules"][:3]))
        self.responses["/rules"] = {"rules": expected_rules(self.group, "reject")}
        self.responses["/proxies"]["proxies"]["node"]["udp"] = False
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.run_helper("write").returncode, 0)
        self.assertTrue(self.evaluate_script()["rules"][0].endswith(",REJECT"))

    def test_switching_back_to_proxy_replaces_managed_block(self):
        self.assertEqual(self.run_helper("write", "reject").returncode, 0)
        self.assertEqual(self.run_helper("write", "proxy").returncode, 0)
        rules = self.evaluate_script()["rules"]
        self.assertEqual(len(rules), len(DOMAINS) + 4)
        self.assertTrue(all(r.endswith("," + self.group) for r in rules[:3]))

    def test_existing_script_runs_first_and_repeated_write_is_idempotent(self):
        script = self.profiles / "Script.js"
        original = ('function main(config, name) {\n  config.fixture = name;\n'
                    '  config.rules.unshift("DOMAIN,custom.test,DIRECT");\n'
                    '  return config;\n}\n')
        script.write_text(original, encoding="utf-8")
        self.assertEqual(self.run_helper("write").returncode, 0)
        first = script.read_bytes()
        self.assertEqual(self.run_helper("write").returncode, 0)
        self.assertEqual(script.read_bytes(), first)
        self.assertTrue(script.read_text(encoding="utf-8").startswith(original))
        result = self.evaluate_script()
        self.assertEqual(result["fixture"], "fixture")
        self.assertIn("DOMAIN,custom.test,DIRECT", result["rules"])
        self.assertTrue(list(self.profiles.glob("Script.js.bak.*")))

    def test_migration_preserves_unmanaged_yaml(self):
        merge = self.profiles / "Merge.yaml"
        outside = "profile:\n  store-selected: true\nprepend-rules:\n  - DOMAIN,personal.test,DIRECT\n"
        merge.write_text(outside + "  # >>> claude-switcher pinned rules >>>\n"
                         "  - DST-PORT,3478,IpEqual\n"
                         "  # <<< claude-switcher pinned rules <<<\n", encoding="utf-8")
        self.assertEqual(self.run_helper("write").returncode, 0)
        self.assertEqual(merge.read_text(encoding="utf-8"), outside)
        self.assertTrue(list(self.profiles.glob("Merge.yaml.bak.*")))

    def test_bad_policy_or_missing_group_makes_no_changes(self):
        for policy in ("invalid", "proxy"):
            with self.subTest(policy=policy):
                self.responses["/proxies"] = {"proxies": {}}
                self.assertNotEqual(self.run_helper("write", policy).returncode, 0)
                self.assertFalse((self.profiles / "Script.js").exists())
                self.assertFalse((self.base / "webrtc-policy").exists())

    def test_group_name_is_json_escaped_without_code_injection(self):
        self.group = 'Proxy "one" \\ 中文'
        self.responses["/proxies"]["proxies"][self.group] = {"type": "Selector", "now": "node", "all": ["node"]}
        self.assertEqual(self.run_helper("write").returncode, 0)
        self.assertTrue(self.evaluate_script()["rules"][0].endswith("," + self.group))

    def test_ambiguous_old_marker_aborts_without_overwriting_script(self):
        merge = self.profiles / "Merge.yaml"
        merge.write_text("# >>> claude-switcher pinned rules >>>\nuser: keep\n", encoding="utf-8")
        script = self.profiles / "Script.js"
        original = "function main(config) { return config; }\n"
        script.write_text(original, encoding="utf-8")
        self.assertNotEqual(self.run_helper("write").returncode, 0)
        self.assertEqual(script.read_text(encoding="utf-8"), original)

    def test_missing_wrong_order_disabled_or_wrong_target_rules_fail(self):
        good = expected_rules(self.group)
        variants = [good[1:], [{"type": "Match", "payload": "", "proxy": "DIRECT"}] + good]
        wrong = copy.deepcopy(good)
        wrong[0]["proxy"] = "DIRECT"
        variants.append(wrong)
        disabled = copy.deepcopy(good)
        disabled[0]["extra"] = {"disabled": True}
        variants.append(disabled)
        for rules in variants:
            self.responses["/rules"] = {"rules": rules}
            self.assertNotEqual(self.run_helper().returncode, 0)

    def test_unavailable_api_or_non_rule_mode_fail(self):
        self.responses["/rules"] = 401
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.responses["/rules"] = {"rules": expected_rules(self.group)}
        self.responses["/configs"] = {"mode": "direct"}
        self.assertNotEqual(self.run_helper().returncode, 0)

    def test_proxy_policy_rejects_selected_direct_and_unsupported_udp(self):
        proxies = self.responses["/proxies"]["proxies"]
        for node in ({"type": "Shadowsocks", "udp": False}, {"type": "Direct", "udp": True}):
            proxies["node"] = node
            self.assertNotEqual(self.run_helper().returncode, 0)

    def test_probe_unknown_malformed_and_failed_exit_cannot_pass(self):
        for output, code in (("RESULT:NONE", "0"), ("", "0"), ("garbage", "0"),
                             ("RESULT:", "0"), ("RESULT:not-an-ip", "0"),
                             ("RESULT:203.0.113.1", "1")):
            with self.subTest(output=output, code=code):
                run = self.run_helper("assess", "proxy", "203.0.113.1", output, code)
                self.assertTrue(run.stdout.startswith("fail:"), run.stdout + run.stderr)

    def test_probe_proxy_ip_passes_and_other_ip_fails_without_echoing_it(self):
        run = self.run_helper("assess", "proxy", "203.0.113.1", "RESULT:203.0.113.1", "0")
        self.assertTrue(run.stdout.startswith("ok:"), run.stdout + run.stderr)
        run = self.run_helper("assess", "proxy", "203.0.113.1", "RESULT:198.51.100.2", "0")
        self.assertTrue(run.stdout.startswith("fail:"), run.stdout + run.stderr)
        self.assertNotIn("198.51.100.2", run.stdout + run.stderr)

    def test_reject_probe_only_accepts_no_response(self):
        run = self.run_helper("assess", "reject", "203.0.113.1", "RESULT:NONE", "0")
        self.assertTrue(run.stdout.startswith("ok:"), run.stdout + run.stderr)
        run = self.run_helper("assess", "reject", "203.0.113.1", "RESULT:203.0.113.1", "0")
        self.assertTrue(run.stdout.startswith("fail:"), run.stdout + run.stderr)

    def test_runtime_port_payload_must_match_exactly(self):
        for payload in ("((Network,udp) || (DstPort,3478))", "((Network,udp) && (DstPort,34780))"):
            self.responses["/rules"]["rules"][0]["payload"] = payload
            self.assertNotEqual(self.run_helper().returncode, 0)

    def test_runtime_domain_preserves_meaningful_characters(self):
        rule = self.responses["/rules"]["rules"][6]
        self.assertEqual(rule["payload"], "claudeusercontent.com")
        for payload in ("claudeuser-content.com", "claudeuser_content.com"):
            with self.subTest(payload=payload):
                rule["payload"] = payload
                self.assertNotEqual(self.run_helper().returncode, 0)
        rule["payload"] = "ClaudeUserContent.COM"
        self.assertEqual(self.run_helper().returncode, 0)

    def test_policy_preflight_needs_no_api_and_rejects_invalid_saved_policy(self):
        self.config.unlink()
        self.group = ""
        self.assertEqual(self.run_helper("policy").stdout.strip(), "proxy")
        (self.base / "webrtc-policy").write_text("reject\n", encoding="utf-8")
        self.assertEqual(self.run_helper("policy").stdout.strip(), "reject")
        (self.base / "webrtc-policy").write_text("invalid\n", encoding="utf-8")
        self.assertNotEqual(self.run_helper("policy").returncode, 0)
        self.assertEqual(self.run_helper("policy", "proxy").stdout.strip(), "proxy")
        self.assertEqual(self.requests, [])

    @unittest.skipUnless(hasattr(socket, "AF_UNIX"), "requires Unix sockets")
    def test_stale_unix_socket_falls_back_to_live_service_socket(self):
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(str(self.folder / "stale.sock"))
        stale.close()
        live = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        live_path = self.folder / "live.sock"
        live.bind(str(live_path))
        live.listen()
        live.settimeout(0.2)
        stop = threading.Event()
        self.addCleanup(live.close)
        self.addCleanup(stop.set)

        def serve():
            while not stop.is_set():
                try:
                    connection, _ = live.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                with connection:
                    request = connection.recv(65536)
                    if not request:
                        continue
                    path = request.split(b" ", 2)[1].decode("ascii")
                    body = json.dumps(self.responses[path]).encode()
                    connection.sendall(
                        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
                        + body)

        threading.Thread(target=serve, daemon=True).start()
        self.config.write_text(f"external-controller-unix: {self.folder / 'stale.sock'}\n",
                               encoding="utf-8")
        run = self.run_helper(service_sock=str(live_path))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_remote_controller_is_rejected_before_sending_secret(self):
        self.config.write_text('external-controller: "untrusted.invalid:9090"\nsecret: fixture-secret\n', encoding="utf-8")
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.requests, [])

    def test_quoted_secret_and_blank_secret_are_parsed(self):
        self.config.write_text(f"external-controller: '127.0.0.1:{self.server.server_port}'\n"
                               "secret: 'fixture secret # with ''quotes'''\n", encoding="utf-8")
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertTrue(all(auth == "Bearer fixture secret # with 'quotes'" for _, auth in self.requests))
        self.requests.clear()
        self.config.write_text(f"external-controller: 127.0.0.1:{self.server.server_port}\nsecret: ''\n", encoding="utf-8")
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertTrue(all(auth is None for _, auth in self.requests))

    def test_old_style_managed_yaml_key_is_removed_with_block(self):
        merge = self.profiles / "Merge.yaml"
        merge.write_text("profile:\n  store-selected: true\n"
                         "# >>> claude-switcher pinned rules >>>\n"
                         "prepend-rules:\n  - DST-PORT,3478,IpEqual\n"
                         "# <<< claude-switcher pinned rules <<<\n", encoding="utf-8")
        self.assertEqual(self.run_helper("write").returncode, 0)
        self.assertEqual(merge.read_text(), "profile:\n  store-selected: true\n")

    def test_global_script_fails_when_group_is_removed_from_subscription(self):
        self.assertEqual(self.run_helper("write").returncode, 0)
        script = (self.profiles / "Script.js").read_text(encoding="utf-8")
        run = subprocess.run([shutil.which("node"), "-e", script +
                              '\nmain({rules: [], "proxy-groups": [], proxies: []});'],
                             capture_output=True, text=True, timeout=5)
        self.assertNotEqual(run.returncode, 0)

    def test_existing_script_returning_invalid_config_is_not_silently_accepted(self):
        (self.profiles / "Script.js").write_text("function main(config) { return null; }\n", encoding="utf-8")
        self.assertEqual(self.run_helper("write").returncode, 0)
        script = (self.profiles / "Script.js").read_text(encoding="utf-8")
        run = subprocess.run([shutil.which("node"), "-e", script + '\nmain({});'],
                             capture_output=True, text=True, timeout=5)
        self.assertNotEqual(run.returncode, 0)

    def test_write_failure_restores_all_original_files(self):
        source = SOURCE.read_text(encoding="utf-8")
        code = re.search(r"<<'PY_CLASH_RULES'\n(.*?)\nPY_CLASH_RULES", source, re.S).group(1)
        namespace = {"__name__": "fixture_module"}
        exec(compile(code, "embedded-clash-rules", "exec"), namespace)
        script = self.profiles / "Script.js"
        merge = self.profiles / "Merge.yaml"
        script.write_bytes(b"original script\n")
        merge.write_bytes(b"original merge\n")
        policy = self.base / "webrtc-policy"
        real_replace = os.replace

        def injected_replace(src, dst, *args, **kwargs):
            if Path(dst) == merge:
                raise OSError("synthetic rename failure")
            return real_replace(src, dst, *args, **kwargs)

        with mock.patch("os.replace", side_effect=injected_replace):
            with self.assertRaises(OSError):
                namespace["write_changes"]({script: "new script", policy: "reject\n", merge: "new merge"})
        self.assertEqual(script.read_bytes(), b"original script\n")
        self.assertEqual(merge.read_bytes(), b"original merge\n")
        self.assertFalse(policy.exists())

    def test_real_shell_dispatch_works_as_a_single_core_script(self):
        bash = (str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")
                if os.name == "nt" else "/bin/bash")
        env = dict(os.environ, CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1")
        run = subprocess.run([bash, str(SOURCE).replace("\\", "/"), "clash-rules", "verify",
                              str(self.clash), str(self.base), self.group, ""],
                             env=env, capture_output=True, text=True, encoding="utf-8", timeout=12)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse((self.base / "accounts").exists())


class ShellWebRTCTests(unittest.TestCase):
    def test_invalid_policy_stops_fix_before_any_repair(self):
        source = SOURCE.read_text(encoding="utf-8")
        match = re.search(r"(?ms)^fix\(\) \{\n.*?^\}", source)
        self.assertIsNotNone(match)
        bash = (str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")
                if os.name == "nt" else "/bin/bash")
        code = r'''
set -u
PROXY_MODE=clash-verge
WEBRTC_POLICY=invalid
clash_rules() { echo 'FAIL:invalid policy' >&2; return 1; }
pgrep() { echo repair-called >&2; exit 99; }
open() { echo repair-called >&2; exit 99; }
'''
        run = subprocess.run([bash, "-c", code + match.group(0) + '\nfix'],
                             text=True, encoding="utf-8", capture_output=True, timeout=5)
        self.assertNotEqual(run.returncode, 0)
        self.assertNotEqual(run.returncode, 99, "repair must not start before policy validation")
        self.assertNotIn("repair-called", run.stdout + run.stderr)
        self.assertIn("invalid policy", run.stdout + run.stderr)

    def run_status(self, *, verified=True, result="RESULT:203.0.113.1", probe_rc=0, mode="clash-verge"):
        source = SOURCE.read_text(encoding="utf-8")
        match = re.search(r"(?ms)^webrtc_status\(\) \{\n.*?^\}", source)
        self.assertIsNotNone(match, "audit and repair must share WebRTC assessment")
        bash = (str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")
                if os.name == "nt" else "/bin/bash")
        code = r'''
set -u
PROXY_MODE="$PROXY_MODE"
clash_rules() {
    case "$1" in
        verify) if [ "$VERIFY_RC" = 0 ]; then echo OK; else echo 'FAIL:runtime not verified' >&2; return 1; fi ;;
        assess) if [ "$3" = 'RESULT:NONE' ]; then printf 'warn:STUN 无响应,未确认 UDP 出口\n'; else printf 'ok:assessed:%s:%s\n' "$3" "$4"; fi ;;
    esac
}
webrtc_test() { echo probe-called >&2; printf '%s' "$PROBE_RESULT"; return "$PROBE_RC"; }
'''
        env = dict(os.environ, VERIFY_RC="0" if verified else "1", PROBE_RESULT=result,
                   PROBE_RC=str(probe_rc), PROXY_MODE=mode, LC_ALL="C")
        return subprocess.run([bash, "-c", code + match.group(0) + '\nwebrtc_status "203.0.113.1"'],
                              env=env, text=True, encoding="utf-8", capture_output=True, timeout=5)

    def test_flclash_no_response_is_unverified_not_safely_rejected(self):
        run = self.run_status(result="RESULT:NONE", mode="flclash")
        self.assertTrue(run.stdout.startswith("warn:"), run.stdout + run.stderr)
        self.assertNotIn("已按规则拒绝", run.stdout)

    def test_unverified_rules_do_not_launch_stun_probe(self):
        run = self.run_status(verified=False)
        self.assertTrue(run.stdout.startswith("fail:"), run.stdout + run.stderr)
        self.assertNotIn("probe-called", run.stderr)

    def test_nonzero_probe_exit_is_forwarded_to_assessment(self):
        run = self.run_status(probe_rc=7)
        self.assertIn(":7", run.stdout)


if __name__ == "__main__":
    unittest.main()
