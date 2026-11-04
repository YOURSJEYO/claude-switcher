"""update 自替换必须原子化，避免运行中的 bash 从被覆盖的脚本里解析到半截语句。

回归背景：self_update 早期用 `cp 新版本 $BIN/claude-switch.sh` 原地覆盖目标文件。
正在运行 update 的 bash 持有该脚本的 fd，执行完 update 分支后还要按字节偏移继续读
后续语句（`rc=$?`、结果日志、`exit`），而 cp 截断重写同一 inode 后，偏移处已是新文件
中间的内容，于是出现"更新成功"后紧跟 `syntax error near unexpected token ...` /
`xxx: unbound variable`，退出码变 2、结果日志丢失（见 ~/.claude-switcher/update.log）。
修复方式：写同目录临时文件后 rename 覆盖，运行中的 bash 继续读旧 inode。

本文件两层覆盖：
1) 静态断言：self_update 必须经 install_staged（临时文件 + chmod + rename）落盘，
   不允许再出现 cp 直接覆盖 $BIN/claude-switch.sh；
2) 流程冒烟：假 curl 提供"远端"工件（新核心 + 对应 SHA256SUMS），在隔离 HOME 里跑真实
   `update` 入口，断言退出码不是解析失败码 2、尾部语句执行（结果日志落盘）、落盘脚本可解析。
"""

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"
MARK = "\n# local marker: 强制走真实替换分支(与远端工件不同)\n"

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
  *SHA256SUMS*) cp "__SUMS__" "$out" ;;
  *codeload*) cp "__ZIP__" "$out" ;;
  *) : >"$out" ;;
esac
exit 0
"""


@unittest.skipUnless(sys.platform == "darwin", "update 流程使用 macOS 专有命令/参数")
class UpdateSelfReplaceTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="update-self-replace-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        # 已安装版本：核心脚本 + 标记行（保证与远端工件不同，走替换分支）
        self.home = root / "home"
        self.bin = self.home / ".local" / "bin"
        self.bin.mkdir(parents=True)
        self.core = self.bin / "claude-switch.sh"
        core_text = SOURCE.read_text(encoding="utf-8")
        self.core.write_text(core_text + MARK, encoding="utf-8")
        self.core.chmod(0o755)

        # 远端工件：新核心 + 只含该文件的 SHA256SUMS（self_update 逐项校验）
        pkg = root / "pkg"
        (pkg / "core").mkdir(parents=True)
        remote_core = pkg / "core" / "claude-switch.sh"
        remote_core.write_text(core_text, encoding="utf-8")
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

        self.env = dict(os.environ, HOME=str(self.home),
                        PATH="%s:/usr/bin:/bin:/usr/sbin:/sbin" % stubs,
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1")

    def test_self_update_replaces_core_via_staged_rename(self):
        """静态防回归：不能用 cp 原地覆盖正在执行的脚本（会从半截内容解析）。"""
        text = SOURCE.read_text(encoding="utf-8")
        self.assertTrue("install_staged() {" in text, "缺少原子落盘助手 install_staged")
        body = text.split("self_update() {", 1)[1]
        self.assertFalse('cp "$NEW/core/claude-switch.sh" "$BIN/claude-switch.sh"' in body,
                         "self_update 仍在用 cp 原地覆盖正在执行的核心脚本")
        self.assertTrue('install_staged "$NEW/core/claude-switch.sh" "$BIN/claude-switch.sh"' in body,
                        "self_update 未通过 install_staged 落盘")
        # install_staged 自身必须是"写临时文件 → chmod → rename"的顺序
        helper = text.split("install_staged() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("mv -f", helper, "install_staged 未使用 rename 覆盖")
        self.assertLess(helper.index("cp "), helper.index("mv -f"))

    def test_update_does_not_parse_truncated_self(self):
        run = subprocess.run(["/bin/bash", str(self.core), "update"], env=self.env,
                             text=True, encoding="utf-8", capture_output=True, timeout=300)
        stderr = run.stderr
        # 自替换后不得再从被覆盖的脚本里解析出半截语句
        self.assertNotIn("syntax error", stderr)
        self.assertNotIn("unbound variable", stderr)
        # 隔离环境里自检必然不通过 → 回滚并返回 1；解析坏掉时是 2
        self.assertIn(run.returncode, (0, 1),
                      "update 退出码异常：%s（stderr 前 500 字：%s）"
                      % (run.returncode, stderr[:500]))
        # 尾部语句必须真的执行：结果日志里应有本次 update 记录
        log = self.home / "Library" / "Logs" / "claude-switcher" / "client.log"
        self.assertTrue(log.exists(), "结果日志未生成，说明尾部语句被跳过：%s" % stderr[:500])
        self.assertIn("command=update", log.read_text(encoding="utf-8"))
        # 落盘脚本必须是完整可解析的版本
        self.assertEqual(subprocess.run(["/bin/bash", "-n", str(self.core)]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
