"""Windows optional-check and diagnostic UI contracts; no PowerShell is executed."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "windows/claude-switch.ps1"
UI = ROOT / "windows/SwitcherUI.ps1"


class WindowsOptionalLoggingStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core = CORE.read_text(encoding="utf-8-sig")
        cls.ui = UI.read_text(encoding="utf-8-sig")

    def test_core_has_validated_optional_config(self):
        self.assertIn("checks.json", self.core)
        self.assertIn("function Get-CheckConfig", self.core)
        self.assertIn("allowOptionalFailures", self.core)
        self.assertIn("function Test-CheckDisabled", self.core)
        for name in ("IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "生态可达性"):
            self.assertIn(name, self.core)
        self.assertIn("skip:用户已禁用", self.core)

    def test_core_has_safe_log_and_diagnostic_commands(self):
        self.assertIn("logs\\client.log", self.core)
        self.assertIn("function Write-ClientLog", self.core)
        self.assertIn("function Export-Diagnostics", self.core)
        self.assertIn("Compress-Archive", self.core)
        self.assertIn("environment.json", self.core)
        self.assertIn("recent-status.json", self.core)
        self.assertIn("'export-diagnostics'", self.core)
        self.assertIn("'set-check-config'", self.core)

    def test_diagnostic_environment_uses_validated_version(self):
        start = self.core.index("function Export-Diagnostics")
        end = self.core.index("# 版本号按", start)
        body = self.core[start:end]
        self.assertIn("$version = Get-AppVersion", body)
        self.assertIn("if ($version -notmatch '^[A-Za-z0-9._-]{1,40}$') { $version = 'unknown' }", body)
        self.assertIn("app_version = $version", body)
        self.assertNotIn("app_version = (Get-AppVersion)", body)

    def test_ui_has_settings_and_export_controls(self):
        self.assertIn("BtnSettings", self.ui)
        self.assertIn("BtnDiagnostics", self.ui)
        self.assertIn("SaveFileDialog", self.ui)
        self.assertIn("allowOptionalFailures", self.ui)
        self.assertIn("export-diagnostics", self.ui)
        self.assertIn("set-check-config", self.ui)

    def test_invoke_core_quotes_json_for_windows_powershell(self):
        start = self.ui.index("function Invoke-Core")
        body = self.ui[start:self.ui.index("function Quote-UiArgument", start)]
        self.assertIn("Quote-UiArgument", body)
        self.assertIn("@quotedArgs", body)

    def test_skip_is_explicitly_accepted_by_both_uis(self):
        self.assertRegex(self.ui, r"'skip'\s*\{")
        swift = (ROOT / "app/main.swift").read_text(encoding="utf-8")
        self.assertIn("case pending, ok, warn, fail, skip", swift)
        self.assertIn('case "skip":', swift)
        self.assertIn("case .skip:", swift)


if __name__ == "__main__":
    unittest.main()
