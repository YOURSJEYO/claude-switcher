"""Windows 切换路径的静态安全回归。

覆盖四类回归：
1. 切换不再先删当前数据目录（暂存 + 换位 + 回滚）
2. STUN 无响应不再被当成「零暴露」
3. 客户端语言不再无条件报 ok，也不把 Windows UI 语言当作客户端语言
4. Claude 由 Appx/AUMID 兜底启动，失败时明确告警

这些用例只读 windows/ 下脚本的文本与字节，不执行 PowerShell，也不接触真实账号数据。
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS = ROOT / "windows"
CORE = WINDOWS / "claude-switch.ps1"
UI = WINDOWS / "SwitcherUI.ps1"


class WindowsSwitchSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core_raw = CORE.read_bytes()
        cls.core = cls.core_raw.decode("utf-8-sig")
        cls.ui = UI.read_bytes().decode("utf-8-sig")

    def test_ps1_keep_bom_and_lf(self):
        for path in sorted(WINDOWS.glob("*.ps1")):
            raw = path.read_bytes()
            self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), f"{path.name} 丢失 UTF-8 BOM")
            self.assertEqual(raw.count(b"\r\n"), 0, f"{path.name} 不应出现 CRLF")

    def test_switch_validates_slot_before_touching_data(self):
        self.assertIn("function Test-AccountSlot", self.core)
        self.assertIn("'^[A-D]$'", self.core)
        body = self.core[self.core.index("function Invoke-Switch"):]
        reject = body.index("FAIL:账号必须是 A、B、C 或 D")
        first_stop = body.index("Stop-ClaudeApp")
        self.assertLess(reject, first_stop, "槽位校验必须早于任何进程/数据操作")

    def test_switch_never_deletes_live_data_dir(self):
        # 旧实现先 Remove-Item $DATA 再 robocopy,复制失败即丢数据
        self.assertIsNone(
            re.search(r"Remove-Item[^\n]*\s\$DATA(?![\w.])", self.core),
            "切换路径不得直接删除当前数据目录",
        )
        self.assertIn('function Get-SwitchStagePath', self.core)
        self.assertIn('function Get-SwitchPreviousPath', self.core)
        self.assertIn('"$BASE\\staging\\Claude.new"', self.core)
        self.assertIn('"$BASE\\staging\\Claude.old"', self.core)
        self.assertIn('Resolve-OwnedSwitchCleanup', self.core)
        commit = self.core.index("function Switch-DataDir")
        cleanup = self.core.index("Remove-Item -LiteralPath $old", commit)
        pointer = self.core.index("Write-AtomicCurrent", commit)
        self.assertLess(pointer, cleanup, "账号指针必须在旧目录清理前与实际数据一起提交")

    def test_interrupted_switch_artifacts_are_never_deleted(self):
        for name in ("Load-Account", "New-AccountData"):
            body = self.core[self.core.index(f"function {name}"):]
            body = body[:body.index("\nfunction ")]
            self.assertIn("if (Test-Path -LiteralPath $stage)", body,
                          f"{name} 必须先拒绝已存在的暂存目录")
            self.assertIn("存在待恢复数据，拒绝覆盖", body)
        switch_body = self.core[self.core.index("function Switch-DataDir"):]
        switch_body = switch_body[:switch_body.index("\nfunction ")]
        self.assertIn("if (Test-Path -LiteralPath $old)", switch_body)
        self.assertIn("存在待恢复数据，拒绝覆盖", switch_body)

    def test_archive_commits_before_target_is_loaded(self):
        # 主切换路径：先归档当前账号，最后一次载入目标账号必须在其后
        self.assertLess(
            self.core.index("if (-not (Save-Account $cur))"),
            self.core.rindex("if (-not (Load-Account $target))"),
            "必须先归档当前账号，再载入目标账号",
        )
        self.assertIn('$previous = "$BASE\\accounts\\$name.previous"', self.core)
        self.assertIn('$stage = "$BASE\\accounts\\$name.new"', self.core)

    def test_robocopy_exit_code_threshold(self):
        # robocopy 0-7 都是成功，8+ 才是失败
        self.assertIn("$LASTEXITCODE -lt 8", self.core)
        self.assertIn("'/R:2'", self.core)
        self.assertIn("'/W:2'", self.core)

    def test_stun_without_response_is_warn_not_ok(self):
        self.assertNotIn("UDP不出网,零暴露", self.core)
        self.assertIn("code = 'warn'; detail = 'STUN 无响应", self.core)

    def test_asn_multiline_responses_are_reassembled(self):
        start = self.core.index("if (Test-CheckDisabled 'ASN属性')")
        body = self.core[start:self.core.index("if (Test-CheckDisabled '生态可达性')", start)]
        self.assertEqual(body.count('-join "`n"'), 2)

    def test_client_language_is_not_hardcoded_ok(self):
        self.assertNotIn("客户端语言=ok:跟随系统", self.core)
        self.assertIn("Format-OptionalResult '客户端语言' 'warn'", self.core)
        self.assertNotIn("CurrentUICulture", self.core)

    def test_claude_launch_falls_back_to_appx_aumid(self):
        self.assertIn("function Find-ClaudeAumid", self.core)
        self.assertIn("shell:AppsFolder\\$($pkg.PackageFamilyName)!$appId", self.core)
        self.assertNotIn(
            'Start-Process "shell:AppsFolder" -ErrorAction SilentlyContinue',
            self.core,
        )
        self.assertIn("WARN:未找到 Claude 可执行文件，请手动启动", self.core)

    def test_graceful_close_before_force_kill(self):
        body = self.core[
            self.core.index("function Stop-ClaudeApp"):
            self.core.index("function Switch-DataDir")
        ]
        self.assertLess(
            body.index("CloseMainWindow"),
            body.index("Stop-Process -Force"),
            "应先请求正常退出，超时后才强杀",
        )

    def test_ui_detects_fail_anywhere_in_switch_output(self):
        # 首次收编会先输出 NOTE，FAIL 可能不在首行
        self.assertIn("(?m)^FAIL:", self.ui)


if __name__ == "__main__":
    unittest.main()
