"""FlClash SQLite repair regressions using isolated profiles only."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"


class FlClashRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "Library/Application Support/com.follow.clash"
        self.home.mkdir(parents=True)
        self.db_path = self.home / "database.sqlite"
        self._create_database()
        (self.home / "shared_preferences.json").write_text(
            json.dumps({"flutter.currentProfileId": 123}), encoding="utf-8"
        )
        (self.home / "config.yaml").write_text(
            "dns:\n  enhanced-mode: fake-ip\n"
            "proxy-groups:\n"
            "  - name: IpEqual\n    type: select\n"
            "  - name: Fallback\n    type: select\n",
            encoding="utf-8",
        )

    def _create_database(self):
        with sqlite3.connect(self.db_path) as db:
            db.executescript(
                """
                CREATE TABLE profiles (id INTEGER PRIMARY KEY);
                CREATE TABLE rules (
                    id INTEGER PRIMARY KEY,
                    profile_id INTEGER,
                    rule_action TEXT NOT NULL,
                    content TEXT,
                    rule_target TEXT,
                    rule_provider TEXT,
                    sub_rule TEXT,
                    no_resolve INTEGER NOT NULL DEFAULT 0,
                    src INTEGER NOT NULL DEFAULT 0,
                    "order" TEXT
                );
                INSERT INTO profiles (id) VALUES (123);
                PRAGMA user_version = 21;
                """
            )

    def run_repair(self, *args, expected=0):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), "flclash-repair", *map(str, args)],
            text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def repair(self, group="IpEqual", expected=0):
        return self.run_repair("repair", self.home, group, expected=expected)

    def rule_rows(self):
        with sqlite3.connect(self.db_path) as db:
            return db.execute(
                "SELECT profile_id, rule_action, content, rule_target FROM rules "
                "ORDER BY rule_action, content"
            ).fetchall()

    def test_repair_inserts_domain_and_stun_rules_once(self):
        self.repair()
        rows = self.rule_rows()
        self.assertEqual(len(rows), 16)
        self.assertEqual({row[0] for row in rows}, {123})
        self.assertIn((123, "DOMAIN_SUFFIX", "claude.ai", "IpEqual"), rows)
        for port in (3478, 5349, 19302):
            self.assertIn((123, "DST_PORT", str(port), "IpEqual"), rows)
        self.repair()
        self.assertEqual(len(self.rule_rows()), 16)

    def test_rollback_restores_original_database(self):
        self.repair()
        backup = next(self.home.glob(".claude-switcher-backup-*.sqlite"))
        self.run_repair("rollback", self.home, backup)
        self.assertEqual(self.rule_rows(), [])
        self.assertTrue(backup.exists(), "回滚后仍保留用户备份")

    def test_invalid_configured_group_uses_first_select_group(self):
        self.repair("not-a-real-group")
        self.assertIn((123, "DOMAIN_SUFFIX", "claude.ai", "IpEqual"), self.rule_rows())

    def test_missing_current_profile_aborts_without_changes(self):
        (self.home / "shared_preferences.json").write_text("{}", encoding="utf-8")
        result = self.repair(expected=1)
        self.assertIn("当前 Profile", result.stdout + result.stderr)
        self.assertEqual(self.rule_rows(), [])
        self.assertEqual(list(self.home.glob(".claude-switcher-backup-*.sqlite")), [])

    def test_unknown_profile_id_aborts_without_changes(self):
        (self.home / "shared_preferences.json").write_text(
            json.dumps({"flutter.currentProfileId": 999}), encoding="utf-8"
        )
        self.repair(expected=1)
        self.assertEqual(self.rule_rows(), [])

    def test_future_schema_aborts_without_changes(self):
        with sqlite3.connect(self.db_path) as db:
            db.execute("PRAGMA user_version = 22")
        self.repair(expected=1)
        self.assertEqual(self.rule_rows(), [])

    def test_fake_ip_is_required_before_writing(self):
        (self.home / "config.yaml").write_text(
            "dns:\n  enhanced-mode: redir-host\n", encoding="utf-8"
        )
        self.repair(expected=1)
        self.assertEqual(self.rule_rows(), [])

    def test_fix_entry_has_rollback_path(self):
        core = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("fix_flclash", core)
        self.assertIn("flclash_repair rollback", core)

    def test_rollback_failure_is_not_reported_as_success(self):
        core = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("if ! rollback_result=$(flclash_repair rollback", core)
        self.assertIn("回滚失败，请手动恢复备份", core)

    def run_full_fix(self, stun="ok", extra_env=None):
        home_dir = self.home.parents[2]
        core = home_dir / ".local/bin/claude-switch.sh"
        core.parent.mkdir(parents=True)
        core.write_text(SCRIPT.read_text(encoding="utf-8").replace(
            'PROXY_MODE="clash-verge"', 'PROXY_MODE="flclash"', 1
        ), encoding="utf-8")
        (home_dir / ".claude-switcher").mkdir()
        fake_bin = home_dir / "bin"
        fake_bin.mkdir()
        state = home_dir / "running"
        scripts = {
            "open": "#!/bin/sh\ntouch \"$FLCLASH_TEST_STATE\"\nexit 0\n",
            "osascript": "#!/bin/sh\nrm -f \"$FLCLASH_TEST_STATE\"\nexit 0\n",
            "pgrep": "#!/bin/sh\nif [ -f \"$FLCLASH_TEST_STATE\" ]; then exit 0; else exit 1; fi\n",
            "ifconfig": "#!/bin/sh\necho 'inet 198.18.0.1'\n",
            "dig": "#!/bin/sh\necho '198.18.0.2'\n",
            "networksetup": "#!/bin/sh\necho 'IPv6: Off'\n",
            "readlink": "#!/bin/sh\necho '/var/db/timezone/zoneinfo/America/New_York'\n",
            "launchctl": "#!/bin/sh\nexit 0\n",
            "defaults": "#!/bin/sh\ncase \"$*\" in *AppleLocale*) echo en_US ;; *) echo '(en-US)' ;; esac\n",
            "curl": "#!/bin/sh\ncase \"$*\" in *cdn-cgi/trace*) printf 'ip=203.0.113.1\\nloc=US\\n' ;; *ipinfo.io*) echo '{\"org\":\"Comcast\"}' ;; *api.anthropic.com*) echo 401 ;; *) echo 200 ;; esac\n",
            "python3": "#!/bin/sh\ncase \"$1\" in *stun-probe.py) if [ \"$FLCLASH_TEST_STUN\" = leak ]; then echo 'RESULT:198.51.100.1'; elif [ \"$FLCLASH_TEST_STUN\" = none ]; then echo 'RESULT:NONE'; else echo 'RESULT:203.0.113.1'; fi ;; *) exec " + repr(sys.executable) + " \"$@\" ;; esac\n",
        }
        for name, content in scripts.items():
            path = fake_bin / name
            path.write_text(content, encoding="utf-8")
            path.chmod(0o755)
        env = dict(os.environ, HOME=str(home_dir), PATH=str(fake_bin) + os.pathsep + os.defpath,
                   FLCLASH_TEST_STATE=str(state), FLCLASH_TEST_STUN=stun)
        env.update(extra_env or {})
        return subprocess.run(["/bin/bash", str(core), "fix"], env=env, text=True,
                              capture_output=True, timeout=30)

    def test_full_fix_applies_and_verifies_rules(self):
        result = self.run_full_fix()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.rule_rows()), 16)
        self.assertIn("FlClash 域名与 STUN 规则已生效", result.stdout)

    def test_full_fix_rolls_back_when_stun_leaks(self):
        result = self.run_full_fix(stun="leak")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.rule_rows(), [])
        self.assertIn("验证失败，已回滚", result.stdout)

    def test_full_fix_honors_reject_policy_for_flclash(self):
        result = self.run_full_fix(stun="none", extra_env={"WEBRTC_POLICY": "reject"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.rule_rows()), 16)
        self.assertIn("FlClash 域名与 STUN 规则已生效", result.stdout)


if __name__ == "__main__":
    unittest.main()
