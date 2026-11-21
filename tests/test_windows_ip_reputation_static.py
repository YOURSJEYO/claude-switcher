"""Windows IP 信誉检查的静态契约(不执行 PowerShell,可在 macOS CI 运行)。

背景:出口 IP 对了不等于 IP 信誉好。「出口IP」只比对这个 IP 与目标国家是否一致;
同一个国家里,住宅家宽、机房地址、VPN 出口、住宅代理池在风控眼里是四种东西。
真实事故:账号在代理池地址上被烧,而当时体检表一片绿。

信誉数据只有第三方有,而且没有哪个免费、免密钥、HTTPS 的接口能稳定分辨
「住宅代理池」——实测有的只返回地理信息不返回风险标记(缺字段≠「没有风险」),
有的对同一地址给出不同结论。所以这个特性做成「可插拔 + 可关闭」:
用户在 checks.json 里指定用哪家的接口,没配就显示未配置,不猜、不假装通过。

这个文件锁住:
1. 四个检查项是「非关键项」——可以关、可以被降级,不与硬性安全项混为一谈;
2. 缺字段判 warn,不判 ok —— 缺数据不等于没有风险;
3. 探测失败判 warn,不判 fail —— 数据源改版不该把所有人的检查判红;
4. 信誉接口必须 HTTPS —— 明文响应可以被中间人改写成「干净」;
5. 内置代码里不写死任何一家数据源、任何 IP、任何分数口径;
6. 密钥不回显;
7. 界面列出的检查项与核心脚本的实际项数一致(计数写错会让用户以为改动没生效);
8. 数值配置字段接受两个 shell 的整数类型(PS 5.1 给 Int32、PS 7 给 Int64);
9. 缓存读回后记录是 hashtable —— 命中缓存的那一轮不能因为对象形状不对而崩。
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "windows/claude-switch.ps1"
UI = ROOT / "windows/SwitcherUI.ps1"

REPUTATION_CHECKS = ("IP纯净度", "IP代理标记", "IP机房属性", "IP黑名单")


class WindowsIpReputationStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = CORE.read_bytes()
        cls.text = cls.raw.decode("utf-8-sig")
        cls.ui = UI.read_text(encoding="utf-8-sig")
        start = cls.text.index("function ConvertTo-CheckConfig")
        end = cls.text.index("\n}", start)
        cls.config_body = cls.text[start:end]

    def test_core_keeps_bom_and_lf(self):
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"), "claude-switch.ps1 必须保持 UTF-8 BOM")
        self.assertEqual(self.raw.count(b"\r\n"), 0)

    def test_reputation_checks_are_optional_items(self):
        """四项必须进可选白名单 —— 它们是「可关可不关」的信息类检查,
        不是硬性安全项。混进硬性项会让用户没法在数据源出问题时先启动。"""
        self.assertIn("$optional = @(", self.config_body)
        for name in REPUTATION_CHECKS:
            self.assertIn(f"'{name}'", self.config_body, f"{name} 必须是可关闭的非关键检查")

    def test_reputation_checks_are_emitted_by_check_detail(self):
        for name in REPUTATION_CHECKS:
            self.assertIn(f"Format-OptionalResult '{name}'", self.text, f"{name} 必须在检查详情里输出")

    def test_missing_field_is_warn_not_ok(self):
        """缺字段判 warn,不判 ok。
        这是这类接口最容易骗人的地方:字段缺失常被当成「没有风险」。
        """
        for marker in ("数据源未提供风险分", "数据源未提供机房属性", "数据源未提供黑名单信息"):
            self.assertIn(marker, self.text, f"缺少「{marker}」这类提示")
        self.assertNotIn("'IP代理标记' 'ok' '无代理标记'", self.text,
                         "代理标记不能在字段缺失时直接判通过")

    def test_probe_failure_is_warn_not_fail(self):
        """探测失败判 warn,不判 fail。
        探测端点改版、限流、网络抖动都不该把检查判红 —— 那是「没测到」,
        不是「测出有问题」。"""
        self.assertIn("信誉数据源探测失败", self.text)
        self.assertIn("未配置信誉数据源", self.text)

    def test_reputation_url_must_be_https(self):
        """明文响应可被中间人改写:把分数改成 0、代理标记改成 false 完全可行。
        配置时就该拒绝 http,而不是运行时静默忽略。"""
        self.assertIn("ipReputation.url 必须是 https 地址", self.config_body)

    def test_core_has_no_built_in_vendor(self):
        """代码里不写死任何一家数据源。阈值与口径由用户按自己那家的文档给。"""
        for pattern in ("scamalytics", "ip-api.com", "ipquery", "ipqualityscore",
                        "proxycheck", "ipapi.is", "kiprio", "pureip", "ip99"):
            self.assertNotIn(pattern, self.text.lower(),
                             f"核心脚本不应内置 {pattern} 这一家数据源")

    def test_reputation_code_has_no_hardcoded_address(self):
        """信誉相关的代码里不写死任何地址。
        核心脚本别处(控制口 127.0.0.1、DNS 检查的 1.1.1.1 等)不在此列。"""
        for name in ("Get-IpReputationConfig", "Get-IpReputationCache",
                     "Read-IpReputationCache", "Write-IpReputationCache",
                     "ConvertFrom-IpReputationPayload", "Invoke-IpReputationLookup",
                     "Get-IpReputation"):
            start = self.text.index(f"function {name}")
            end = self.text.index("\n}", start)
            body = self.text[start:end]
            self.assertIsNone(re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", body),
                              f"{name} 里不应写死任何地址")

    def test_threshold_is_user_supplied(self):
        """阈值来自配置,不是代码里的常量。"""
        self.assertIn("ipReputation.threshold", self.config_body)
        self.assertIn("$threshold = [double]$ipRepCfg.threshold", self.text)

    def test_api_key_is_not_echoed(self):
        """get-check-config 只回显「配没配」和阈值,不把密钥读回屏幕。"""
        index = self.text.index("'get-check-config' {")
        block = self.text[index:index + 1200]
        self.assertIn("configured", block)
        self.assertNotIn("key = [string]$config.ipReputation.key", block,
                         "get-check-config 不应回显密钥")

    def test_cache_key_contains_provider_url(self):
        """缓存键必须含接口地址:同一个 IP 在不同数据源下结论可以完全不同,
        只按 IP 记账的话,用户换了接口会读到上一个接口留下的旧结论。"""
        self.assertIn("$key = ([string]$Cfg.url) + '|' + $Ip", self.text)

    def test_ui_lists_the_same_items_as_the_core(self):
        """界面列出的名字与核心脚本实际输出的名字必须一一对应,
        且界面上的项数文案必须与实际项数一致。"""
        match = re.search(r"\$checkNames = @\(([^)]*)\)", self.ui)
        self.assertIsNotNone(match, "找不到界面的 checkNames")
        names = [n.strip().strip("'") for n in match.group(1).split(",")]
        core = re.search(r"function Get-CheckItemNames \{(.*?)\n\}", self.text, re.S)
        self.assertIsNotNone(core, "找不到核心脚本的检查项清单")
        core_names = [n.strip().strip("'") for n in
                      re.search(r"return @\(([^)]*)\)", core.group(1)).group(1).split(",")]
        self.assertEqual(names, core_names, "界面与核心脚本的检查项清单必须一致")
        for name in REPUTATION_CHECKS:
            self.assertIn(name, names, f"界面缺少 {name}")

    def test_ui_item_count_matches_the_item_list(self):
        """界面上的「N 项」文案必须等于实际项数。
        上一轮就出过这个毛病:表格已经 15 行,标题还写着「14 项」,
        用户以为改动没生效。"""
        names = re.search(r"\$checkNames = @\(([^)]*)\)", self.ui).group(1)
        count = len([n for n in names.split(",") if n.strip()])
        for text in ("项检查 · 硬性项必须通过", "全部"):
            match = re.search(re.escape(text).replace(r"项检查", r"\d+ 项检查")
                              .replace("全部", r"全部 \d+ 项"), self.ui)
            self.assertIsNotNone(match, f"找不到界面文案: {text}")
        self.assertIn(f"{count} 项检查 · 硬性项必须通过", self.ui,
                      "顶部状态卡的项数与实际项数不一致")
        self.assertIn(f"全部 {count} 项", self.ui, "环境检查卡的项数与实际项数不一致")

    def test_core_rejects_unknown_config_fields(self):
        """配置里出现未知字段必须报错 —— 不然用户写错 key 会静默失效。"""
        self.assertIn("ipReputation 包含未知字段", self.config_body)
        self.assertIn("检查配置包含未知字段", self.config_body)

    def test_numeric_config_fields_accept_both_shell_types(self):
        """阈值与缓存天数是数字,但不能只认一种数字类型。

        PowerShell 5.1 的 ConvertFrom-Json 把整数解成 Int32,PowerShell 7 解成 Int64。
        只认 [int]/[double] 的话,同一份合法配置在一个 shell 上能读、在另一个上
        直接把整份 checks.json 判成无效(「检查配置无效,请恢复默认设置」),
        而 checks.json 是所有检查的公共入口 —— 那等于整个体检在 pwsh 7 上全废。
        """
        self.assertIn("function Test-IpReputationNumber", self.text)
        self.assertIn("Test-IpReputationNumber $t", self.config_body)
        self.assertIn("Test-IpReputationNumber $d", self.config_body)
        self.assertNotIn("$t -isnot [int] -and $t -isnot [double]", self.config_body,
                         "不要把数字类型写死成 Int32")
        self.assertNotIn("$d -isnot [int] -and $d -isnot [double]", self.config_body,
                         "不要把数字类型写死成 Int32")
        start = self.text.index("function Test-IpReputationNumber")
        helper = self.text[start:self.text.index("\n}", start)]
        self.assertIn("[long]", helper, "必须接受 Int64 —— PowerShell 7 会把整数解成 Int64")
        self.assertNotIn("[bool]", helper, "布尔不算数字:JSON 里写 true 应当被拒绝")

    def test_cache_records_are_normalized_to_hashtable(self):
        """缓存读回后,记录对象本身必须是 hashtable。

        ConvertFrom-Json 的产物是 PSCustomObject,而判定代码按 hashtable 的
        ContainsKey 取字段 —— 只归一外层(键)不够,记录本身也要归一,
        否则第二次检查(命中缓存、不发新请求)会在 ContainsKey 上直接崩掉。
        """
        start = self.text.index("function Read-IpReputationCache")
        body = self.text[start:self.text.index("\n}", start)]
        self.assertIn("$rec = $p.Value", body)
        self.assertIn("$r[$rp.Name] = $rp.Value", body,
                      "缓存记录必须逐字段归一成 hashtable")
        self.assertIn("$rep.ContainsKey('score')", self.text,
                      "判定代码按 hashtable 取字段,缓存读回的对象形状必须对得上")

    def test_all_disabled_skips_probe_before_lookup(self):
        detail = self.text[self.text.index("function Invoke-CheckDetail"):]
        rep_start = detail.index("$ipRepCfg = Get-IpReputationConfig")
        lookup_pos = detail.index("Get-IpReputation ([string]$e.ip)", rep_start)
        guard_segment = detail[rep_start:lookup_pos]
        for name in REPUTATION_CHECKS:
            self.assertIn(f"Test-CheckDisabled '{name}'", guard_segment,
                          f"调用信誉接口前必须先检查 {name} 是否已禁用")

    def test_ui_save_omits_key_and_core_preserves_existing_key(self):
        self.assertNotIn("key = [string]$config.ipReputation.key", self.ui,
                         "UI 不应把 get-check-config 缺失的 key 写成空串覆盖保存")
        save_start = self.text.index("function Set-CheckConfigFromJson")
        save_body = self.text[save_start:self.text.index("\n}", save_start)]
        self.assertIn("hasKey", save_body, "省略 key 时应由核心按同 URL 保留既有密钥")

    def test_headers_use_curl_stdin_not_command_line(self):
        start = self.text.index("function Invoke-ProbeText")
        body = self.text[start:self.text.index("\n}", start)]
        self.assertIn("'-K', '-'", body, "带密钥请求头应通过 curl -K - 经 stdin 传递")
        self.assertNotIn("'-H', $h", body, "敏感请求头不应直接放进 curl 命令行参数")
        self.assertIn("ipReputation.key 包含非法控制字符", self.config_body)


if __name__ == "__main__":
    unittest.main()
