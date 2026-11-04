import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


CORE = Path(__file__).resolve().parents[1] / "linux/claude-switch.sh"
INSTALL = Path(__file__).resolve().parents[1] / "linux/install.sh"


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux desktop and /proc integration")
class LinuxDesktopTests(unittest.TestCase):
    def run_slot(self, slot, checks="ok", session="none"):
        with tempfile.TemporaryDirectory() as tmp:
            desktop = Path(tmp, "claude-desktop")
            desktop.write_text('#!/bin/sh\nprintf "%s\\n" "$CLAUDE_CONFIG_DIR" "$@"\n')
            desktop.chmod(0o755)
            Path(tmp, "flock").write_text("#!/bin/sh\nexit 0\n")
            Path(tmp, "flock").chmod(0o755)
            script = '''
                set -- status
                source "$CORE"
                desktop_exec() { claude-desktop "$@"; }
                desktop_matches_slot() { return 1; }
                desktop_session_pids() {
                    if [ "$SESSION" = cli-only ] && [ "$1" = roots ]; then return; fi
                    if [ "$SESSION" != none ] && [ ! -e "$HOME/exited" ]; then echo 12345; fi
                }
                kill() {
                    if [ "$1" = -TERM ]; then
                        echo REQUESTED_TERM
                        if [ "$SESSION" = exits ] || [ "$SESSION" = cli-only ]; then touch "$HOME/exited"; fi
                    else
                        builtin kill "$@"
                    fi
                }
                sleep() { :; }
                checkdetail() {
                    for name in 代理内核 TUN网卡 出口IP IP一致 时区 地区 IPv6 DNS WebRTC 保镖 规则置顶 客户端语言 ASN属性 生态可达性; do
                        echo "$name=$CHECKS"
                    done
                }
                desktop_open "$SLOT" switch
            '''
            env = dict(os.environ, HOME=tmp, PATH=tmp + ":" + os.environ["PATH"],
                       CORE=str(CORE), CHECKS=checks, SLOT=slot, SESSION=session, CLAUDE_CONFIG_DIR="")
            return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)

    def run_desktop_exec(self, slot="A", inherited=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("claude-desktop", "systemctl"):
                (root / name).write_text("#!/bin/sh\nexit 0\n")
                (root / name).chmod(0o755)
            (root / "systemd-run").write_text(r'''#!/bin/sh
n=0
[ ! -f "$HOME/run-count" ] || n=$(cat "$HOME/run-count")
n=$((n + 1))
echo "$n" > "$HOME/run-count"
printf 'RUN %s\n' "$*" >> "$HOME/systemd.log"
printf 'Running as unit: run-u%s.service\n' "$n"
''')
            (root / "systemd-run").chmod(0o755)
            (root / "systemctl").write_text(r'''#!/bin/sh
if [ "$2" = stop ]; then
    printf 'STOP %s\n' "$3" >> "$HOME/systemd.log"
    : > "$HOME/stopped-$3"
    exit 0
fi
unit=$3
printf 'SHOW %s\n' "$unit" >> "$HOME/systemd.log"
if [ -e "$HOME/stopped-$unit" ]; then echo inactive; exit 3; fi
n=0
[ ! -f "$HOME/state-$unit" ] || n=$(cat "$HOME/state-$unit")
n=$((n + 1))
echo "$n" > "$HOME/state-$unit"
if [ "$n" -eq 1 ]; then echo activating; else echo active; fi
''')
            (root / "systemctl").chmod(0o755)
            env = dict(os.environ, HOME=tmp, PATH=f"{tmp}:/usr/bin:/bin", CORE=str(CORE))
            if inherited:
                env.update(CLAUDE_CONFIG_DIR="/explicit/code", XDG_CONFIG_HOME="/explicit/config")
            else:
                env.pop("CLAUDE_CONFIG_DIR", None)
                env.pop("XDG_CONFIG_HOME", None)
            script = '''
                source "$CORE" status >/dev/null
                sleep() { :; }
                CLAUDE_SWITCHER_DESKTOP_SLOT="$SLOT" desktop_exec claude://code/new
                CLAUDE_SWITCHER_DESKTOP_SLOT="$SLOT" desktop_exec claude://code/continue
                cat "$HOME/systemd.log"
            '''
            return subprocess.run(["/bin/bash", "-c", script], env=dict(env, SLOT=slot),
                                  capture_output=True, text=True)

    def test_launch_profiles(self):
        for slot in "ABCD":
            result = self.run_slot(slot)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("claude://code/new?source=desktop_action", result.stdout)
            self.assertEqual("--user-data-dir=" in result.stdout, slot != "A")
            self.assertEqual(f"/desktop/{slot}/code" in result.stdout, slot != "A")

    def test_switch_waits_for_existing_session(self):
        result = self.run_slot("C", session="exits")
        self.assertIn("REQUESTED_TERM", result.stdout)
        self.assertEqual(result.returncode, 0)
        self.assertIn("/desktop/C/profile", result.stdout)
        result = self.run_slot("D", session="busy")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("claude://code/new", result.stdout)
        result = self.run_slot("C", checks="fail", session="exits")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REQUESTED_TERM", result.stdout)

    def test_switch_waits_for_cli_without_desktop_root(self):
        result = self.run_slot("B", session="cli-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REQUESTED_TERM", result.stdout)
        self.assertIn("/desktop/B/profile", result.stdout)

    def test_blocked_launch(self):
        for slot, checks in [("A", "fail"), ("A", ""), ("E", "ok")]:
            result = self.run_slot(slot, checks)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("claude://code/new", result.stdout)

    def test_a_clears_manager_account_environment_but_preserves_explicit_values(self):
        result = self.run_desktop_exec("A")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--setenv=CLAUDE_CONFIG_DIR= ", result.stdout)
        self.assertIn("--setenv=XDG_CONFIG_HOME= ", result.stdout)
        result = self.run_desktop_exec("A", inherited=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--setenv=CLAUDE_CONFIG_DIR=/explicit/code", result.stdout)
        self.assertIn("--setenv=XDG_CONFIG_HOME=/explicit/config", result.stdout)

    def test_desktop_exec_tracks_units_until_activation_finishes(self):
        result = self.run_desktop_exec("B")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SHOW run-u1.service", result.stdout)
        self.assertIn("SHOW run-u2.service", result.stdout)
        self.assertGreaterEqual(result.stdout.count("SHOW run-u1.service"), 2)
        self.assertGreaterEqual(result.stdout.count("SHOW run-u2.service"), 2)

    def test_process_matching_handles_node_options_symlinks_and_unrelated_scripts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "lib/node_modules/@anthropic-ai/claude-code"
            package.mkdir(parents=True)
            (package / "cli.js").write_text("// fixture\n")
            npm_bin = root / "bin"
            npm_bin.mkdir()
            (npm_bin / "claude").symlink_to(package / "cli.js")
            other = root / "other.js"
            other.write_text("// unrelated\n")
            uid = os.getuid()
            (root / "ps").write_text(f'''#!/bin/sh
printf '%s 101 node node --max-old-space-size=4096 {npm_bin}/claude --resume\\n' {uid}
printf '%s 102 node node --inspect {package}/cli.js\\n' {uid}
printf '%s 103 node node --inspect {other}\\n' {uid}
printf '%s 104 node node --eval "console.log(\\"{package}/cli.js\\")"\\n' {uid}
''')
            (root / "ps").chmod(0o755)
            (root / "readlink").write_text('#!/bin/sh\npython3 -c \'import os,sys; print(os.path.realpath(sys.argv[-1]))\'\n')
            (root / "readlink").chmod(0o755)
            proc = root / "proc"
            for pid, args in {
                101: ["node", "--max-old-space-size=4096", str(npm_bin / "claude"), "--resume"],
                102: ["node", "--inspect", str(package / "cli.js")],
                103: ["node", "--inspect", str(other)],
                104: ["node", "--eval", f'console.log("{package}/cli.js")'],
            }.items():
                (proc / str(pid)).mkdir(parents=True)
                (proc / str(pid) / "cmdline").write_bytes(b"\0".join(os.fsencode(arg) for arg in args) + b"\0")
            env = dict(os.environ, HOME=tmp, PATH=f"{tmp}:/usr/bin:/bin", CORE=str(CORE))
            run = subprocess.run(["/bin/bash", "-c", 'source "$CORE" status >/dev/null; desktop_session_pids cli "$1"',
                                  "bash", str(proc)], env=env, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.splitlines(), ["101", "102"])

    @unittest.skipUnless(shutil.which("node"), "node is required for the real process regression")
    def test_real_node_process_and_npm_symlink_are_matched_narrowly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "lib/node_modules/@anthropic-ai/claude-code"
            package.mkdir(parents=True)
            script = "setInterval(() => {}, 1000);\n"
            (package / "cli.js").write_text(script)
            other = root / "other.js"
            other.write_text(script)
            npm_bin = root / "bin"
            npm_bin.mkdir()
            (npm_bin / "claude").symlink_to(package / "cli.js")
            env = dict(os.environ, HOME=tmp, CORE=str(CORE))
            children = [
                subprocess.Popen(["node", "--max-old-space-size=32", str(npm_bin / "claude")],
                                 env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
                subprocess.Popen(["node", str(other)], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
            ]
            try:
                matches = []
                for _ in range(50):
                    run = subprocess.run(["bash", "-c", 'source "$CORE" status >/dev/null; desktop_session_pids cli'],
                                         env=env, capture_output=True, text=True)
                    matches = run.stdout.splitlines()
                    if str(children[0].pid) in matches:
                        break
                    time.sleep(0.1)
                self.assertIn(str(children[0].pid), matches)
                self.assertNotIn(str(children[1].pid), matches)
            finally:
                for child in children:
                    child.terminate()
                for child in children:
                    child.wait(timeout=5)

    def test_install_preflight_requires_flock_and_systemd_run(self):
        prefix = INSTALL.read_text().split("# ---- 出口国家校验", 1)[0]
        for dependencies, expected in [((), 1), (("flock", "systemd-run"), 0)]:
            with self.subTest(dependencies=dependencies), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                for name in ("python3", "systemctl") + dependencies:
                    (root / name).write_text("#!/bin/sh\nexit 0\n")
                    (root / name).chmod(0o755)
                run = subprocess.run(["/bin/bash", "-c", prefix], input="9\n", text=True,
                                     env=dict(os.environ, HOME=tmp, PATH=tmp), capture_output=True)
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
                if expected:
                    self.assertIn("flock", run.stdout + run.stderr)
                    self.assertIn("systemd-run", run.stdout + run.stderr)

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

    def test_focus_preserves_requested_action_in_live_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = """
                source "$CORE" status
                echo D > "$BASE/desktop-last"
                claude-desktop() { :; }
                desktop_audit() { return 0; }
                desktop_session_pids() { echo 12345; }
                desktop_exec() { printf '%s\n' "$@"; }
                kill() { exit 80; }
                flock() { return 0; }
                desktop_open A focus claude://code/continue
            """
            env = dict(os.environ, HOME=tmp, CORE=str(CORE))
            run = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("/desktop/D/profile", run.stdout)
            self.assertIn("claude://code/continue", run.stdout)


if __name__ == "__main__":
    unittest.main()
