"""Windows FlClash 控制口发现的静态回归。

只读脚本文本，不执行 PowerShell，也不连接真实的 9090。
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "windows" / "claude-switch.ps1"
UI = ROOT / "windows" / "SwitcherUI.ps1"


class WindowsFlClashControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = CORE.read_bytes()
        cls.text = cls.raw.decode("utf-8-sig")
        cls.ui = UI.read_text(encoding="utf-8-sig")

    def test_core_keeps_bom_and_lf(self):
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"))
        self.assertEqual(self.raw.count(b"\r\n"), 0)

    def test_discovery_order_is_override_then_config_then_default_port(self):
        self.assertIn("function Get-FlClashApi", self.text)
        self.assertIn(r"com.follow\clash\config.yaml", self.text)
        self.assertIn("127.0.0.1:9090", self.text)
        self.assertIn("/version", self.text)
        self.assertIn("flclash-controller.txt", self.text)
        api = self.text[self.text.index("function Get-ClashApi"): self.text.index("function Get-ClashApiError")]
        self.assertLess(api.index("Get-FlClashApi"), api.index("@('clash-verge.yaml', 'config.yaml', 'verge.yaml')"))
        self.assertIn("Test-FlClashClientSelected", api)
        self.assertIn("IsNullOrWhiteSpace($addr)", api)

    def test_override_reuses_flclash_config_secret(self):
        self.assertIn(
            "ConvertTo-LoopbackClashEndpoint $override $secret 'flclash-override'",
            self.text,
        )

    def test_flclash_never_falls_back_to_verge(self):
        self.assertIn("function Test-FlClashClientSelected", self.text)
        api = self.text[self.text.index("function Get-ClashApi"): self.text.index("function Get-ClashApiError")]
        self.assertIn("if (Test-FlClashClientSelected) { return Get-FlClashApi }", api)
        mode = self.text[self.text.index("function Get-ClashMode"): self.text.index("function Get-ClashRules")]
        self.assertLess(mode.index("Test-FlClashClientSelected"), mode.index("@('clash-verge.yaml'"))

    def test_port_lostfocus_only_saves_changes_and_disables_editor(self):
        self.assertIn("$script:savedFlClashPort", self.ui)
        self.assertIn("$raw -eq $script:savedFlClashPort", self.ui)
        self.assertIn("$win.FindName('FlClashPort').IsEnabled = -not $busy", self.ui)

    def test_no_unrelated_port_sweep(self):
        self.assertNotIn("1..65535", self.text)
        self.assertNotIn("Test-NetConnection", self.text)

    def test_commands_reject_non_loopback_and_are_dispatched(self):
        self.assertIn("'get-flclash-controller' { Get-FlClashControllerSetting }", self.text)
        self.assertIn("'set-flclash-controller' { Set-FlClashControllerSetting $args[1] }", self.text)
        self.assertIn("只接受本机端口", self.text)

    def test_ui_can_store_a_loopback_port(self):
        self.assertIn('x:Name="FlClashPort"', self.ui)
        self.assertIn("set-flclash-controller", self.ui)


if __name__ == "__main__":
    unittest.main()
