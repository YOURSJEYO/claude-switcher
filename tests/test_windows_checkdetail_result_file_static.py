"""Windows checkdetail 的结果文件不得残留上一轮内容(不执行 PowerShell,可在 macOS CI 运行)。

背景:界面上的两个信息源可能来自不同轮次 —— 逐项颜色读 `last-check.txt`,
整体结论读 `checkdetail` 进程的退出码。检查过程异常中断时,旧实现不会重写
`last-check.txt`,于是界面会拿上一轮的全绿行配上这一轮的失败退出码,显示成
「逐项全绿、整体红」,用户完全看不出到底哪一项没过,横幅还提示
「存在未通过项,可一键修复或手动处理后重试」,把人引向错误方向。

客户端日志能直接看到这种运行:退出码非 0,而摘要里没有任何逐项状态。
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "windows/claude-switch.ps1"
UI = ROOT / "windows/SwitcherUI.ps1"


class WindowsCheckdetailResultFileStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = CORE.read_bytes()
        cls.text = cls.raw.decode("utf-8-sig")
        cls.ui = UI.read_text(encoding="utf-8-sig")

    def test_core_keeps_bom_and_lf(self):
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"), "claude-switch.ps1 必须保持 UTF-8 BOM")
        self.assertEqual(self.raw.count(b"\r\n"), 0)

    def test_checkdetail_branch_is_present(self):
        self.assertIn("'checkdetail' {", self.text)
        self.assertIn("$r = @(Invoke-CheckDetail)", self.text)

    def test_stale_result_is_cleared_before_the_check_runs(self):
        """清空必须发生在检查之前:检查崩溃时文件里就不会留着上一轮的结果。"""
        start = self.text.index("'checkdetail' {")
        end = self.text.index("$r = @(Invoke-CheckDetail)", start)
        branch = self.text[start:end]
        self.assertIn(
            "Out-File",
            branch,
            "checkdetail 必须在执行检查前先清空 last-check.txt,否则崩溃时会留下上一次的旧结果",
        )

    def test_result_file_is_still_written_after_a_successful_check(self):
        start = self.text.index("$r = @(Invoke-CheckDetail)")
        end = self.text.index("$summary =", start)
        self.assertIn("Out-File", self.text[start:end])

    def test_ui_verdict_comes_from_the_exit_code(self):
        """界面的整体结论确实来自退出码 —— 这正是两个信息源可能打架的原因。"""
        self.assertIn("$valid = $ExitCode -eq 0", self.ui)

    def test_ui_rows_come_from_the_result_file(self):
        """逐项颜色来自结果文件,不是来自本次运行的输出。"""
        self.assertIn("last-check.txt", self.ui)
        self.assertIn("$matched.Count -ne $checkNames.Count", self.ui)


if __name__ == "__main__":
    unittest.main()
