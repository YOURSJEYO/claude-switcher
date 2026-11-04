"""update 自替换必须暂存完整候选脚本，再原子发布并可靠回滚。"""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("CLAUDE_SWITCHER_TEST_SOURCE", ROOT / "core/claude-switch.sh"))
MARK = "\n# local marker: 强制走真实替换分支(与远端工件不同)\n"
CONFIG = {
    "PROXY_MODE": "clash-verge",
    "PROXY_GROUP": "隔离测试组",
    "COUNTRY_TARGET": "JP",
    "TZ_TARGET": "Asia/Tokyo",
    "LOCALE_TARGET": "ja_JP",
}

CURL_STUB = """#!/bin/bash
url=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "$out" ] || exit 0
case "$url" in
  *SHA256SUMS*) /bin/cp "__SUMS__" "$out" ;;
  *codeload*) /bin/cp "__ZIP__" "$out" ;;
  *) : >"$out" ;;
esac
exit 0
"""

COMMAND_STUB = """#!/bin/bash
name="$(basename "$0")"
{
  printf '%s' "$name"
  printf ' %s' "$@"
  printf '\\n'
} >> "$UPDATE_TRACE"
if [ "$name" = cp ]; then
  eval 'src="${'$(($# - 1))'}"; dst="${'$#'}"'
  if [ "${UPDATE_FAIL_BACKUP:-0}" = 1 ] && [[ "$dst" = *.bak ]]; then
    exit 1
  fi
  if [ "${UPDATE_FAIL_ROLLBACK:-0}" = 1 ] && [[ "$src" = *.bak ]]; then
    exit 1
  fi
fi
case "$name" in
  cp) exec /bin/cp "$@" ;;
  mv) exec /bin/mv "$@" ;;
  *) exec "/usr/bin/$name" "$@" ;;
esac
"""


@unittest.skipUnless(sys.platform == "darwin", "update 流程使用 macOS 专有命令/参数")
class UpdateSelfReplaceTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="update-self-replace-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        self.home = root / "home"
        self.bin = self.home / ".local" / "bin"
        self.bin.mkdir(parents=True)
        self.core = self.bin / "claude-switch.sh"
        core_text = SOURCE.read_text(encoding="utf-8")
        for key, value in CONFIG.items():
            core_text = re.sub(r'^%s="[^"]*"' % key, '%s="%s"' % (key, value),
                               core_text, count=1, flags=re.MULTILINE)
        self.original = (core_text + MARK).encode()
        self.core.write_bytes(self.original)
        self.core.chmod(0o755)

        pkg = root / "pkg"
        (pkg / "core").mkdir(parents=True)
        remote_core = pkg / "core" / "claude-switch.sh"
        self_check = r'''
checkdetail() {
    : > "$HOME/self-check-ran"
    case "${UPDATE_TEST_SELF_CHECK:-fail}" in
        pass) echo "forced=ok"; return 0 ;;
        nonzero) echo "forced=ok"; return 1 ;;
        *) echo "forced=fail"; return 1 ;;
    esac
}
'''
        padding = "".join("# remote padding %04d %s\n" % (i, "x" * 72) for i in range(400))
        remote_text = core_text.replace('operation="${1:-}"',
                                        padding + self_check + 'operation="${1:-}"', 1)
        self.assertNotEqual(remote_text, core_text)
        remote_core.write_text(remote_text, encoding="utf-8")
        sums = pkg / "SHA256SUMS"
        sums.write_text(
            "%s  core/claude-switch.sh\n" % hashlib.sha256(remote_core.read_bytes()).hexdigest(),
            encoding="utf-8")
        self.zip_path = root / "remote.zip"
        with zipfile.ZipFile(self.zip_path, "w") as archive:
            archive.write(remote_core, "claude-switcher-main/core/claude-switch.sh")
            archive.write(sums, "claude-switcher-main/SHA256SUMS")

        stubs = root / "stubs"
        stubs.mkdir()
        curl = stubs / "curl"
        curl.write_text(
            CURL_STUB.replace("__SUMS__", str(sums)).replace("__ZIP__", str(self.zip_path)),
            encoding="utf-8")
        curl.chmod(0o755)
        for name in ("cp", "mv", "sed"):
            stub = stubs / name
            stub.write_text(COMMAND_STUB, encoding="utf-8")
            stub.chmod(0o755)

        self.trace = root / "commands.log"
        self.trace.write_text("", encoding="utf-8")
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin" % stubs,
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1",
                        UPDATE_TRACE=str(self.trace))

    def run_update(self, self_check="fail", fail_backup=False, fail_rollback=False):
        self.env.update(UPDATE_TEST_SELF_CHECK=self_check,
                        UPDATE_FAIL_BACKUP="1" if fail_backup else "0",
                        UPDATE_FAIL_ROLLBACK="1" if fail_rollback else "0")
        return subprocess.run(["/bin/bash", str(self.core), "update"], env=self.env,
                              text=True, encoding="utf-8", capture_output=True, timeout=300)

    def operations(self, name):
        return [line for line in self.trace.read_text(encoding="utf-8").splitlines()
                if line.startswith(name + " ")]

    def assert_original_restored(self):
        self.assertEqual(self.core.read_bytes(), self.original)
        self.assertEqual((self.bin / "claude-switch.sh.bak").read_bytes(), self.original)
        self.assertEqual(subprocess.run(["/bin/bash", "-n", str(self.core)]).returncode, 0)

    def assert_result_logged(self):
        log = self.home / "Library" / "Logs" / "claude-switcher" / "client.log"
        self.assertTrue(log.exists(), "结果日志未生成，说明 update 尾部语句被跳过")
        self.assertIn("command=update", log.read_text(encoding="utf-8"))

    def test_self_update_uses_staged_rename(self):
        text = SOURCE.read_text(encoding="utf-8")
        self.assertTrue("install_staged() {" in text, "缺少原子落盘助手 install_staged")
        body = text.split("self_update() {", 1)[1]
        self.assertNotRegex(body, r'cp "\$NEW/core/claude-switch\.sh" "\$BIN/claude-switch\.sh"')
        self.assertIn('install_staged "$candidate" "$BIN/claude-switch.sh"', body,
                      "完整候选脚本必须通过一次 install_staged 发布")
        helper = text.split("install_staged() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("mv -f", helper, "install_staged 未使用 rename 覆盖")
        self.assertLess(helper.index("cp "), helper.index("mv -f"))

    def test_success_publishes_configured_candidate_once(self):
        run = self.run_update(self_check="pass")
        self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
        installed = self.core.read_text(encoding="utf-8")
        for key, value in CONFIG.items():
            self.assertIn('%s="%s"' % (key, value), installed)
        self.assertEqual((self.bin / "claude-switch.sh.bak").read_bytes(), self.original)
        self.assertTrue((self.home / "self-check-ran").exists())
        publishes = [line for line in self.operations("mv")
                     if line.endswith(" " + str(self.core))]
        self.assertEqual(len(publishes), 1, publishes)
        self.assertEqual([line for line in self.operations("sed")
                          if line.endswith(" " + str(self.core))], [])
        self.assert_result_logged()

    def test_failed_self_check_restores_original_and_logs_result(self):
        run = self.run_update()
        self.assertEqual(run.returncode, 1, run.stderr + run.stdout)
        self.assertIn("已自动回滚", run.stdout)
        self.assertTrue((self.home / "self-check-ran").exists(), "未进入更新后自检路径")
        self.assert_original_restored()
        self.assert_result_logged()

    def test_nonzero_self_check_without_fail_text_restores_original(self):
        run = self.run_update(self_check="nonzero")
        self.assertEqual(run.returncode, 1, run.stderr + run.stdout)
        self.assertTrue((self.home / "self-check-ran").exists(), "未进入更新后自检路径")
        self.assert_original_restored()

    def test_backup_failure_aborts_before_publish_or_self_check(self):
        backup = self.bin / "claude-switch.sh.bak"
        backup.write_bytes(b"existing backup")
        run = self.run_update(self_check="pass", fail_backup=True)
        self.assertEqual(run.returncode, 1, run.stderr + run.stdout)
        self.assertEqual(self.core.read_bytes(), self.original)
        self.assertEqual(backup.read_bytes(), b"existing backup")
        self.assertFalse((self.home / "self-check-ran").exists())
        self.assertEqual([line for line in self.operations("mv")
                          if line.endswith(" " + str(self.core))], [])

    def test_rollback_failure_is_not_reported_as_rolled_back(self):
        run = self.run_update(fail_rollback=True)
        self.assertEqual(run.returncode, 1, run.stderr + run.stdout)
        self.assertIn("回滚失败", run.stdout)
        self.assertNotIn("已自动回滚", run.stdout)
        self.assertNotEqual(self.core.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
