"""Windows Clash 规则修复静态回归(不执行 PowerShell,可在 macOS CI 运行)。

重点防止回归:
- 必须先识别 Clash 模式,global/direct/unknown 不写规则;
- 规则模式只写 profiles\\Script.js,禁止再写 Merge.yaml 的 prepend-rules;
- 旧 Merge 的 16 条规则、--- 多文档与重复顶层键会被清理并备份;
- 写入后通过内核 /rules 验证,失败回滚 Script.js。
"""
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WIN = ROOT / "windows"
CORE = WIN / "claude-switch.ps1"
UI = WIN / "SwitcherUI.ps1"
INSTALL = WIN / "install.ps1"
README = WIN / "README.md"
PS1_FILES = (
    CORE,
    UI,
    INSTALL,
    WIN / "claude-bodyguard.ps1",
)
DOMAINS = (
    "claude.ai",
    "claude.com",
    "anthropic.com",
    "claudeusercontent.com",
    "challenges.cloudflare.com",
    "datadoghq.com",
    "segment.io",
    "stripe.com",
    "stripe.network",
    "stripecdn.com",
    "intercom.io",
    "intercomcdn.com",
    "intercomassets.com",
)
PORTS = ("3478", "5349", "19302")


def read(path):
    return path.read_text(encoding="utf-8-sig")


def extract_block(text, marker):
    """从 marker 后的第一个 { 开始做花括号配平,返回块内文本。"""
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    raise AssertionError(f"unclosed block: {marker}")


def between(text, start_marker, end_marker):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


class WindowsRulesStaticTests(unittest.TestCase):
    def test_ps1_files_keep_utf8_bom(self):
        for path in PS1_FILES:
            with self.subTest(path=path.name):
                self.assertTrue(
                    path.read_bytes().startswith(b"\xef\xbb\xbf"),
                    f"{path.name} 必须保持 UTF-8 with BOM",
                )

    def test_mode_detection_functions_and_fallbacks(self):
        text = read(CORE)
        for name in (
            "Get-ClashMode",
            "Get-ClashRules",
            "Write-ClashScriptRules",
            "Remove-LegacyMergeRules",
            "Get-RulesStatus",
        ):
            with self.subTest(name=name):
                self.assertIn(f"function {name}", text)

        for needle in (
            "external-controller",
            "secret",
            "/configs",
            "Authorization",
            "Bearer ",
            "TimeoutSec = 3",
            "clash-verge.yaml",
            "verge.yaml",
            "(?m)^mode:",
            "return 'unknown'",
            "Get-Content -LiteralPath $path -Encoding UTF8",
        ):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)
        api_body = between(text, "function Get-ClashApi", "function Get-ClashMode")
        self.assertIn("config.yaml", api_body)
        self.assertIn("IsNullOrWhiteSpace($addr)", api_body)
        # 中文代理组名/规则不能按 ANSI 读取
        self.assertIn("Get-Content -LiteralPath $mergePath -Encoding UTF8", text)

    def test_global_branch_does_not_write_rules(self):
        text = read(CORE)
        block = extract_block(
            text, "elseif ($clashMode -eq 'global' -or $clashMode -eq 'direct')"
        )
        self.assertIn("Remove-LegacyMergeRules", block)
        self.assertIn("Restart-ClashVerge", block)
        self.assertIn("Wait-Tun", block)
        self.assertIn("规则不适用,未改动任何配置", block)
        self.assertNotIn("Write-ClashScriptRules", block)
        self.assertNotIn("prepend-rules", block)
        self.assertNotIn("$mergePath", block)

    def test_unknown_mode_only_skips(self):
        text = read(CORE)
        block = extract_block(text, "if ($clashMode -eq 'unknown')")
        self.assertIn("无法确认 Clash 模式", block)
        self.assertNotIn("Remove-LegacyMergeRules", block)
        self.assertNotIn("Write-ClashScriptRules", block)
        self.assertNotIn("Restart-ClashVerge", block)

    def test_script_js_write_is_idempotent_and_backed_up(self):
        text = read(CORE)
        body = between(
            text, "function Write-ClashScriptRules", "function Remove-LegacyMergeRules"
        )
        for needle in (
            "profiles\\Script.js",
            "// >>> claude-switcher managed rules >>>",
            "// <<< claude-switcher managed rules <<<",
            "function main(config)",
            "function\\s+main\\s*\\(",
            "pinnedRules",
            "config.rules = pinnedRules.concat",
            "ConvertTo-Json",
            ".bak.",
            "UTF8Encoding($false)",
            "没有 function main",
            "规则已是当前版本",
        ):
            with self.subTest(needle=needle):
                self.assertIn(needle, body)
        # 幂等替换:已有托管块时只换块内内容
        self.assertIn("[regex]::Replace", body)
        self.assertIn("-ceq", body)
        # 单行 function main 插入后必须在托管块后换行,避免把 return comment 掉
        self.assertIn('$managed + "`r`n" + $existing.Substring', body)
        # 组名可能含 $,替换模式必须转义为字面量
        self.assertIn("Replace('$', '$$')", body)
        # 代理组名校验:允许空格,禁止空值/逗号/换行
        self.assertIn("IsNullOrWhiteSpace($PROXY_GROUP)", body)
        self.assertIn("PROXY_GROUP -match '[,\\r\\n]'", body)
        # 不允许写 Merge 规则
        self.assertNotIn("prepend-rules", body)

    def test_legacy_merge_cleanup_covers_rules_docs_and_dupes(self):
        text = read(CORE)
        body = between(
            text, "function Remove-LegacyMergeRules", "function Restart-ClashVerge"
        )
        for needle in (
            "Merge.yaml",
            ".bak.",
            "prepend-rules",
            "hasEmptyPrepend",
            "---",
            "$CLAUDE_DOMAINS",
            "$CLAUDE_PORTS",
            "Group-Object",
            "IsNullOrWhiteSpace($after)",
            "Remove-Item -LiteralPath $mergePath",
            "UTF8Encoding($false)",
        ):
            with self.subTest(needle=needle):
                self.assertIn(needle, body)
        for domain in DOMAINS:
            with self.subTest(domain=domain):
                self.assertIn(f"'{domain}'", text)
        for port in PORTS:
            with self.subTest(port=port):
                self.assertIn(f"'{port}'", text)

    def test_rule_mode_verifies_kernel_and_rolls_back(self):
        text = read(CORE)
        rule_branch = extract_block(text, "} else {\n            \"FIX:Clash 模式=rule\"")
        for needle in (
            "Remove-LegacyMergeRules",
            "Write-ClashScriptRules",
            "Get-ClashRules",
            "Wait-ClashRules",
            "Test-PinnedRules",
            "Restore-ClashScriptChange",
            "FIX:规则已写入但无法验证内核加载(控制接口不可用)",
            "FIX:置顶规则验证失败,正在回滚 Script.js",
        ):
            with self.subTest(needle=needle):
                self.assertIn(needle, rule_branch)

        rules_body = between(text, "function Get-ClashRules", "function Test-PinnedRules")
        self.assertIn("/rules", rules_body)
        self.assertIn("TimeoutSec = 3", rules_body)
        pinned_body = between(text, "function Test-PinnedRules", "function Write-ClashScriptRules")
        self.assertIn("Select-Object -First 16", pinned_body)
        self.assertIn("DST-PORT", pinned_body)
        self.assertIn("domainsuffix", pinned_body)
        self.assertIn("dstport", pinned_body)

    def test_checkdetail_reports_mode_aware_status(self):
        text = read(CORE)
        for needle in (
            "Get-RulesStatus",
            "规则置顶=ok:全局模式(规则不适用)",
            "规则置顶=ok:直连模式(规则不适用)",
            "规则置顶=warn:无法确认 Clash 模式,未检查规则",
            "规则置顶=warn:规则已写入但无法验证内核加载",
            "规则置顶=fail:内核未加载置顶规则",
        ):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)

    def test_installer_no_longer_writes_merge_rules(self):
        text = read(INSTALL)
        self.assertNotIn("prepend-rules", text)
        self.assertNotIn("$mergePath", text)
        self.assertNotIn("$merge = @\"", text)
        # Native setup delegates protected changes; rule repair remains in the core.
        self.assertIn("Invoke-ElevatedSystemSetup", text)
        self.assertIn("-Operation 'repair-system'", text)
        self.assertNotIn("Write-ClashScriptRules", text)
        self.assertNotIn("WriteAllText($mergePath", text)

    def test_core_no_longer_writes_prepend_rules(self):
        text = read(CORE)
        self.assertNotIn('$merge = @"', text)
        self.assertNotIn("- DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP", text)
        self.assertNotIn("WriteAllText($mergePath, $merge", text)
        self.assertIn("profiles\\Script.js", text)

    def test_ui_shows_trusted_fix_failure_in_banner(self):
        text = read(UI)
        self.assertIn("Invoke-LegacyCoreOperation -Command 'fix'", text)
        self.assertIn("$outcome.Result.TrustedSuccess", text)
        self.assertIn("Set-Banner $outcome.Result.Message", text)
        # The JSON process result is UTF-8 and cannot be replaced by a stale cache.
        self.assertNotIn("last-fix.txt", text)
        self.assertNotIn("Get-Content \"$BASE\\last-check.txt\"", text)

    def test_readme_describes_mode_aware_behavior(self):
        text = read(README)
        self.assertIn("## Clash 规则与全局模式", text)
        self.assertIn("全局 / 直连模式", text)
        self.assertIn("Script.js", text)
        self.assertIn("回滚", text)
        self.assertNotIn("重建 Merge.yaml", text)
        self.assertNotIn("只保留一个 `profile:` 与一个 `prepend-rules:`", text)


if __name__ == "__main__":
    unittest.main()
