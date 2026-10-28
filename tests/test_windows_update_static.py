"""Windows 自动更新静态回归(不执行 PowerShell,可在 macOS CI 运行)。

覆盖:UTF-8 BOM、check-update/update-now 关键路径、配置注入、SHA256 校验、
备份与计划任务重启、WPF 更新提示条与 24h 缓存、安装器/发布流水线写入版本号,
以及禁止 Invoke-Expression / 从非 GitHub 域名下载等危险模式。
"""
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WIN = ROOT / "windows"
CORE = WIN / "claude-switch.ps1"
UI = WIN / "SwitcherUI.ps1"
INSTALL = WIN / "install.ps1"
BODYGUARD = WIN / "claude-bodyguard.ps1"
RELEASE = ROOT / ".github" / "workflows" / "release.yml"

PS1_FILES = (CORE, UI, INSTALL, BODYGUARD)
ALLOWED_UPDATE_HOSTS = {
    "api.github.com",
    "github.com",
    "objects.githubusercontent.com",
    "github-releases.githubusercontent.com",
    "codeload.github.com",
}


def read(path):
    return path.read_text(encoding="utf-8-sig")


def update_now_body():
    text = read(CORE)
    start = text.index("function Invoke-UpdateNow")
    end = text.index("if($MyInvocation.InvocationName -ne '.')", start)
    return text[start:end]


def ps1_balance_error(text):
    """忽略字符串/注释/here-string 后的括号与引号平衡检查。"""
    i = 0
    n = len(text)
    stack = []
    line = 1
    in_single = in_double = False
    here = None
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
        if here:
            if c == "\n":
                k = i + 1
                while k < n and text[k] in " \t":
                    k += 1
                if text.startswith(here, k):
                    i = k + len(here)
                    line += 1
                    here = None
                    continue
            i += 1
            continue
        if not in_single and not in_double:
            if text.startswith('@"', i) and (i + 2 >= n or text[i + 2] in " \t\r\n"):
                here = '"@'
                i += 2
                continue
            if text.startswith("@'", i) and (i + 2 >= n or text[i + 2] in " \t\r\n"):
                here = "'@"
                i += 2
                continue
            if text.startswith("<#", i):
                j = text.find("#>", i + 2)
                if j < 0:
                    return f"line {line}: unclosed block comment"
                line += text.count("\n", i, j)
                i = j + 2
                continue
            if c == "#":
                j = text.find("\n", i)
                i = n if j < 0 else j
                continue
        if c == "'" and not in_double:
            in_single = not in_single
            i += 1
            continue
        if c == '"' and not in_single:
            in_double = not in_double
            i += 1
            continue
        if in_single or in_double:
            if c == "`" and in_double:
                i += 2
                continue
            i += 1
            continue
        if c == "{":
            stack.append(line)
        elif c == "}":
            if not stack:
                return f"line {line}: unmatched }}"
            stack.pop()
        i += 1
    if here:
        return "unclosed here-string"
    if in_single:
        return "unclosed single quote"
    if in_double:
        return "unclosed double quote"
    if stack:
        return f"unclosed {{ from line {stack[-1]}"
    return None


class WindowsUpdateStaticTests(unittest.TestCase):
    def test_ps1_files_keep_utf8_bom(self):
        for path in PS1_FILES:
            with self.subTest(path=path.name):
                self.assertTrue(
                    path.read_bytes().startswith(b"\xef\xbb\xbf"),
                    f"{path.name} 必须保持 UTF-8 with BOM",
                )

    def test_core_exposes_version_and_update_commands(self):
        text = read(CORE)
        self.assertIn("function Get-AppVersion", text)
        self.assertIn('Join-Path $BASE "version.txt"', text)
        self.assertIn("return 'unknown'", text)
        self.assertIn("function Compare-Version", text)
        self.assertIn("function Invoke-CheckUpdate", text)
        self.assertIn("function Invoke-UpdateNow", text)

        self.assertIn("'check-update'", text)
        self.assertIn("'update-now'", text)
        self.assertIn("checkdetail|status|fix|switch A|B|check-update|update-now", text)
        # check-update 不得创建目录/写文件
        self.assertNotIn("New-Item", text.split("function Log", 1)[0])
        self.assertIn("'check-update' { Invoke-CheckUpdate }", text)

    def test_check_update_contract(self):
        text = read(CORE)
        self.assertIn(
            "https://api.github.com/repos/YOURSJEYO/claude-switcher/releases/latest",
            text,
        )
        self.assertIn("-UserAgent 'ClaudeSwitcher'", text)
        self.assertIn("-TimeoutSec 8", text)
        self.assertIn("SecurityProtocol", text)
        self.assertIn("Tls12", text)
        for key in (
            "STATUS=update_available",
            "STATUS=latest",
            "STATUS=error",
            "CURRENT=",
            "LATEST=",
            "ZIP_URL=",
            "SUMS_URL=",
            "PAGE_URL=",
            "MESSAGE=",
        ):
            with self.subTest(key=key):
                self.assertIn(key, text)
        self.assertIn("*-windows.zip", text)
        self.assertIn("SHA256SUMS-release.txt", text)

    def test_update_now_hardening(self):
        body = update_now_body()
        # 下载、校验
        self.assertIn("Invoke-WebRequest", body)
        self.assertIn("-UseBasicParsing", body)
        self.assertIn("-TimeoutSec 60", body)
        self.assertIn("Get-FileHash", body)
        self.assertIn("-Algorithm SHA256", body)
        self.assertIn("校验失败", body)
        self.assertIn("Expand-Archive", body)
        self.assertIn("Test-GitHubDownloadUrl", body)
        # 4 项用户配置注入
        for key in ("PROXY_MODE", "COUNTRY_TARGET", "TZ_TARGET", "PROXY_GROUP"):
            with self.subTest(key=key):
                self.assertIn(key, body)
        self.assertIn("Set-ScriptConfigValue", body)
        # 备份、替换、任务重启、版本写入
        self.assertIn("backup-", body)
        self.assertIn("Copy-Item", body)
        self.assertIn("Stop-ScheduledTask", body)
        self.assertIn("Start-ScheduledTask", body)
        self.assertIn("STATUS=updated", body)
        self.assertIn("PREVIOUS=", body)
        self.assertIn("MESSAGE=更新完成", body)
        self.assertIn("STATUS=error", body)
        self.assertIn("Remove-Item -LiteralPath $tmp", body)
        # 不执行下载包里的任何脚本
        self.assertNotIn("Invoke-Expression", body)
        self.assertNotIn("Start-Process", body)
        self.assertNotIn("& $", body)

    def test_ui_update_bar_cache_and_restart(self):
        text = read(UI)
        self.assertRegex(
            text,
            r'x:Name="UpdateBar"\s+Visibility="Collapsed"',
            "UpdateBar 必须默认隐藏",
        )
        for name in ("UpdateBar", "UpdateText", "BtnUpdate", "BtnLater", "BtnCheckUpdate"):
            with self.subTest(name=name):
                self.assertIn(f'x:Name="{name}"', text)
        self.assertIn("发现新版本 v", text)
        self.assertIn("正在下载并校验", text)
        self.assertIn("update-check.json", text)
        self.assertIn("checkedAt", text)
        self.assertIn("$hours -lt 24", text)
        self.assertIn("DispatcherTimer", text)
        self.assertIn("FromMilliseconds(500)", text)
        self.assertIn("Start-Job", text)
        self.assertIn("check-update", text)
        self.assertIn("update-now", text)
        self.assertIn("Receive-Job", text)
        self.assertIn("$kv['STATUS'] -eq 'updated'", text)
        self.assertIn("$kv['STATUS'] -eq 'latest'", text)
        self.assertIn("Start-Process powershell", text)
        self.assertIn("SwitcherUI.ps1", text)

    def test_ui_xaml_is_well_formed_and_names_unique(self):
        text = read(UI)
        match = re.search(r'\$xaml = @"\n(.*?)\n"@', text, re.S)
        self.assertIsNotNone(match, "未找到 XAML here-string")
        root = ET.fromstring(match.group(1))
        self.assertIn("ScrollViewer", match.group(1), "提示条出现时内容区域需要可滚动")
        x_name = "{http://schemas.microsoft.com/winfx/2006/xaml}Name"
        names = [node.get(x_name) for node in root.iter() if node.get(x_name)]
        self.assertEqual(len(names), len(set(names)), "控件 x:Name 必须唯一")

    def test_installer_writes_version_file(self):
        text = read(INSTALL)
        self.assertIn("version.txt", text)
        self.assertIn("Join-Path $script:SetupSourceDirectory '..\\VERSION'", text)
        self.assertIn("Join-Path $script:SetupSourceDirectory 'VERSION'", text)
        self.assertIn("$appVersion = 'unknown'", text)
        self.assertIn("UTF8Encoding($false)", text)

    def test_release_pipeline_writes_windows_version(self):
        text = read(RELEASE)
        self.assertIn("scripts/package-windows.ps1", text)
        package = read(ROOT / "scripts" / "package-windows.ps1")
        self.assertIn("VERSION", package)
        self.assertIn("New-PackageZip", package)

    def test_no_dangerous_patterns(self):
        for path in PS1_FILES:
            text = read(path)
            with self.subTest(path=path.name):
                self.assertNotIn("Invoke-Expression", text)
                self.assertNotRegex(text, r"(?i)(^|[\s;&|])iex\s")

        core = read(CORE)
        for match in re.finditer(r"(?im)^.*\bInvoke-(?:WebRequest|RestMethod)\b.*$", core):
            line = match.group(0)
            for url in re.findall(r"https?://([^/\s'\"]+)", line):
                with self.subTest(line=line.strip()):
                    self.assertIn(url.lower(), ALLOWED_UPDATE_HOSTS)
        for line in core.splitlines():
            if "Invoke-WebRequest" in line:
                self.assertNotRegex(
                    line,
                    r"https?://",
                    "更新下载必须使用经过白名单校验的资产 URL,不能写死非 GitHub 地址",
                )

    def test_ps1_braces_balanced(self):
        for path in PS1_FILES:
            error = ps1_balance_error(read(path))
            with self.subTest(path=path.name):
                self.assertIsNone(error, f"{path.name}: {error}")


if __name__ == "__main__":
    unittest.main()
