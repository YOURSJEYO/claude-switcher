"""Windows 出口探测的多端点冗余(不执行 PowerShell,可在 macOS CI 运行)。

背景:出口探测原本只押在单一端点(cloudflare trace)上。实测链路中断常常是
「掐特定目标」而不是全面断网 —— 同一时刻某个出口查询服务被掐断,另一个却
正常。把探测摊到几个服务商上,任一拿到答案即可;它们查的都是同一个出口,
IP 不变。

这个文件锁住三件事:
1. Get-Egress 确实有多个端点,且按顺序依次尝试;
2. 每个端点只试一次 —— 预算是用来换端点,不是在同一个脆弱端点上反复重试;
3. Fail-Closed 的前置闸门没有被挪动:路径可能失效时仍然零请求、立刻失败。
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "windows/claude-switch.ps1"


class WindowsEgressMultiEndpointStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = CORE.read_bytes()
        cls.text = cls.raw.decode("utf-8-sig")
        start = cls.text.index("function Get-Egress {")
        end = cls.text.index("\n}", start)
        cls.body = cls.text[start:end]

    def test_core_keeps_bom_and_lf(self):
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"), "claude-switch.ps1 必须保持 UTF-8 BOM")
        self.assertEqual(self.raw.count(b"\r\n"), 0)

    def test_egress_probes_multiple_endpoints(self):
        urls = re.findall(r"Url\s*=\s*'(https://[^']+)'", self.body)
        self.assertGreaterEqual(
            len(urls),
            3,
            "出口探测必须摊到多个服务商上,否则单个目标被掐就会误报",
        )
        self.assertEqual(len(urls), len(set(urls)), "端点列表不应有重复")

    def test_probe_endpoints_are_distinct_providers(self):
        """端点来自不同服务商 —— 同一服务商的多个入口不构成冗余。"""
        urls = re.findall(r"Url\s*=\s*'(https://[^']+)'", self.body)
        hosts = {re.sub(r"^https://([^/]+).*$", r"\1", u) for u in urls}
        self.assertEqual(
            len(hosts),
            len(urls),
            "每个端点应当是不同主机,否则冗余只是同一个服务的多个路径",
        )

    def test_each_endpoint_has_a_bounded_attempt_count(self):
        """每个端点的重试次数必须有界。

        实测中断是周期性脉冲:单次约 12~20 秒,整个周期约 40~60 秒。
        每个端点只试一次的话,四个端点连打只够约 22 秒,跨不完一个脉冲就会误报;
        所以每个端点允许试两次,整体存活时间约 45 秒,能盖住一个完整周期。
        但也不能无界 —— 预算是用来换端点,不是无限重试。
        """
        attempts = re.findall(r"Invoke-ProbeText\s+-Url\s+\$probe\.Url\s+-Attempts\s+(\d+)", self.body)
        self.assertTrue(attempts, "找不到按端点循环的探测调用")
        for value in attempts:
            self.assertGreaterEqual(int(value), 1, "每个端点至少要试一次")
            self.assertLessEqual(int(value), 2, "每个端点的重试次数必须有界(最多两次)")

    def test_fail_closed_gate_stays_in_front(self):
        """路径可能失效时仍然零请求、立刻失败 —— 这段闸门必须在任何探测之前。"""
        gate = self.body.index("if (-not (Test-ProxyPathAlive))")
        first_probe = self.body.index("Invoke-ProbeText")
        self.assertLess(
            gate,
            first_probe,
            "Fail-Closed 闸门必须排在探测之前,否则可能在泄漏的路径上敲门",
        )
        self.assertIn("skipped = $true", self.body)

    def test_skipped_result_is_preserved(self):
        """跳过的语义不变:路径失效时返回 skipped,交由上层按 fail 处理。"""
        self.assertIn("return @{ ip = ''; loc = ''; skipped = $true }", self.body)
        self.assertIn("return @{ ip = ''; loc = ''; skipped = $false }", self.body)

    def test_both_ip_and_loc_are_required(self):
        """ip 与 loc 都取到才算有效答案 —— 少一个就换下一个端点。"""
        self.assertIn("if ($ip -and $loc)", self.body)


if __name__ == "__main__":
    unittest.main()
