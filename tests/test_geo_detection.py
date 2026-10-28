"""多源出口探测回归:隔离执行 core/安装器中的 geo_lookup,假 curl 模拟各源。

不访问真实网络,不读取用户配置;安装器的地区探测与核心脚本共用同一段实现。
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GEO_SOURCES = (
    ROOT / "core" / "claude-switch.sh",
    ROOT / "installer" / "安装.command",
    ROOT / "linux" / "install.sh",
)
WINDOWS_INSTALL = ROOT / "windows" / "install.ps1"

DEFAULT_TZ = {
    "US": "America/New_York",
    "JP": "Asia/Tokyo",
    "TW": "Asia/Taipei",
    "HK": "Asia/Hong_Kong",
    "SG": "Asia/Singapore",
    "GB": "Europe/London",
    "DE": "Europe/Berlin",
    "FR": "Europe/Paris",
    "KR": "Asia/Seoul",
    "AU": "Australia/Sydney",
    "CA": "America/Toronto",
}

FAKE_CURL = r"""#!/bin/bash
url=""
for arg in "$@"; do
    case "$arg" in
        http://*|https://*) url="$arg" ;;
    esac
done
key=""
case "$url" in
    https://ipinfo.io/json) key=IPINFO ;;
    https://ipapi.co/json/) key=IPAPI ;;
    https://ifconfig.co/json) key=IFCONFIG ;;
    *cdn-cgi/trace*) key=CLOUDFLARE ;;
    *) exit 7 ;;
esac
body_var="FAKE_${key}_BODY"; body="${!body_var:-}"
status_var="FAKE_${key}_STATUS"; status="${!status_var:-200}"
timeout_var="FAKE_${key}_TIMEOUT"; timeout="${!timeout_var:-}"
if [ -n "$timeout" ]; then exit 28; fi
if [ -n "$body" ]; then printf '%s\n' "$body"; fi
printf '%s\n' "$status"
"""

WRAPPER_TAIL = r"""
set -u
GEO_DIAG_FILE="$1"
geo_fn=geo_lookup
declare -f detect_geo >/dev/null 2>&1 && geo_fn=detect_geo
RESULT=$($geo_fn); rc=$?
printf 'RC=%s\n' "$rc"
printf 'RESULT=%s\n' "$RESULT"
cc=${RESULT%%|*}
if [ "$cc" = "CN" ]; then printf 'CALLER=reject\n'; else printf 'CALLER=accept\n'; fi
printf 'DIAG_START\n'
cat "$GEO_DIAG_FILE" 2>/dev/null
printf 'DIAG_END\n'
"""


def extract_geo_block(path):
    text = path.read_text(encoding="utf-8")
    start = text.index("default_tz_for() {")
    end = text.index("locale_for() {", start)
    return text[start:end]


def field(stdout, name):
    prefix = name + "="
    for line in stdout.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):]
    return None


def diag_lines(stdout):
    try:
        body = stdout.split("DIAG_START\n", 1)[1].split("\nDIAG_END", 1)[0]
    except IndexError:
        return []
    return [line for line in body.splitlines() if line.strip()]


class GeoDetectionTests(unittest.TestCase):
    def run_geo(self, source, fixtures):
        block = extract_geo_block(source)
        with tempfile.TemporaryDirectory(prefix="geo-test-") as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake = bin_dir / "curl"
            fake.write_text(FAKE_CURL, encoding="utf-8")
            fake.chmod(0o755)
            script = root / "geo.sh"
            script.write_text("#!/bin/bash\n" + block + WRAPPER_TAIL, encoding="utf-8")
            diag = root / "diag.txt"
            diag.touch()
            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}:/usr/bin:/bin"
            for name in ("IPINFO", "IPAPI", "IFCONFIG", "CLOUDFLARE"):
                env.pop(f"FAKE_{name}_BODY", None)
                env.pop(f"FAKE_{name}_STATUS", None)
                env.pop(f"FAKE_{name}_TIMEOUT", None)
            for name, spec in fixtures.items():
                if "body" in spec:
                    env[f"FAKE_{name}_BODY"] = spec["body"]
                if "status" in spec:
                    env[f"FAKE_{name}_STATUS"] = str(spec["status"])
                if spec.get("timeout"):
                    env[f"FAKE_{name}_TIMEOUT"] = "1"
            return subprocess.run(
                ["/bin/bash", str(script), str(diag)],
                env=env, text=True, encoding="utf-8",
                capture_output=True, timeout=30)

    def assert_result(self, result, expected):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(field(result.stdout, "RC"), "0", result.stdout + result.stderr)
        self.assertEqual(field(result.stdout, "RESULT"), expected,
                         result.stdout + result.stderr)

    def test_all_scripts_share_geo_block(self):
        blocks = {path: extract_geo_block(path) for path in GEO_SOURCES}
        normalized = {
            path: block.replace("detect_geo() {", "geo_lookup() {")
            for path, block in blocks.items()
        }
        values = list(normalized.values())
        for path, block in normalized.items():
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertIn("geo_lookup()", block)
                self.assertIn("https://www.cloudflare.com/cdn-cgi/trace", block)
        for path in GEO_SOURCES[1:]:
            self.assertIn("detect_geo()", blocks[path],
                          f"{path.name} 必须暴露安装器入口 detect_geo")
        self.assertTrue(all(block == values[0] for block in values),
                        "核心与两个安装器的探测实现必须保持一致")

    def test_ipinfo_success(self):
        for source in GEO_SOURCES:
            with self.subTest(source=source.name):
                result = self.run_geo(source, {
                    "IPINFO": {"body": '{"country":"US","timezone":"America/New_York"}'},
                    "IPAPI": {"body": '{"country_code":"US","timezone":"America/Los_Angeles"}'},
                    "IFCONFIG": {"body": '{"country_iso":"US","timezone":"America/Chicago"}'},
                    "CLOUDFLARE": {"body": "ip=203.0.113.9\nloc=US"},
                })
                self.assert_result(result, "US|America/New_York|ipinfo")
                self.assertEqual(field(result.stdout, "CALLER"), "accept")

    def test_ipinfo_failure_falls_back_to_ipapi(self):
        for source in GEO_SOURCES:
            with self.subTest(source=source.name):
                result = self.run_geo(source, {
                    "IPINFO": {"status": 429},
                    "IPAPI": {"body": '{"country_code":"US","timezone":"America/Los_Angeles"}'},
                    "IFCONFIG": {"status": 500},
                    "CLOUDFLARE": {"status": 503},
                })
                self.assert_result(result, "US|America/Los_Angeles|ipapi")
                self.assertIn("ipinfo HTTP 429", "\n".join(diag_lines(result.stdout)))

    def test_cloudflare_fallback_uses_country_default_timezone(self):
        for source in GEO_SOURCES:
            with self.subTest(source=source.name):
                result = self.run_geo(source, {
                    "IPINFO": {"status": 429},
                    "IPAPI": {"timeout": True},
                    "IFCONFIG": {"status": 403},
                    "CLOUDFLARE": {"body": "fl=1f2\nip=203.0.113.7\nloc=JP\ntls=TLSv1.3"},
                })
                self.assert_result(result, "JP|Asia/Tokyo|cloudflare")
                diag = "\n".join(diag_lines(result.stdout))
                self.assertIn("ipinfo HTTP 429", diag)
                self.assertIn("ipapi 超时/连接失败", diag)
                self.assertIn("ifconfig HTTP 403", diag)

    def test_all_sources_fail_reports_diagnostics(self):
        for source in GEO_SOURCES:
            with self.subTest(source=source.name):
                result = self.run_geo(source, {
                    "IPINFO": {"status": 429},
                    "IPAPI": {"status": 403},
                    "IFCONFIG": {"timeout": True},
                    "CLOUDFLARE": {"status": 502},
                })
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(field(result.stdout, "RESULT"), "||")
                self.assertEqual(field(result.stdout, "RC"), "1")
                diag = diag_lines(result.stdout)
                self.assertEqual(len(diag), 4, diag)
                self.assertIn("ipinfo HTTP 429", diag)
                self.assertIn("ipapi HTTP 403", diag)
                self.assertIn("ifconfig 超时/连接失败", diag)
                self.assertIn("cloudflare HTTP 502", diag)

    def test_all_sources_cn_is_returned_and_rejected(self):
        fixtures = {
            "IPINFO": {"body": '{"country":"CN","timezone":"Asia/Shanghai"}'},
            "IPAPI": {"body": '{"country_code":"CN","timezone":"Asia/Shanghai"}'},
            "IFCONFIG": {"body": '{"country_iso":"CN","timezone":"Asia/Shanghai"}'},
            "CLOUDFLARE": {"body": "loc=CN"},
        }
        for source in GEO_SOURCES:
            with self.subTest(source=source.name):
                result = self.run_geo(source, fixtures)
                self.assert_result(result, "CN|Asia/Shanghai|ipinfo")
                self.assertEqual(field(result.stdout, "CALLER"), "reject")

    def test_conflict_uses_priority_and_warns(self):
        result = self.run_geo(GEO_SOURCES[0], {
            "IPINFO": {"body": '{"country":"US","timezone":"America/New_York"}'},
            "IPAPI": {"body": '{"country_code":"GB","timezone":"Europe/London"}'},
            "IFCONFIG": {"status": 429},
            "CLOUDFLARE": {"body": "loc=GB"},
        })
        self.assert_result(result, "US|America/New_York|ipinfo")
        self.assertIn("WARN:出口国家不一致", result.stderr)
        self.assertIn("ipinfo=US", result.stderr)

    def test_invalid_timezone_falls_back_to_country_default(self):
        result = self.run_geo(GEO_SOURCES[0], {
            "IPINFO": {"body": '{"country":"US","timezone":"Not/A_Real_TZ!"}'},
            "IPAPI": {"status": 429},
            "IFCONFIG": {"status": 429},
            "CLOUDFLARE": {"status": 429},
        })
        self.assert_result(result, "US|America/New_York|ipinfo")

    def test_default_tz_for_mapping(self):
        block = extract_geo_block(GEO_SOURCES[0])
        with tempfile.TemporaryDirectory(prefix="geo-tz-") as tmp:
            script = Path(tmp) / "tz.sh"
            script.write_text(
                "#!/bin/bash\n" + block + "\n" +
                'for cc in US JP TW HK SG GB DE FR KR AU CA; do '
                'printf "%s=%s\\n" "$cc" "$(default_tz_for "$cc")"; done\n'
                'printf "XX=%s\\n" "$(default_tz_for XX)"\n',
                encoding="utf-8")
            result = subprocess.run(["/bin/bash", str(script)], text=True,
                                    encoding="utf-8", capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        for cc, tz in DEFAULT_TZ.items():
            self.assertEqual(field(result.stdout, cc), tz)
        self.assertEqual(field(result.stdout, "XX"), "America/New_York")

    def test_bash_scripts_parse(self):
        for path in (
            ROOT / "core" / "claude-switch.sh",
            ROOT / "installer" / "安装.command",
            ROOT / "linux" / "install.sh",
        ):
            with self.subTest(path=path.name):
                result = subprocess.run(["/bin/bash", "-n", str(path)],
                                        text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_windows_installer_geo_static(self):
        raw = WINDOWS_INSTALL.read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"),
                        "install.ps1 必须保持 UTF-8 with BOM")
        text = raw.decode("utf-8-sig")
        self.assertIn("function Get-GeoInfo", text)
        for url in ("https://ipinfo.io/json", "https://ipapi.co/json/",
                    "https://ifconfig.co/json", "https://www.cloudflare.com/cdn-cgi/trace"):
            self.assertIn(url, text)
        self.assertIn("[Net.SecurityProtocolType]::Tls12", text)
        self.assertIn("TimeoutSec 8", text)
        self.assertIn("function Get-SetupEgress", text)
        self.assertIn("$country=$response.Country", text)
        self.assertIn("$zone=Get-WindowsTimeZoneId $response.Timezone", text)
        self.assertIn("Country=$country;TimeZoneId=$zone;Culture=$culture", text)
        self.assertNotIn("$env:FORCE", text)
        mapping = (WINDOWS_INSTALL.parent / "helpers" / "UserSetup.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("Eastern Standard Time", mapping)
        # 粗略平衡检查:脚本里的花括号必须成对(字符串内无花括号)
        self.assertEqual(text.count("{"), text.count("}"))


if __name__ == "__main__":
    unittest.main()
