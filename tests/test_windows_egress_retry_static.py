"""Windows 出口探测的 Fail-Closed 语义静态回归(不执行 PowerShell,可在 macOS CI 运行)。

背景:`checkdetail` 的「出口IP」原来只发一次请求,长链路代理节点上单次请求有可观
失败率,一次链路抖动就会把硬性检查项判成 fail —— 用户看到的是「检查未过」而不是
「节点暂时不可用」。更糟的是响应为空时对空数组调用 .Trim() 会抛异常,
整轮检查被截断成前两行并以错误码退出。

但重试不能无条件加:代理路径可能已经失效时,任何出站探测都会脱离隧道、
用真实 IP 敲门;那种情况下正确做法是立刻失败(保镖同时杀 Claude),而不是继续试探。

这组用例锁住:
1. 代理路径存活才允许发起出口探测,路径失效时零请求、立刻失败
2. 路径在线时才重试 —— 隧道内失败「只断不绕」,不是泄漏
3. 空响应降级成「未取到」而不是抛异常
4. 杀进程层(保镖)不做网络探测、不做重试退避,保持立刻急停
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "windows/claude-switch.ps1"
GUARD = ROOT / "windows/claude-bodyguard.ps1"

PROBE_HELPERS = ("Invoke-ProbeText", "Invoke-ProbeCode")


def function_body(text, name):
    """截取 function <name> 的函数体(花括号配平)。"""
    start = text.index(f"function {name}")
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise AssertionError(f"unclosed function: {name}")


class WindowsEgressRetryStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = CORE.read_bytes()
        cls.text = cls.raw.decode("utf-8-sig")
        cls.guard = GUARD.read_text(encoding="utf-8-sig")

    def test_core_keeps_bom_and_lf(self):
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"), "claude-switch.ps1 必须保持 UTF-8 BOM")
        self.assertEqual(self.raw.count(b"\r\n"), 0)

    # ---- 杀进程层:立刻急停,不许探测也不许重试 ----

    def test_bodyguard_never_probes_the_network(self):
        """保镖一旦发现代理/TUN 失效就立刻杀进程,不能为了确认情况再发请求。"""
        for token in ("curl", "Invoke-WebRequest", "Invoke-RestMethod", "Test-NetConnection"):
            self.assertNotIn(token, self.guard, f"保镖不应发起网络探测: {token}")

    def test_bodyguard_has_no_retry_backoff(self):
        """保镖不能有重试退避 —— 迟到的急停等于没急停。"""
        self.assertNotIn("Start-Sleep -Milliseconds", self.guard)
        self.assertNotIn("for ($attempt", self.guard)

    def test_bodyguard_still_kills_immediately(self):
        self.assertIn("Stop-Process -Force", self.guard)

    # ---- 闸门:路径失效时不发起任何出口探测 ----

    def test_proxy_path_alive_helper_exists(self):
        self.assertIn("function Test-ProxyPathAlive", self.text)
        body = function_body(self.text, "Test-ProxyPathAlive")
        self.assertIn("Test-ProxyAlive", body)
        self.assertIn("Test-TunUp", body)

    def test_get_egress_is_gated_on_proxy_path(self):
        body = function_body(self.text, "Get-Egress")
        self.assertIn("Test-ProxyPathAlive", body)
        self.assertIn("skipped = $true", body)
        # 闸门必须发生在探测之前。
        self.assertLess(body.index("Test-ProxyPathAlive"), body.index("Invoke-ProbeText"))

    def test_ecosystem_reachability_is_gated_on_proxy_path(self):
        body = function_body(self.text, "Invoke-CheckDetail")
        self.assertIn("elseif (-not (Test-ProxyPathAlive))", body)
        self.assertIn("已跳过探测", body)

    def test_check_output_distinguishes_skipped_probe(self):
        body = function_body(self.text, "Invoke-CheckDetail")
        self.assertIn("if ($e.skipped)", body)
        self.assertIn("代理路径失效,已跳过探测", body)

    # ---- 路径在线时的降级与重试 ----

    def test_probe_helpers_exist(self):
        for name in PROBE_HELPERS:
            self.assertIn(f"function {name}", self.text)

    def test_probe_helpers_retry_with_backoff(self):
        for name in PROBE_HELPERS:
            body = function_body(self.text, name)
            self.assertIn("for ($attempt = 1; $attempt -le $Attempts; $attempt++)", body)
            self.assertIn("Start-Sleep", body)
            self.assertIn("[int]$Attempts = 3", body)

    def test_probe_code_treats_000_as_transport_failure(self):
        body = function_body(self.text, "Invoke-ProbeCode")
        self.assertIn("'%{http_code}'", body)
        self.assertIn("$code -ne '000'", body)

    def test_probe_text_accepts_caller_supplied_validity_gate(self):
        body = function_body(self.text, "Invoke-ProbeText")
        self.assertIn("[scriptblock]$Valid", body)
        self.assertIn("& $Valid $body", body)

    def test_check_path_has_no_direct_curl(self):
        """出口探测不再单发 curl;diagnose-proxy 的 Get-Command 属于显式诊断,不算探测。"""
        for name in ("Get-Egress", "Invoke-CheckDetail", "Invoke-Fix"):
            body = function_body(self.text, name)
            self.assertNotIn("curl.exe", body, f"{name} 不应再直接调用 curl.exe")

    def test_only_probe_helpers_call_curl(self):
        """全脚本只有两个探测点直接调用 curl,且都在带重试的助手内部。"""
        calls = [line.strip() for line in self.text.splitlines() if "& curl.exe" in line]
        self.assertEqual(len(calls), 2, f"直接 curl 调用点应只有探测助手内的两处: {calls}")
        for name in PROBE_HELPERS:
            self.assertIn("& curl.exe", function_body(self.text, name))

    def test_get_egress_goes_through_probe_helper(self):
        body = function_body(self.text, "Get-Egress")
        self.assertIn("Invoke-ProbeText", body)
        self.assertIn("https://www.cloudflare.com/cdn-cgi/trace", body)

    def test_get_egress_requires_both_ip_and_loc(self):
        """重试不能改变判定标准:ip 和 loc 都取到才算有效答案。"""
        body = function_body(self.text, "Get-Egress")
        self.assertIn("(?m)^ip=", body)
        self.assertIn("(?m)^loc=", body)

    def test_get_egress_does_not_trim_a_possibly_empty_array(self):
        """空响应时对空数组调 .Trim() 会抛异常中断整轮检查,必须先 join 成字符串。"""
        body = function_body(self.text, "Get-Egress")
        self.assertNotRegex(body, r"-replace 'ip=',''\)\.Trim\(\)")
        self.assertIn("-join '').Trim()", body)

    def test_ecosystem_reachability_uses_probe_code(self):
        body = function_body(self.text, "Invoke-CheckDetail")
        self.assertIn("Invoke-ProbeCode -Url 'https://claude.ai/'", body)
        self.assertIn("Invoke-ProbeCode -Url 'https://api.anthropic.com/v1/models'", body)

    def test_asn_lookup_uses_probe_text(self):
        body = function_body(self.text, "Invoke-CheckDetail")
        self.assertIn("Invoke-ProbeText -Url \"https://ipinfo.io/", body)
        self.assertIn("Invoke-ProbeText -Url \"https://www.peeringdb.com/api/net?", body)

    def test_asn_lookup_is_gated_on_proxy_path(self):
        """ASN 查询要把出口 IP 交给第三方,路径失效时不能用真实 IP 的源地址发出去。"""
        body = function_body(self.text, "Invoke-CheckDetail")
        self.assertIn("if ($e.ip -and (Test-ProxyPathAlive))", body)

    def test_fix_reverification_shares_the_probe_path(self):
        """一键修复的出口复验必须复用同一条路径,不能另开单发请求。"""
        body = function_body(self.text, "Invoke-Fix")
        self.assertIn("Get-Egress", body)
        self.assertNotIn("cdn-cgi/trace", body)
        self.assertIn("if ($e.skipped)", body)

    def test_retry_defaults_are_consistent(self):
        """两个助手的默认重试次数必须一致,否则同类探测行为会漂移。"""
        defaults = re.findall(r"\[int\]\$Attempts = (\d+)", self.text)
        self.assertTrue(defaults)
        self.assertEqual(len(set(defaults)), 1, f"重试次数默认值不一致: {defaults}")

    def test_integration_test_is_wired_into_ci(self):
        workflow = (ROOT / ".github/workflows/checks.yml").read_text(encoding="utf-8")
        asn_test = (ROOT / "tests/windows-asn-integration.ps1").read_text(encoding="utf-8-sig")
        self.assertGreaterEqual(workflow.count("windows-asn-integration.ps1"), 2)
        self.assertIn("windows-egress-retry-integration.ps1", asn_test,
                      "出口探测回归必须挂到现有 Windows ASN 测试中")


if __name__ == "__main__":
    unittest.main()
