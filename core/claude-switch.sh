#!/bin/bash
# Claude 账号切换器 - 核心脚本 (通用版)
# 用法: claude-switch.sh check | status | switch A|B|C|D | checkdetail | fix | set-region | update [--check|--auto] | diagnose-proxy
set -u
export LC_ALL=en_US.UTF-8

# 随现有单脚本更新分发;在任何账号状态读写、审计/修复/启动之前分派。
if [ "${1:-}" = "diagnose-proxy" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_PROXY_DIAGNOSE'
"""Read-only transport diagnostics for an explicitly selected HTTP/SOCKS proxy."""
import argparse
import concurrent.futures
import ipaddress
import json
import math
import os
import subprocess
from urllib.parse import urlsplit


TARGETS = (
    ("anthropic_api", "https://api.anthropic.com/v1/models"),
    ("claude_web", "https://claude.ai/"),
)


def select_proxy(args, environ):
    if args.proxy is not None:
        value, source = args.proxy, "argument"
    elif args.config is not None:
        with open(args.config, encoding="utf-8") as handle:
            config = json.load(handle)
        if not isinstance(config, dict):
            raise ValueError("invalid config")
        value, source = config.get("proxy_url"), "config"
    else:
        value, source = environ.get("CLAUDE_SWITCHER_PROXY_URL"), "environment"
    if not isinstance(value, str) or not value.strip():
        raise ValueError("proxy required")
    value = value.strip()
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("invalid proxy")
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https", "socks5", "socks5h")
            or not parsed.hostname or parsed.port is None
            or not 0 < parsed.port < 65536
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("invalid proxy")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname.lower() == "localhost"
    # Do not include proxy addresses, credentials, or private config paths in reports.
    public = {"scheme": parsed.scheme, "port": parsed.port,
              "host_scope": "loopback" if loopback else "remote",
              "authentication_configured": parsed.username is not None,
              "source": source}
    return value, public


def probe(name, url, proxy, environ):
    # -q ignores curlrc. Pass proxy credentials over stdin, never in argv/reports.
    quoted = proxy.replace("\\", "\\\\").replace('"', '\\"')
    config = 'proxy = "' + quoted + '"\n'
    args = ["curl", "-q", "--config", "-", "-sS", "-o", os.devnull,
            "--proto", "=https", "--noproxy", "", "--connect-timeout", "6",
            "--max-time", "12", "-w",
            "%{http_code}\t%{http_connect}\t%{ssl_verify_result}\t%{time_appconnect}\t%{time_total}",
            url]
    keep = {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "SYSTEMROOT"}
    clean_env = {k: v for k, v in environ.items() if k in keep}
    result = {"name": name, "url": url, "transport_reached": False,
              "access": "unknown"}
    try:
        process = subprocess.run(args, input=config, env=clean_env, capture_output=True,
                                 text=True, timeout=15)
        fields = process.stdout.strip().split()
        status, connect, verify = map(int, fields[:3])
        tls, elapsed = map(float, fields[3:5])
        if (not 0 <= status <= 599 or not 0 <= connect <= 599 or verify < 0
                or not math.isfinite(tls) or not math.isfinite(elapsed)
                or tls < 0 or elapsed < 0):
            raise ValueError("invalid probe metrics")
        reached = process.returncode == 0 and status > 0 and verify == 0 and tls > 0
        access = ("unauthenticated" if status == 401 else
                  "access_restricted" if status in (403, 407) else
                  "server_error" if status >= 500 else "http_response")
        result.update(curl_exit=process.returncode, http_status=status,
                      proxy_connect_status=connect, tls_verified=reached,
                      elapsed_seconds=elapsed, transport_reached=reached,
                      access=access if reached else "unknown")
    except subprocess.TimeoutExpired:
        result["error"] = "probe_timeout"
    except OSError:
        result["error"] = "curl_unavailable"
    except (ValueError, IndexError):
        result["error"] = "invalid_probe_output"
    return result


class DiagnosticParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default error can echo private URLs or paths from argv.
        raise ValueError("invalid arguments")


def main(argv=None, environ=None):
    parser = DiagnosticParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--proxy", help="explicit proxy URL including a port")
    choice.add_argument("--config", help="private JSON file containing proxy_url")
    environ = os.environ if environ is None else environ
    report = {"schema_version": 1, "mode": "proxy_diagnostics",
              "scope": "unauthenticated_transport_only",
              "account_status": "not_evaluated", "leak_protection": "not_evaluated",
              "launch_allowed": None, "application_started": False,
              "system_modified": False}
    try:
        args = parser.parse_args(argv)
        proxy, public = select_proxy(args, environ)
    except (OSError, ValueError, TypeError):
        report.update(state="configuration_error", error="invalid_or_missing_proxy",
                      hint="Use --proxy, --config, or CLAUDE_SWITCHER_PROXY_URL; an explicit port is required.")
        print(json.dumps(report, ensure_ascii=False))
        return 2
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(probe, name, url, proxy, environ) for name, url in TARGETS]
        checks = [f.result() for f in futures]
    reached = all(check["transport_reached"] for check in checks)
    report.update(proxy=public, checks=checks,
                  state="transport_reached" if reached else "transport_failed")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if reached else 1


if __name__ == "__main__":
    raise SystemExit(main())
PY_PROXY_DIAGNOSE
fi

if [ "${1:-}" = "clash-rules" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_CLASH_RULES'
"""Install and verify the Clash Verge global script without trusting Merge.yaml text."""
import http.client
import ipaddress
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit


DOMAINS = (
    "claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com",
    "challenges.cloudflare.com", "datadoghq.com", "segment.io", "stripe.com",
    "stripe.network", "stripecdn.com", "intercom.io", "intercomcdn.com",
    "intercomassets.com",
)
PORTS = (3478, 5349, 19302)
SCRIPT_BEGIN = "// >>> claude-switcher managed rules >>>"
SCRIPT_END = "// <<< claude-switcher managed rules <<<"
MERGE_BEGIN = "# >>> claude-switcher pinned rules >>>"
MERGE_END = "# <<< claude-switcher pinned rules <<<"


def fail(message):
    print("FAIL:" + message, file=sys.stderr)
    raise SystemExit(1)


def read_yaml_scalar(path, key):
    if not path.exists():
        return ""
    match = re.search(r"^" + re.escape(key) + r":[ \t]*(.*)$", read_text(path), re.M)
    if not match:
        return ""
    value = match.group(1).strip()
    if value.startswith('"'):
        return json.JSONDecoder().raw_decode(value)[0]
    if value.startswith("'"):
        match = re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?", value)
        if not match:
            fail("无法读取 Clash 控制接口配置")
        return match.group(1).replace("''", "'")
    value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
    if value in {"", "null", "~"}:
        return ""
    if value.startswith(("|", ">", "*", "&", "[", "{")):
        fail("Clash 控制接口需要普通标量配置")
    return value


def read_text(path):
    return path.read_bytes().decode("utf-8-sig")


def controller_config(clash_dir):
    for name in ("clash-verge.yaml", "verge.yaml"):
        path = clash_dir / name
        unix_path = read_yaml_scalar(path, "external-controller-unix")
        secret = read_yaml_scalar(path, "secret")
        if "\r" in secret or "\n" in secret:
            fail("Clash 控制接口密钥格式无效")
        if unix_path and hasattr(socket, "AF_UNIX"):
            if not os.path.isabs(unix_path):
                fail("Clash Unix socket 路径必须为绝对路径")
            # 生成的配置可能记着已失效的临时 socket(Clash Verge 重启后路径会变);
            # 依次尝试配置路径与服务实际使用的用户级 socket,都存在才继续走 TCP 分支
            candidates = [unix_path]
            if hasattr(os, "getuid"):
                candidates.append(
                    "/var/run/clash-verge-service/users/%d/verge-mihomo.sock" % os.getuid())
            for candidate in candidates:
                if os.path.isabs(candidate) and Path(candidate).exists():
                    return ("unix", candidate, None), secret
        endpoint = read_yaml_scalar(path, "external-controller")
        if endpoint:
            if not endpoint.startswith(("http://", "https://")):
                endpoint = "http://" + endpoint
            parsed = urlsplit(endpoint)
            host = parsed.hostname
            if host in {"0.0.0.0", "::"}:
                host = "127.0.0.1" if host == "0.0.0.0" else "::1"
            if host != "localhost":
                try:
                    local = ipaddress.ip_address(host).is_loopback
                except ValueError:
                    local = False
                if not local:
                    fail("只允许验证本机 Clash 控制接口")
            if (parsed.scheme not in {"http", "https"} or not parsed.port
                    or parsed.username or parsed.password or parsed.path not in {"", "/"}
                    or parsed.query or parsed.fragment):
                fail("Clash 控制接口地址格式无效")
            return (parsed.scheme, host, parsed.port), secret
    fail("未找到本机 Clash 控制接口，无法验证内核规则")


def api_get(endpoint, secret, path):
    headers = {"Accept": "application/json"}
    if secret:
        headers["Authorization"] = "Bearer " + secret
    scheme, host, port = endpoint
    connection = None
    try:
        if scheme == "unix":
            connection = http.client.HTTPConnection("localhost", timeout=2)
            connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.sock.settimeout(2)
            connection.sock.connect(host)
        else:
            cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
            connection = cls(host, port, timeout=2)
        # http.client connects directly; inherited proxy variables are never used.
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            fail("Clash 内核接口未返回成功状态")
        data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            fail("Clash 内核接口响应过大")
        value = json.loads(data.decode("utf-8"))
        if not isinstance(value, dict):
            fail("Clash 内核接口返回格式异常")
        return value
    except (http.client.HTTPException, OSError, ValueError) as exc:
        fail("Clash 内核接口不可用(" + exc.__class__.__name__ + ")")
    finally:
        if connection:
            connection.close()


def selected_proxy(proxies, name, seen=None):
    seen = set() if seen is None else seen
    if name in seen:
        fail("代理组存在循环引用")
    seen.add(name)
    item = proxies.get(name)
    if not isinstance(item, dict):
        fail("代理组不存在:" + name)
    if "all" in item or "now" in item:
        current = item.get("now")
        if not current or current == name:
            fail("代理组没有可用的当前节点:" + name)
        return selected_proxy(proxies, current, seen)
    return item


def validate_group(state, group, policy):
    proxies = state.get("proxies", {}).get("proxies", {})
    if not isinstance(proxies, dict) or group in {"DIRECT", "REJECT", "GLOBAL", "PASS"}:
        fail("请选择实际的代理组")
    if not isinstance(proxies.get(group), dict) or "all" not in proxies[group]:
        fail("配置的代理组不存在")
    selected = selected_proxy(proxies, group)
    selected_type = str(selected.get("type", "")).lower()
    if selected_type in {"direct", "reject", "block"}:
        fail("代理组当前节点为直连或拒绝，请选择代理节点")
    if policy == "proxy" and selected.get("udp") is not True:
        fail("当前节点未确认支持 UDP，请更换节点或选择 reject 策略")


def norm(value):
    return re.sub(r"[\s()_-]+", "", str(value).upper()).replace("&&", ",")


def expected_rules():
    rules = [("port", p) for p in PORTS]
    rules.extend(("domain", d) for d in DOMAINS)
    return rules


def verify_runtime(clash_dir, group, policy):
    base, secret = controller_config(clash_dir)
    state = {
        "configs": api_get(base, secret, "/configs"),
        "rules": api_get(base, secret, "/rules"),
        "proxies": api_get(base, secret, "/proxies"),
    }
    if str(state["configs"].get("mode", "")).lower() != "rule":
        fail("Clash 当前不是 rule 模式")
    validate_group(state, group, policy)
    rules = state["rules"].get("rules")
    if not isinstance(rules, list):
        fail("Clash /rules 返回格式异常")
    expected = expected_rules()
    if len(rules) < len(expected):
        fail("运行中的规则数量不足")
    for index, (kind, value) in enumerate(expected):
        if kind == "port":
            rule = rules[index]
            target = "REJECT" if policy == "reject" else group
            payload = norm(rule.get("payload", "")) if isinstance(rule, dict) else ""
            if (not isinstance(rule, dict) or str(rule.get("type", "")).upper() != "AND"
                    or payload != "NETWORK,UDP,DSTPORT," + str(value)
                    or rule.get("proxy") != target
                    or (rule.get("extra") or {}).get("disabled") is True):
                fail("运行规则未按策略置顶:UDP/" + str(value))
        else:
            rule = rules[index]
            if (not isinstance(rule, dict)
                    or str(rule.get("type", "")).upper().replace("_", "-") not in {"DOMAIN-SUFFIX", "DOMAINSUFFIX"}
                    or str(rule.get("payload", "")).strip().lower() != value
                    or rule.get("proxy") != group
                    or (rule.get("extra") or {}).get("disabled") is True):
                fail("运行规则未按策略置顶:" + value)
    return state


def rule_strings(group, policy):
    target = "REJECT" if policy == "reject" else group
    return ([f"AND,((NETWORK,UDP),(DST-PORT,{port})),{target}" for port in PORTS] +
            [f"DOMAIN-SUFFIX,{domain},{group}" for domain in DOMAINS])


def managed_block(group, policy):
    encoded = json.dumps(rule_strings(group, policy), ensure_ascii=False)
    group_json = json.dumps(group, ensure_ascii=False)
    return f"""{SCRIPT_BEGIN}
;(function () {{
  const originalMain = main;
  const pinnedRules = {encoded};
  const group = {group_json};
  main = function (config, ...args) {{
    const result = originalMain(config, ...args);
    if (!result || typeof result !== \"object\" || Array.isArray(result)) throw new Error(\"claude-switcher: original main must return a config object\");
    if (!Array.isArray(result[\"proxy-groups\"]) || !result[\"proxy-groups\"].some((item) => item && item.name === group)) throw new Error(\"claude-switcher: configured proxy group missing\");
    if (result.rules !== undefined && !Array.isArray(result.rules)) throw new Error(\"claude-switcher: rules must be an array\");
    result.rules = pinnedRules.concat((result.rules || []).filter((rule) => !pinnedRules.includes(rule)));
    return result;
  }};
}})();
{SCRIPT_END}"""


def script_text(path, group, policy):
    old = read_text(path) if path.exists() else ""
    block = managed_block(group, policy)
    if SCRIPT_BEGIN in old:
        if old.count(SCRIPT_BEGIN) != 1 or old.count(SCRIPT_END) != 1:
            fail("Script.js 中存在未闭合的 claude-switcher 管理块")
        pattern = re.compile(re.escape(SCRIPT_BEGIN) + r".*?" + re.escape(SCRIPT_END), re.S)
        if old.index(SCRIPT_END) < old.index(SCRIPT_BEGIN):
            fail("Script.js 中的管理块顺序无效")
        return pattern.sub(lambda _: block, old, count=1)
    if SCRIPT_END in old:
        fail("Script.js 中存在孤立的 claude-switcher 管理块")
    if not old.strip():
        old = "function main(config) { return config; }\n"
    match = re.search(r"function\s+main\s*\(", old)
    if not match:
        fail("现有 Script.js 没有可组合的 main(config)，已停止以免覆盖用户脚本")
    return old + ("" if old.endswith("\n") else "\n") + block + "\n"


def migrate_merge(path):
    if not path.exists():
        return None
    old = read_text(path)
    if MERGE_BEGIN not in old:
        if MERGE_END in old:
            fail("Merge.yaml 中存在孤立的 claude-switcher 管理块")
        return old
    if old.count(MERGE_BEGIN) != 1 or old.count(MERGE_END) != 1 or old.index(MERGE_END) < old.index(MERGE_BEGIN):
        fail("Merge.yaml 中存在未闭合的 claude-switcher 管理块")
    pattern = re.compile(r"(?ms)^[ \t]*" + re.escape(MERGE_BEGIN) + r"[ \t]*\r?\n.*?^[ \t]*" + re.escape(MERGE_END) + r"[ \t]*\r?\n?")
    new = pattern.sub("", old, count=1)
    return new


def write_changes(changes):
    changes = {path: data.encode("utf-8") for path, data in changes.items()
               if not path.exists() or path.read_bytes() != data.encode("utf-8")}
    originals, staged, replaced = {}, {}, []
    try:
        for path, data in changes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            originals[path] = path.read_bytes() if path.exists() else None
            if path.exists():
                shutil.copy2(path, path.with_name(path.name + ".bak." + str(time.time_ns())))
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".claude-switcher-", delete=False) as handle:
                staged[path] = Path(handle.name)
                handle.write(data)
            if path.exists():
                staged[path].chmod(path.stat().st_mode & 0o777)
        for path, temp in staged.items():
            os.replace(temp, path)
            replaced.append(path)
    except OSError:
        for path in reversed(replaced):
            if originals[path] is None:
                path.unlink()
            else:
                path.write_bytes(originals[path])
        raise
    finally:
        for temp in staged.values():
            if temp.exists():
                temp.unlink()


def assess_probe(policy, expected_ip, output, exit_code):
    if exit_code != "0":
        return "fail:STUN 探测执行失败，未确认 UDP 出口"
    try:
        expected = ipaddress.IPv4Address(expected_ip)
    except ValueError:
        return "fail:未获取有效的 IPv4 出口，无法比对 STUN 结果"
    if output == "RESULT:NONE":
        if policy == "reject":
            return "ok:常见 STUN UDP 拒绝规则已验证，探测无响应"
        return "fail:STUN 无响应，无法确认 UDP 是否经过代理"
    if not output.startswith("RESULT:"):
        return "fail:STUN 探测结果格式异常"
    try:
        addresses = [ipaddress.IPv4Address(value) for value in output[7:].split(",")]
    except ValueError:
        return "fail:STUN 探测结果格式异常"
    if policy == "reject":
        return "fail:拒绝策略下仍收到 STUN 响应，请检查运行规则"
    if any(address != expected for address in addresses):
        return "fail:STUN 暴露了非代理出口地址"
    return "ok:STUN 仅返回代理出口地址"


def main():
    if len(sys.argv) < 5:
        fail("内部参数不足")
    action, clash_dir, base_dir, group = sys.argv[1:5]
    clash_dir = Path(clash_dir)
    base_dir = Path(base_dir)
    policy_path = base_dir / "webrtc-policy"
    policy = sys.argv[5] if len(sys.argv) > 5 else ""
    policy = policy or (read_text(policy_path).strip() if policy_path.exists() else "proxy")
    if policy not in {"proxy", "reject"}:
        fail("WEBRTC_POLICY 只能是 proxy 或 reject")
    if action == "policy":
        print(policy)
        return 0
    if action == "assess" and len(sys.argv) == 9:
        print(assess_probe(policy, *sys.argv[6:9]))
        return 0
    if action == "mode":
        base, secret = controller_config(clash_dir)
        print(str(api_get(base, secret, "/configs").get("mode", "")).lower())
        return 0
    if not group or any(char in group for char in ",\r\n"):
        fail("代理组名为空或包含规则分隔符")
    if action == "verify":
        verify_runtime(clash_dir, group, policy)
        print("OK:运行时规则已验证(" + policy + ")")
        return 0
    if action != "write":
        fail("未知内部动作")

    base, secret = controller_config(clash_dir)
    state = {"configs": api_get(base, secret, "/configs"),
             "proxies": api_get(base, secret, "/proxies")}
    if str(state["configs"].get("mode", "")).lower() != "rule":
        fail("Clash 当前不是 rule 模式")
    validate_group(state, group, policy)
    profiles = clash_dir / "profiles"
    script_path = profiles / "Script.js"
    merge_path = profiles / "Merge.yaml"
    new_script = script_text(script_path, group, policy)
    new_merge = migrate_merge(merge_path)
    changes = {script_path: new_script, policy_path: policy + "\n"}
    if new_merge is not None:
        changes[merge_path] = new_merge
    write_changes(changes)
    print("OK:全局脚本已写入(" + policy + ")")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, AttributeError):
        fail("规则配置处理失败，未确认修复；请检查配置格式与权限")
PY_CLASH_RULES
fi

# ============ 安装时可配置项(安装程序会自动改写) ============
PROXY_MODE="clash-verge"       # 代理客户端: clash-verge|shadowrocket|sing-box|clashx|surge|auto
PROXY_GROUP="IpEqual"          # Clash 代理组名(安装时自动探测)
COUNTRY_TARGET="US"            # 目标出口国家(安装时按出口自动识别)
TZ_TARGET="America/New_York"   # 锁定时区,应与出口IP所在城市一致
LOCALE_TARGET="en_US"          # 锁定地区格式
# ============================================================

DATA="$HOME/Library/Application Support/Claude"
BASE="$HOME/.claude-switcher"
LOG="$HOME/Library/Logs/claude-switch.log"
CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
ROUTE_MISSED=""
KEEP_STAGED=0
mkdir -p "$BASE/accounts"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

# TUN 在线判定:存在 fake-ip 网段地址即视为 TUN 已接管(兼容各种 TUN 设备名)
tun_up() { ifconfig 2>/dev/null | grep -q 'inet 198\.18\.'; }

# 代理客户端显示名(供检查细节输出)
proxy_name() {
    case "$PROXY_MODE" in
        clash-verge)  echo "Clash Verge" ;;
        shadowrocket) echo "Shadowrocket" ;;
        sing-box)     echo "sing-box" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        auto)         echo "代理客户端" ;;
        *)            echo "$PROXY_MODE" ;;
    esac
}

# 可 open -a 启动的客户端 App 名(sing-box/auto 无标准 App,返回空)
proxy_app_name() {
    case "$PROXY_MODE" in
        clash-verge)  echo "Clash Verge" ;;
        shadowrocket) echo "Shadowrocket" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        *)            echo "" ;;
    esac
}

# Shadowrocket 在 Mac 上表现为 VPN 配置;launchd/非图形环境下 scutil 可能查不到该行,此时以 TUN 判定为准(避免误杀)
shadowrocket_up() {
    nc=$(scutil --nc list 2>/dev/null)
    if echo "$nc" | grep -q 'com.liguangming.Shadowrocket'; then
        echo "$nc" | grep 'com.liguangming.Shadowrocket' | grep -q '(Connected)'
    else
        tun_up
    fi
}

# 代理内核在线判定:按安装时识别的客户端分派;auto 时任一命中即活
proxy_alive() {
    case "$PROXY_MODE" in
        clash-verge)  pgrep -f verge-mihomo >/dev/null 2>&1 ;;
        shadowrocket) shadowrocket_up ;;
        sing-box)     pgrep -f sing-box >/dev/null 2>&1 ;;
        clashx)       pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1 ;;
        surge)        pgrep -f Surge >/dev/null 2>&1 ;;
        auto)         pgrep -f verge-mihomo >/dev/null 2>&1 || shadowrocket_up \
                      || pgrep -f sing-box >/dev/null 2>&1 \
                      || pgrep -x ClashX >/dev/null 2>&1 || pgrep -f clash >/dev/null 2>&1 \
                      || pgrep -f Surge >/dev/null 2>&1 ;;
        *)            pgrep -f verge-mihomo >/dev/null 2>&1 ;;
    esac
}

# 单文件内嵌 Python 的隔离入口;策略从 WEBRTC_POLICY 或持久化文件读取。
clash_rules() {
    local action="$1"
    shift
    "${BASH:-/bin/bash}" "$0" clash-rules "$action" "$CLASH_DIR" "$BASE" "$PROXY_GROUP" "${WEBRTC_POLICY:-}" "$@"
}

# 只接受运行中内核加载的规则，不再用配置文本或 fake-ip 代替。
merge_ok() { clash_rules verify >/dev/null 2>&1; }
stun_ok() { merge_ok; }
# 当前 Clash 模式(rule/global/direct);读取失败返回空
clash_mode() { clash_rules mode 2>/dev/null; }

# 置顶规则行为检测:三个生态域名全部解析到 fake-ip 段(198.18.x.x)即视为已置顶;未命中域名记入 ROUTE_MISSED
route_ok() {
    ROUTE_MISSED=""
    local d a
    for d in claude.ai api.anthropic.com claudeusercontent.com; do
        a=$(dig +short +time=3 +tries=1 "$d" 2>/dev/null | head -1)
        case "$a" in
            198.18.*) ;;
            *) ROUTE_MISSED="$ROUTE_MISSED $d" ;;
        esac
    done
    [ -z "$ROUTE_MISSED" ]
}

# 国家代码 → 默认 IANA 时区(cloudflare trace 等来源不带时区时使用)
default_tz_for() {
    case "$1" in
        US) echo America/New_York ;; JP) echo Asia/Tokyo ;; TW) echo Asia/Taipei ;;
        HK) echo Asia/Hong_Kong ;; SG) echo Asia/Singapore ;; GB) echo Europe/London ;;
        DE) echo Europe/Berlin ;; FR) echo Europe/Paris ;; KR) echo Asia/Seoul ;;
        AU) echo Australia/Sydney ;; CA) echo America/Toronto ;;
        *) echo America/New_York ;;
    esac
}

# 出口探测辅助:严格校验两位大写国家码与 IANA 时区格式
_geo_valid_country() {
    case "$1" in [A-Z][A-Z]) return 0 ;; *) return 1 ;; esac
}
_geo_valid_tz() {
    [[ "$1" =~ ^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$ ]]
}
_geo_json_field() {
    printf '%s\n' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}
_geo_diag_add() {
    GEO_DIAG="${GEO_DIAG:+$GEO_DIAG; }$1"
    if [ -n "${GEO_DIAG_FILE:-}" ]; then
        printf '%s\n' "$1" >>"$GEO_DIAG_FILE"
    fi
}
# 取一个源;失败把简短原因(HTTP 码/超时)记进诊断,不打印
_geo_fetch() {
    local out rc code
    _GEO_BODY=""
    out=$(curl -s --max-time 8 -w '\n%{http_code}' "$1" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
        _geo_diag_add "$2 超时/连接失败"
        return 1
    fi
    if [ -z "$out" ]; then
        _geo_diag_add "$2 无响应"
        return 1
    fi
    code=$(printf '%s\n' "$out" | tail -n 1)
    case "$code" in
        200)
            _GEO_BODY=$(printf '%s\n' "$out" | sed '$d')
            return 0 ;;
        [0-9][0-9][0-9])
            _geo_diag_add "$2 HTTP $code"
            return 1 ;;
        *)
            # 没有 -w 状态行时按成功处理(兼容 curl 替身/中间层)
            _GEO_BODY="$out"
            return 0 ;;
    esac
}
# 记录一个成功源;首个成功源优先,后续来源国家不一致只告警
_geo_consider() {
    [ -z "$1" ] && return 0
    if [ -z "$_GEO_CC" ]; then
        _GEO_CC="$1"; _GEO_TZ="$2"; _GEO_SRC="$3"
    elif [ "$1" != "$_GEO_CC" ]; then
        printf 'WARN:出口国家不一致(%s=%s %s=%s),采用优先级更高的 %s\n' \
            "$_GEO_SRC" "$_GEO_CC" "$3" "$1" "$_GEO_SRC" >&2
    fi
}

# 多源出口探测:ipinfo → ipapi → ifconfig → cloudflare trace,成功源按此优先级取首个;
# 全部失败输出 "||",各源失败原因写入 GEO_DIAG_FILE(命令替换会丢子 shell 变量)。
geo_lookup() {
    local cc tz loc
    local _GEO_BODY="" _GEO_CC="" _GEO_TZ="" _GEO_SRC=""
    GEO_DIAG=""

    if _geo_fetch "https://ipinfo.io/json" ipinfo; then
        cc=$(_geo_json_field "$_GEO_BODY" country)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ipinfo
        else
            _geo_diag_add "ipinfo 国家字段无效"
        fi
    fi

    if _geo_fetch "https://ipapi.co/json/" ipapi; then
        cc=$(_geo_json_field "$_GEO_BODY" country_code)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ipapi
        else
            _geo_diag_add "ipapi 国家字段无效"
        fi
    fi

    if _geo_fetch "https://ifconfig.co/json" ifconfig; then
        cc=$(_geo_json_field "$_GEO_BODY" country_iso)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ifconfig
        else
            _geo_diag_add "ifconfig 国家字段无效"
        fi
    fi

    if _geo_fetch "https://www.cloudflare.com/cdn-cgi/trace" cloudflare; then
        loc=$(printf '%s\n' "$_GEO_BODY" | tr -d '\r' | sed -n 's/^loc=\([A-Za-z][A-Za-z]\)$/\1/p' | head -n 1 | tr 'a-z' 'A-Z')
        if _geo_valid_country "$loc"; then
            _geo_consider "$loc" "$(default_tz_for "$loc")" cloudflare
        else
            _geo_diag_add "cloudflare loc 无效"
        fi
    fi

    if [ -z "$_GEO_CC" ]; then
        printf '||\n'
        return 1
    fi
    printf '%s|%s|%s\n' "$_GEO_CC" "$_GEO_TZ" "$_GEO_SRC"
    return 0
}

# 国家代码 → 地区格式映射(未收录的国家回退 en_US)
locale_for() {
    case "$1" in
        US) echo en_US ;; JP) echo ja_JP ;; TW) echo zh_TW ;; HK) echo zh_HK ;;
        SG) echo en_SG ;; GB) echo en_GB ;; DE) echo de_DE ;; FR) echo fr_FR ;;
        KR) echo ko_KR ;; AU) echo en_AU ;; CA) echo en_CA ;; *) echo en_US ;;
    esac
}

# IP 审查:记录出口IP并统计最近48h内不同IP个数(账号画像风险指标)
iphist_count() {
    [ -z "$1" ] && { echo 0; return; }
    local HIST="$BASE/iphistory.log"
    local now=$(date +%s)
    echo "$1 $now" >>"$HIST"
    # 裁掉48小时(172800秒)以前的记录
    awk -v cutoff=$((now-172800)) '$2>=cutoff' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
    # 统计48h内不同IP个数
    awk '{print $1}' "$HIST" | sort -u | wc -l | tr -d ' '
}

# ---------- 安全检查 ----------
check() {
    fails=""

    proxy_alive || fails="$fails;代理内核未运行"
    tun_up || fails="$fails;TUN网卡不在线"

    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    [ "$loc" = "$COUNTRY_TARGET" ] || fails="$fails;出口IP异常(${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET)"
    ipwarn=""
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    if [ -n "$ip" ] && [ -n "$lastip" ] && [ "$ip" != "$lastip" ]; then
        ipwarn="注意:出口IP与上次不同($lastip -> $ip)"
    fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"

    # IP 审查:48h 内出口 IP 变化 ≥3 次追加警告(只 warn 不 fail)
    ipn=$(iphist_count "$ip")
    if [ "$ipn" -ge 3 ] 2>/dev/null; then
        ipwarn="${ipwarn:+$ipwarn; }注意:48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
    fi

    tz=$(readlink /etc/localtime 2>/dev/null)
    [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ] || fails="$fails;时区异常($tz)"

    locale=$(defaults read -g AppleLocale 2>/dev/null)
    [ "$locale" = "$LOCALE_TARGET" ] || fails="$fails;地区异常($locale)"

    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    echo "$v6" | grep -qi 'off' || fails="$fails;IPv6未关闭"

    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) ;;
        *) fails="$fails;DNS未走隧道(返回${dnsip:-空})" ;;
    esac

    wr=$(webrtc_status "$ip")
    case "$wr" in fail:*) fails="$fails;WebRTC:${wr#fail:}" ;; esac

    guard_state=$(bodyguard_status)
    case "$guard_state" in
        ok:*) ;;
        fail:*) fails="$fails;保镖:${guard_state#fail:}" ;;
        *) fails="$fails;保镖:状态无法验证" ;;
    esac

    # 置顶规则:Clash Verge 验证运行内核;全局模式下全部流量走代理,规则不适用;其他客户端只看行为检测
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        [ "$(clash_mode)" = "global" ] || merge_ok || fails="$fails;运行中置顶规则未验证"
    else
        route_ok || fails="$fails;置顶规则缺失(未命中:${ROUTE_MISSED# })"
    fi

    defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' || {
        syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
        [[ "$syslang" == en* ]] || fails="$fails;客户端语言为中文"
    }

    r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
    r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
    { [ "$r1" = "000" ] || [ "$r2" = "000" ]; } && fails="$fails;Anthropic生态不可达($r1/$r2)"

    if [ -n "$fails" ]; then
        echo "FAIL:${fails#;}"
        return 1
    fi
    echo "OK:$ip${ipwarn:+|$ipwarn}"
    return 0
}

# WebRTC/STUN 探测:返回 RESULT:ip,ip 或 RESULT:NONE 或空
webrtc_test() {
    python3 "$BASE/stun-probe.py" 2>/dev/null
}

# 日常检查与修复共用此判断。先确认规则，再允许探测，避免向已知直连路径发包。
webrtc_status() {
    local verified result probe_rc assessment mode leak wips w
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        mode=$(clash_mode)
        # 全局模式不经过规则匹配,直接按"STUN 结果是否等于当前出口"判断
        if [ "$mode" = "global" ]; then
            result=$(webrtc_test)
            probe_rc=$?
            [ "$probe_rc" -ne 0 ] && { echo "fail:STUN 探测执行失败，未确认 UDP 出口"; return; }
            case "$result" in
                RESULT:NONE) echo "warn:UDP 无响应,全局模式下无法验证(可能已被节点拦截)" ;;
                RESULT:*)
                    leak=""
                    wips=${result#RESULT:}
                    OLDIFS=$IFS; IFS=','
                    for w in $wips; do [ -n "$1" ] && [ "$w" != "$1" ] && leak="$leak $w"; done
                    IFS=$OLDIFS
                    if [ -n "$leak" ]; then
                        echo "fail:暴露非代理IP:${leak# }"
                    else
                        echo "ok:仅暴露代理出口IP(全局模式)"
                    fi ;;
                *) echo "fail:STUN 探测结果格式异常" ;;
            esac
            return
        fi
        if ! verified=$(clash_rules verify 2>&1); then
            echo "fail:运行规则未验证:${verified#FAIL:}"
            return
        fi
    fi
    result=$(webrtc_test)
    probe_rc=$?
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        assessment=$(clash_rules assess "$1" "$result" "$probe_rc" 2>/dev/null)
    else
        # 其他客户端的规则由用户管理，不能把 reject 的无响应视为已验证。
        assessment=$(WEBRTC_POLICY=proxy clash_rules assess "$1" "$result" "$probe_rc" 2>/dev/null)
    fi
    case "$assessment" in
        ok:*|fail:*) echo "$assessment" ;;
        *) echo 'fail:无法评估 STUN 结果' ;;
    esac
}

# 保镖脚本由 root 安装，MODE 在安装时写死。核心切客户端后必须检测模式一致性，
# 否则旧保镖可能按错误的代理进程状态关闭 Claude，单看 launchctl 在线会误报成功。
bodyguard_status() {
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        echo 'fail:未安装'
        return
    fi
    local guard="/Library/Application Support/claude-switcher/claude-bodyguard.sh"
    if [ ! -r "$guard" ]; then
        echo 'fail:守护脚本不可读或缺失(请重新运行安装器)'
        return
    fi
    local guard_mode
    guard_mode=$(sed -n 's/^MODE="\([^"]*\)".*/\1/p' "$guard" | head -1)
    if [ -z "$guard_mode" ]; then
        echo 'fail:守护模式无法识别(请重新运行安装器)'
        return
    fi
    if [ "$guard_mode" != "$PROXY_MODE" ]; then
        echo "fail:客户端不一致(核心=$PROXY_MODE,保镖=$guard_mode;请重新运行安装器同步)"
        return
    fi
    local lastkill
    lastkill=$(tail -1 "$HOME/Library/Logs/claude-bodyguard.log" 2>/dev/null | cut -c1-40)
    echo "ok:${lastkill:-待命}"
}

# 逐项输出检查结果(供UI使用): 名称=ok|fail:细节
checkdetail() {
    if proxy_alive; then
        case "$PROXY_MODE" in
            shadowrocket) echo '代理内核=ok:Shadowrocket 已连接' ;;
            *) echo "代理内核=ok:$(proxy_name) 运行中" ;;
        esac
    else
        echo "代理内核=fail:$(proxy_name) 未运行"
    fi
    if tun_up; then echo 'TUN网卡=ok'; else echo 'TUN网卡=fail:不在线'; fi
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then echo "出口IP=ok:$ip/$loc"; else echo "出口IP=fail:${ip:-无}/${loc:-未知}(期望$COUNTRY_TARGET)"; fi
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    ipst=""; ipdt=""
    if [ -z "$ip" ]; then echo 'IP一致=fail:未获取到出口IP'
    elif [ -z "$lastip" ]; then ipst="ok"; ipdt="首次记录"
    elif [ "$ip" = "$lastip" ]; then ipst="ok"
    else ipst="warn"; ipdt="$lastip → $ip"; fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"
    # IP 审查:48h 内出口 IP 变化 ≥3 次提示账号画像风险(只 warn 不 fail)
    if [ -n "$ipst" ]; then
        ipn=$(iphist_count "$ip")
        if [ "$ipn" -ge 3 ] 2>/dev/null; then
            if [ "$ipst" = "ok" ]; then
                ipst="warn"; ipdt="48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
            else
                ipdt="$ipdt;48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
            fi
        fi
        if [ -z "$ipdt" ]; then echo "IP一致=$ipst"; else echo "IP一致=$ipst:$ipdt"; fi
    fi
    tz=$(readlink /etc/localtime 2>/dev/null)
    if [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ]; then echo '时区=ok'; else echo "时区=fail:$tz"; fi
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" = "$LOCALE_TARGET" ]; then echo '地区=ok'; else echo "地区=fail:$locale"; fi
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    if echo "$v6" | grep -qi 'off'; then echo 'IPv6=ok:已关闭'; else echo 'IPv6=fail:未关闭'; fi
    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) echo 'DNS=ok:走隧道' ;;
        *) echo "DNS=fail:未走隧道(${dnsip:-空})" ;;
    esac
    echo "WebRTC=$(webrtc_status "$ip")"
    echo "保镖=$(bodyguard_status)"
    # 置顶规则:Clash Verge 验证运行内核;全局模式下规则不适用(全部流量已走代理)
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if [ "$(clash_mode)" = "global" ]; then
            echo '规则置顶=ok:全局模式(全部流量走代理)'
        elif merge_ok; then
            echo '规则置顶=ok'
        else
            echo '规则置顶=fail:未生效'
        fi
    else
        if route_ok; then
            echo '规则置顶=ok:行为检测通过'
        else
            echo "规则置顶=fail:未命中(${ROUTE_MISSED# }),请在 $(proxy_name) 中自行加置顶规则"
        fi
    fi
    # 12. Claude 客户端语言(单独设为英文,或系统首选语言为英文均可;防止 JS 层读出中文)
    clang=$(defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | head -2)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if echo "$clang" | grep -q 'en-US'; then
        echo '客户端语言=ok:en-US'
    elif [[ "$syslang" == en* ]]; then
        echo '客户端语言=ok:跟随系统(英文)'
    else
        echo '客户端语言=fail:跟随系统(中文)'
    fi
    # 13. ASN 网络属性(住宅宽带 vs 机房,按目标地区收录主流运营商)
    org=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null | grep '"org"' | cut -d'"' -f4)
    case "$org" in
        '') echo 'ASN属性=warn:未获取' ;;
        *Comcast*|*AT\&T*|*Verizon*|*Spectrum*|*Charter*|*Cox*|*T-Mobile*|*Cable*|*esidential*|\
        *NTT*|*KDDI*|*SoftBank*|*IIJ*|*OCN*|*So-net*|\
        *HiNet*|*Chunghwa*|*CHT*|*kbro*|*Taiwan*|*FarEasTone*|*Data\ Communication*|\
        *Singtel*|*StarHub*|*M1*|\
        *HKT*|*PCCW*|*HKBN*|*HGC*|\
        *BT*|*Sky*|*Virgin*|*TalkTalk*|*Vodafone*|\
        *Deutsche\ Telekom*|*1\&1*|*O2*) echo "ASN属性=ok:$org" ;;
        *) echo "ASN属性=warn:疑似机房($org)" ;;
    esac
    # 14. Anthropic 生态可达性
    r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
    r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
    if [ "$r1" != "000" ] && [ "$r2" != "000" ]; then
        echo "生态可达性=ok:claude.ai:$r1 api:$r2"
    else
        echo "生态可达性=fail:claude.ai:$r1 api:$r2"
    fi
}

# 保留隐藏入口供安装器调用;现在生成全局 Script.js 并迁移旧管理块。
write_merge_rules() { clash_rules write; }

# 一键修复:按项自动修复,每步输出结果
fix() {
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        local policy_result
        if ! policy_result=$(clash_rules policy 2>&1); then
            echo "FIX:WebRTC 策略无效 ✗ $policy_result"
            return 1
        fi
        WEBRTC_POLICY="$policy_result"
    fi
    echo "FIX:开始一键修复"

    # A. 代理内核 + TUN
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if ! pgrep -f verge-mihomo >/dev/null 2>&1; then
            echo "FIX:正在启动 Clash Verge..."
            open -a "Clash Verge"
        fi
        for i in $(seq 1 40); do
            pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up && break
            sleep 1
        done
        if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            V="$CLASH_DIR/verge.yaml"
            if [ -f "$V" ] && grep -q '^enable_tun_mode: false' "$V"; then
                echo "FIX:检测到 TUN 开关被关闭,正在恢复..."
                osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
                sleep 3
                sed -i '' 's/^enable_tun_mode: false/enable_tun_mode: true/' "$V"
                open -a "Clash Verge"
                for i in $(seq 1 40); do
                    tun_up && break
                    sleep 1
                done
            fi
            if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
                echo "FIX:代理内核+TUN ✓(已恢复TUN开关)"
            else
                echo "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路)"
            fi
        fi
    else
        app=$(proxy_app_name)
        if ! proxy_alive && [ -n "$app" ]; then
            echo "FIX:正在启动 $app..."
            open -a "$app" >/dev/null 2>&1
        fi
        for i in $(seq 1 40); do
            proxy_alive && tun_up && break
            sleep 1
        done
        if proxy_alive && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            echo "FIX:代理内核/TUN ✗(请打开 $(proxy_name) 手动检查节点/线路及TUN模式)"
        fi
    fi

    # B. 时区/IPv6/DNS缓存/保镖(需管理员权限,会弹一次密码框)
    tz=$(readlink /etc/localtime 2>/dev/null)
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    adminCmds=""
    [ "$tz" != "/var/db/timezone/zoneinfo/$TZ_TARGET" ] && adminCmds="${adminCmds}/usr/sbin/systemsetup -settimezone $TZ_TARGET; "
    echo "$v6" | grep -qi 'off' || adminCmds="${adminCmds}networksetup -setv6off Wi-Fi; "
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        adminCmds="${adminCmds}cp $HOME/.local/bin/local.claude-bodyguard.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist && launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist; "
    fi
    if [ -n "$adminCmds" ]; then
        adminCmds="${adminCmds}dscacheutil -flushcache; killall -HUP mDNSResponder"
        echo "FIX:修复时区/IPv6/DNS/保镖(需要密码)..."
        if osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "一键修复需要管理员权限" with administrator privileges
ASEOF
        then
            echo "FIX:时区/IPv6/DNS/保镖 ✓"
        else
            echo "FIX:时区/IPv6/保镖 ✗(取消或失败)"
        fi
    else
        echo "FIX:时区/IPv6/保镖 无需修复 ✓"
    fi

    # B3. Claude 客户端单独设英文(用户级,无需密码;系统首选语言已是英文则跳过)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if ! defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' && [[ "$syslang" != en* ]]; then
        defaults write com.anthropic.claudefordesktop AppleLanguages -array en-US
        echo "FIX:Claude 客户端语言 → en-US ✓(重启 Claude 后生效)"
    fi

    # B4. 地区格式(用户级,无需密码)
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" != "$LOCALE_TARGET" ]; then
        defaults write -g AppleLocale "$LOCALE_TARGET"
        echo "FIX:地区格式 → $LOCALE_TARGET ✓"
    fi

    # B2. 更新全局脚本并检查运行规则;写入失败或未加载均不能报成功。全局模式下规则不适用。
    if [ "$PROXY_MODE" = "clash-verge" ] && [ "$(clash_mode)" = "global" ]; then
        echo "FIX:全局模式,置顶规则不适用(全部流量已走代理) ✓"
    elif [ "$PROXY_MODE" = "clash-verge" ]; then
        echo "FIX:写入全局扩展脚本(保留已有 main 与无关配置)..."
        local rules_result
        if ! rules_result=$(write_merge_rules 2>&1); then
            echo "FIX:置顶规则 ✗ $rules_result"
            return 1
        fi
        osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
        sleep 3
        open -a "Clash Verge"
        for i in $(seq 1 40); do tun_up && break; sleep 1; done
        local loaded=0
        for i in $(seq 1 5); do
            if rules_result=$(clash_rules verify 2>&1); then loaded=1; break; fi
            sleep 1
        done
        if [ "$loaded" -ne 1 ]; then
            echo "FIX:置顶规则 ✗ 未验证内核加载:$rules_result"
            echo "FIX:请检查全局扩展脚本是否启用、代理组是否存在，以及节点 UDP 支持"
            return 1
        fi
        echo "FIX:置顶规则 ✓ 已验证内核实际加载"
    elif ! route_ok; then
        echo "FIX:置顶规则 ✗ 请在 $(proxy_name) 中自行添加 DOMAIN-SUFFIX 置顶规则"
    fi

    # C. 复测与日常审计共用判断，空结果、非零退出及无响应不会冒充代理成功。
    local fix_failed=0
    wrip=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2)
    wr=$(webrtc_status "$wrip")
    case "$wr" in
        ok:*) echo "FIX:WebRTC ✓ ${wr#ok:}" ;;
        *) echo "FIX:WebRTC ✗ ${wr#fail:}"; fix_failed=1 ;;
    esac

    # D. 出口IP最终验证
    sleep 2
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then
        echo "FIX:出口IP ✓ ($ip/$loc)"
    else
        echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET) — 可能是节点故障,请到 $(proxy_name) 里换条线路"
    fi
    echo "FIX:修复流程结束"
    return "$fix_failed"
}

# 更换代理客户端:改写已安装脚本头部的 PROXY_MODE(用于安装后换客户端/装错客户端)
set_client() {
    mode="${1:-}"
    case "$mode" in
        clash-verge|shadowrocket|sing-box|clashx|surge|auto) ;;
        *) echo "FAIL:用法: claude-switch.sh set-client <clash-verge|shadowrocket|sing-box|clashx|surge|auto>"; return 1 ;;
    esac
    target="${CLAUDE_SWITCHER_CORE:-}"
    if [ -z "$target" ]; then
        if [ -f "$HOME/.local/bin/claude-switch.sh" ] && [ -w "$HOME/.local/bin/claude-switch.sh" ]; then
            target="$HOME/.local/bin/claude-switch.sh"
        else
            target="$0"
        fi
    fi
    [ -f "$target" ] && [ -w "$target" ] || { echo "FAIL:找不到可写的核心脚本: $target"; return 1; }
    sed -i '' "s|^PROXY_MODE=\"[^\"]*\"|PROXY_MODE=\"$mode\"|" "$target" || { echo "FAIL:写入失败"; return 1; }
    grep -q "^PROXY_MODE=\"$mode\"" "$target" || { echo "FAIL:校验失败"; return 1; }
    PROXY_MODE="$mode"
    echo "OK:代理客户端已设为 $mode"
    guard_state=$(bodyguard_status)
    case "$guard_state" in
        fail:未安装) echo "INFO:保镖尚未安装,checkdetail 会提示未安装" ;;
        fail:*) echo "WARN:保镖校验未通过(${guard_state#fail:});请重新运行安装器同步 root 守护脚本(需管理员权限),完成前不要启动 Claude" ;;
    esac
    echo "INFO:重新运行 checkdetail 生效;非 Clash 客户端请在应用内自行添加 Claude 域名置顶规则"
    return 0
}

# 地区自适应:按当前出口国家一键重设 国家/时区/地区格式(换了国家节点后运行)
set_region() {
    local geo gfile ctry ntz src nlocale rc
    gfile=$(mktemp "${TMPDIR:-/tmp}/claude-geo.XXXXXX" 2>/dev/null) || gfile=""
    GEO_DIAG_FILE="$gfile"
    geo=$(geo_lookup); rc=$?
    if [ -n "$gfile" ]; then
        GEO_DIAG=$(tr '\n' ';' < "$gfile" 2>/dev/null | sed 's/;$//')
        rm -f "$gfile"
    else
        GEO_DIAG=""
    fi
    unset GEO_DIAG_FILE
    if [ "$rc" -ne 0 ] || [ -z "$geo" ] || [ "${geo%%|*}" = "" ]; then
        echo "FAIL:所有出口探测源均失败(${GEO_DIAG:-无诊断信息})"
        echo "INFO:请确认代理已开启;若代理规则把 ipinfo/ipapi 判直连,可改为手动设置或稍后重试"
        return 1
    fi
    ctry=${geo%%|*}; geo=${geo#*|}
    ntz=${geo%%|*}; src=${geo#*|}
    if [ "$ctry" = "CN" ]; then
        echo "FAIL:出口国家为 CN(来源 $src),已中止;请先切换节点再重试"
        return 1
    fi
    [ -n "$ntz" ] || ntz=$(default_tz_for "$ctry")
    [ "$src" = "cloudflare" ] && echo "INFO:时区使用国家默认(可手动改)"
    nlocale=$(locale_for "$ctry")

    # 改写脚本自身头部三个配置项
    sed -i '' \
        -e "s|^COUNTRY_TARGET=\".*\"|COUNTRY_TARGET=\"$ctry\"|" \
        -e "s|^TZ_TARGET=\".*\"|TZ_TARGET=\"$ntz\"|" \
        -e "s|^LOCALE_TARGET=\".*\"|LOCALE_TARGET=\"$nlocale\"|" \
        "$0"
    COUNTRY_TARGET="$ctry"; TZ_TARGET="$ntz"; LOCALE_TARGET="$nlocale"

    # 地区格式(用户级,无需密码)
    defaults write -g AppleLocale "$nlocale"

    # 时区(需管理员权限,会弹一次授权框);看门狗脚本在 root 目录下,顺道用同一次授权同步目标值
    WD="/Library/Application Support/claude-switcher/tz-watchdog.sh"
    adminCmds="/usr/sbin/systemsetup -settimezone $ntz"
    wdsync=0
    if [ -f "$WD" ] && [ ! -w "$WD" ]; then
        adminCmds="$adminCmds; /usr/bin/sed -i '' 's|^TARGET=.*|TARGET=$ntz|' '$WD'"
        wdsync=1
    fi
    if ! osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "set-region 需要管理员权限以锁定时区" with administrator privileges
ASEOF
    then
        echo "FAIL:时区设置被取消或失败(国家/地区格式已更新为 $ctry/$nlocale)"
        return 1
    fi
    # 看门狗目标同步兜底(可写的老版本安装直接 sed;失败则提示运行安装器刷新)
    if [ -f "$WD" ] && [ "$wdsync" -eq 0 ]; then
        sed -i '' "s|^TARGET=.*|TARGET=$ntz|" "$WD" 2>/dev/null || echo "WARN:看门狗目标未同步,请运行安装器刷新"
    fi

    echo "OK:region=$ctry tz=$ntz locale=$nlocale source=$src"
}

# 自动更新:拉取 main 分支最新代码,SHA256 校验+配置注入+自检+失败回滚
# --check 只检查不写入;--auto 供 LaunchAgent 每12小时调用(静默写 update.log)
self_update() {
    auto=0; check=0
    case "${1:-}" in
        --auto) auto=1 ;;
        --check) check=1 ;;
    esac
    # 路径全部从脚本自身位置推导,兼容旧版 LaunchDaemon(root) 混跑时 $HOME 不可靠的场景
    BIN=$(cd "$(dirname "$0")" && pwd)
    UHOME="${BIN%/.local/bin}"
    [ "$UHOME" = "$BIN" ] && UHOME="$HOME"
    if [ "$auto" -eq 1 ]; then
        mkdir -p "$BASE"
        exec >>"$BASE/update.log" 2>&1
        echo "# $(date '+%F %T') update --auto 开始"
    fi

    tmpd=$(mktemp -d)
    if ! curl -sL --max-time 30 "https://codeload.github.com/YOURSJEYO/claude-switcher/zip/refs/heads/main" -o "$tmpd/main.zip" \
        || ! unzip -q "$tmpd/main.zip" -d "$tmpd" 2>/dev/null; then
        echo "FAIL:下载或解压失败(网络问题,稍后再试)"; rm -rf "$tmpd"; return 1
    fi
    NEW="$tmpd/claude-switcher-main"
    if [ ! -f "$NEW/core/claude-switch.sh" ]; then
        echo "FAIL:远程包结构异常,已中止"; rm -rf "$tmpd"; return 1
    fi

    # 工件完整性校验:逐项比对仓库 SHA256SUMS,任一不符即中止(防传输篡改;信任根为 GitHub 仓库本身)
    if ! curl -sL --max-time 15 "https://raw.githubusercontent.com/YOURSJEYO/claude-switcher/main/SHA256SUMS" -o "$tmpd/SHA256SUMS" \
        || [ ! -s "$tmpd/SHA256SUMS" ]; then
        echo "FAIL:无法获取校验清单(SHA256SUMS),已中止"; rm -rf "$tmpd"; return 1
    fi
    bad=0
    while read -r sum rel; do
        [ -z "$sum" ] && continue
        if [ ! -f "$NEW/$rel" ] || [ "$(shasum -a 256 "$NEW/$rel" | awk '{print $1}')" != "$sum" ]; then
            bad=1; break
        fi
    done < "$tmpd/SHA256SUMS"
    if [ "$bad" -eq 1 ]; then
        echo "FAIL:工件校验失败,已中止(不排除网络篡改,可稍后重试或手动 update)"; rm -rf "$tmpd"; return 1
    fi

    # 跳过判断:剔除头部5个配置行后与本地已安装版本比对,无差异即已是最新
    strip_cfg() { grep -vE '^(PROXY_MODE|PROXY_GROUP|COUNTRY_TARGET|TZ_TARGET|LOCALE_TARGET)="' "$1"; }
    if [ -f "$BIN/claude-switch.sh" ] && \
       diff <(strip_cfg "$BIN/claude-switch.sh") <(strip_cfg "$NEW/core/claude-switch.sh") >/dev/null 2>&1; then
        echo "OK:已是最新版本"; rm -rf "$tmpd"; return 0
    fi

    # 只读检查:不备份、不写文件、不物化守护脚本、不触发自检/回滚
    if [ "$check" -eq 1 ]; then
        stamp=$(stat -f '%Sm' -t '%Y-%m-%d' "$NEW/core/claude-switch.sh" 2>/dev/null)
        [ -z "$stamp" ] && stamp=$(date '+%F')
        echo "INFO:发现新版本 $stamp"
        rm -rf "$tmpd"; return 0
    fi

    # 备份现有核心脚本
    [ -f "$BIN/claude-switch.sh" ] && cp "$BIN/claude-switch.sh" "$BIN/claude-switch.sh.bak"

    # 替换核心脚本 + 从 .bak 读出5个配置值注入新脚本
    cp "$NEW/core/claude-switch.sh" "$BIN/claude-switch.sh"
    PM=""; PG=""; CT=""; TZV=""; LCT=""
    if [ -f "$BIN/claude-switch.sh.bak" ]; then
        get_cfg() { grep "^$1=\"" "$BIN/claude-switch.sh.bak" | head -1 | cut -d'"' -f2; }
        PM=$(get_cfg PROXY_MODE); PG=$(get_cfg PROXY_GROUP); CT=$(get_cfg COUNTRY_TARGET)
        TZV=$(get_cfg TZ_TARGET); LCT=$(get_cfg LOCALE_TARGET)
        inject_cfg() { grep -q "^$1=\"" "$BIN/claude-switch.sh.bak" && sed -i '' "s|^$1=\".*\"|$1=\"$2\"|" "$BIN/claude-switch.sh"; }
        inject_cfg PROXY_MODE "$PM"; inject_cfg PROXY_GROUP "$PG"; inject_cfg COUNTRY_TARGET "$CT"
        inject_cfg TZ_TARGET "$TZV"; inject_cfg LOCALE_TARGET "$LCT"
    fi
    chmod +x "$BIN/claude-switch.sh"

    # 守护进程脚本(root 所有,用户态不可写):与远程模板比对,有差异只提示不自动改
    APPDIR="/Library/Application Support/claude-switcher"
    if [ -f "$APPDIR/claude-bodyguard.sh" ] || [ -f "$APPDIR/tz-watchdog.sh" ]; then
        [ -z "$PM" ] && PM="clash-verge"
        [ -z "$TZV" ] && TZV="America/New_York"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__PROXY_MODE__|$PM|g" "$NEW/daemons/claude-bodyguard.sh" > "$tmpd/bg.new"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__TZ_TARGET__|$TZV|g" "$NEW/daemons/tz-watchdog.sh" > "$tmpd/tz.new"
        if ! diff -q "$tmpd/bg.new" "$APPDIR/claude-bodyguard.sh" >/dev/null 2>&1 || \
           ! diff -q "$tmpd/tz.new" "$APPDIR/tz-watchdog.sh" >/dev/null 2>&1; then
            echo "INFO:守护进程脚本有更新,请运行 installer/安装.command 刷新(需要密码)"
        fi
    fi
    rm -rf "$tmpd"

    # 更新后自检:root(旧版 LaunchDaemon)下切回真实用户执行,避免 defaults 读到 root 的配置
    if [ "$(id -u)" -eq 0 ]; then
        owner=$(stat -f '%Su' "$UHOME" 2>/dev/null)
        if [ -n "$owner" ]; then out=$(sudo -H -u "$owner" "$BIN/claude-switch.sh" checkdetail 2>&1); else out=""; fi
    else
        out=$("$BIN/claude-switch.sh" checkdetail 2>&1)
    fi
    if [ -z "$out" ] || echo "$out" | grep -q '=fail'; then
        [ -f "$BIN/claude-switch.sh.bak" ] && cp "$BIN/claude-switch.sh.bak" "$BIN/claude-switch.sh"
        echo "FAIL:新版自检未通过,已自动回滚"
        return 1
    fi
    echo "OK:更新完成 $(date '+%Y-%m-%d')"
    return 0
}

# 设备指纹体检:字体地区特征 + GPU/虚拟机特征(Canvas/WebGL 由 Web 检测页覆盖)
fingerprint() {
    echo "# 设备指纹体检 $(date '+%F %T')"
    hits=""
    for d in /Library/Fonts "$HOME/Library/Fonts"; do
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            b=$(basename "$f" | tr '[:upper:]' '[:lower:]')
            case "$b" in
                *simsun*|*simhei*|*simkai*|*simfang*|*msyh*|*msjh*|*dengxian*|*wqy*|*fzshu*|*fzkai*|*fzhei*|*fangsong*) hits="$hits $b" ;;
            esac
        done < <(find "$d" -type f \( -iname '*.ttf' -o -iname '*.ttc' -o -iname '*.otf' \) 2>/dev/null)
    done
    if [ -n "$hits" ]; then
        echo "字体=warn:检测到地区特征字体:${hits# }"
        echo "建议=上述字体通常随中文办公软件安装,美区环境很少出现;不用的可在字体册停用"
    else
        echo "字体=ok:未发现中文办公字体(仅系统自带字体)"
    fi

    gpu=$(system_profiler SPDisplaysDataType 2>/dev/null)
    chip=$(echo "$gpu" | grep -m1 'Chipset Model' | sed 's/.*: //')
    res=$(echo "$gpu" | grep -m1 'Resolution' | sed 's/.*: //')
    [ -z "$chip" ] && chip="未知"
    echo "GPU=ok:${chip}"
    echo "显示=ok:${res:-未知}"
    virt=$(sysctl -n kern.hv_vmm_present 2>/dev/null)
    case "$chip" in
        *Virtual*|*VMware*|*Parallels*|*VirtualBox*|*SwiftShader*|*llvmpipe*)
            echo "虚拟机=warn:检测到虚拟 GPU($chip),这是强指纹" ;;
        *)
            [ "$virt" = "1" ] && echo "虚拟机=warn:运行在虚拟机中" || echo "虚拟机=ok:物理机" ;;
    esac
    echo "CanvasWebGL=info:原生检查读不到 Claude Electron 的渲染特征,请打开 Web 检测页 https://yoursjeyo.github.io/claude-switcher/ 查看 Canvas/WebGL 指纹"
}

# 账号快照加密导出/导入(macOS):AES-256 加密 DMG,密码只经 stdin 传递
# 一次性隔离浏览器:独立临时 profile,禁用非代理 UDP,关闭后销毁;URL 仅允许 http/https
# Claude Code CLI 体检:只读检测安装方式/版本/多份安装冲突,不执行卸载或重装
cli_info() {
    echo "# Claude Code CLI 体检 $(date '+%F %T')"
    path=$(command -v claude 2>/dev/null)
    if [ -n "$path" ]; then
        real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || echo "$path")
        ver=$(perl -e 'alarm 4; exec @ARGV' "$real" --version 2>/dev/null | head -1)
        [ -z "$ver" ] && ver=$(perl -e 'alarm 4; exec @ARGV' "$path" --version 2>/dev/null | head -1)
        echo "CLI=ok:$path"
        [ "$real" != "$path" ] && echo "CLI真实路径=info:$real"
        echo "版本=ok:${ver:-未获取}"
        case "$real" in
            *".claude/local"*|*".local/share/claude"*) method="native(官方安装脚本)" ;;
            *"/opt/homebrew/"*|*"/usr/local/Cellar/"*|*"/home/linuxbrew/"*) method="homebrew" ;;
            *"node_modules"*|*".npm-global"*|*"/.bun/"*) method="npm/bun" ;;
            *) method="未知(建议核对 PATH)" ;;
        esac
        echo "安装方式=info:$method"
    else
        echo "CLI=warn:PATH 中没有 claude 命令"
        echo "安装方式=info:未安装(桌面版可能自带内置 CLI,见下)"
    fi

    bundled=$(ls -d "$HOME/Library/Application Support/Claude/claude-code"/* 2>/dev/null | tail -1)
    if [ -n "$bundled" ]; then
        echo "桌面版内置=ok:$(basename "$bundled")"
    else
        echo "桌面版内置=info:未发现(Claude 桌面版未安装或版本较旧)"
    fi

    if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
        echo "npm全局包=warn:检测到 @anthropic-ai/claude-code"
    else
        echo "npm全局包=ok:未检测到"
    fi
    if command -v brew >/dev/null 2>&1 && brew list --versions claude-code >/dev/null 2>&1; then
        echo "Homebrew包=warn:$(brew list --versions claude-code 2>/dev/null | head -1)"
    else
        echo "Homebrew包=ok:未检测到"
    fi

    cfg="$HOME/.claude"
    if [ -d "$cfg" ]; then
        echo "配置目录=ok:$cfg ($(du -sh "$cfg" 2>/dev/null | cut -f1))"
    else
        echo "配置目录=info:未创建(尚未运行过 CLI)"
    fi

    [ -n "$path" ] && echo "建议=info:升级用对应包管理器(brew upgrade claude-code / npm i -g @anthropic-ai/claude-code@latest);卸载前先确认桌面版是否依赖它"
    return 0
}

open_safe() {
    url="${1:-}"
    case "$url" in
        http://*|https://*) ;;
        '') echo "FAIL:用法: claude-switch.sh open-safe <http(s)://链接>"; return 1 ;;
        *) echo "FAIL:只允许 http/https 链接"; return 1 ;;
    esac
    if [ "${CLAUDE_SWITCHER_SKIP_NET_CHECK:-0}" != "1" ] && ! tun_up && ! proxy_alive; then
        echo "FAIL:代理未就绪(TUN 未接管且客户端未运行),拒绝打开以免直连"
        return 1
    fi
    chrome="${CLAUDE_SWITCHER_CHROME:-}"
    if [ -z "$chrome" ]; then
        for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                 "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                 "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
                 "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
            [ -x "$c" ] && chrome="$c" && break
        done
    fi
    [ -n "$chrome" ] && [ -x "$chrome" ] || { echo "FAIL:未找到 Chrome/Chromium/Edge/Brave"; return 1; }

    profile=$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-safe.XXXXXX") || { echo "FAIL:无法创建临时 profile"; return 1; }
    chmod 700 "$profile"
    lang="${LOCALE_TARGET:-en_US}"; lang="${lang/_/-}"
    nohup "$chrome" \
        --user-data-dir="$profile" \
        --no-first-run --no-default-browser-check \
        --disable-sync --disable-extensions \
        --force-webrtc-ip-handling-policy=disable_non_proxied_udp \
        --lang="$lang" \
        "$url" >/dev/null 2>&1 &
    pid=$!
    nohup bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 5; done; rm -rf "$2"' _ "$pid" "$profile" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo "OK:已在一次性隔离浏览器打开(profile 将在窗口关闭后销毁)"
    echo "INFO:该窗口不继承你日常浏览器的 cookies/插件;在其中登录产生的会话会随窗口关闭一并丢弃"
}

snapshot_export() {
    target="${1:-}"; out="${2:-}"; mode="${3:-}"
    case "$target" in A|B|C|D) ;; *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;; esac
    [ -d "$BASE/accounts/$target" ] || { echo "FAIL:账号$target 没有已归档快照(先切换一次让它归档)"; return 1; }
    [ -n "$out" ] || { echo "FAIL:请指定导出文件路径"; return 1; }
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    [ -e "$out" ] && { echo "FAIL:目标文件已存在,请换一个路径"; return 1; }
    if [ "$(cat "$BASE/current" 2>/dev/null)" = "$target" ]; then
        echo "FAIL:账号$target 正在使用中,当前数据在运行目录;请先切换到另一账号(会自动归档)再导出"
        return 1
    fi

    if [ "$mode" = "--password-stdin" ]; then
        IFS= read -r pass || true
    else
        printf '设置导出密码(至少 8 位): '; stty -echo 2>/dev/null; IFS= read -r pass; stty echo 2>/dev/null; echo
        printf '再次输入: '; stty -echo 2>/dev/null; IFS= read -r pass2; stty echo 2>/dev/null; echo
        [ "$pass" = "$pass2" ] || { echo "FAIL:两次密码不一致"; return 1; }
    fi
    if [ ${#pass} -lt 8 ]; then
        unset pass pass2
        echo "FAIL:密码至少 8 位"; return 1
    fi

    stage=$(mktemp -d)
    if ! ditto "$BASE/accounts/$target/" "$stage/"; then
        rm -rf "$stage"; unset pass pass2
        echo "FAIL:复制快照失败"; return 1
    fi
    cat > "$stage/.claude-switcher-snapshot.json" <<EOF
{"format":"claude-switcher-snapshot","version":1,"account":"$target","created":"$(date '+%F %T')"}
EOF
    if ! printf '%s\n' "$pass" | hdiutil create -srcfolder "$stage" -volname "ClaudeSnapshot-$target" \
        -encryption AES-256 -stdinpass "$out" >/dev/null 2>&1; then
        rm -rf "$stage"; rm -f "$out"; unset pass pass2
        echo "FAIL:创建加密镜像失败"; return 1
    fi
    rm -rf "$stage"
    # 加密镜像校验必须带密码,否则 macOS 会弹出图形密码框
    if ! printf '%s\n' "$pass" | hdiutil verify -stdinpass "$out" >/dev/null 2>&1; then
        rm -f "$out"; unset pass pass2
        echo "FAIL:镜像校验失败"; return 1
    fi
    unset pass pass2
    chmod 600 "$out"
    echo "OK:账号$target 已加密导出到 $out"
}

snapshot_import() {
    file="${1:-}"; target="${2:-}"; mode="${3:-}"
    case "$target" in A|B|C|D) ;; *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;; esac
    [ -f "$file" ] || { echo "FAIL:找不到镜像文件: $file"; return 1; }
    [ -e "$BASE/accounts/$target" ] && { echo "FAIL:账号$target 已有快照,请先导出或删除后再导入"; return 1; }

    if [ "$mode" = "--password-stdin" ]; then
        IFS= read -r pass || true
    else
        printf '输入镜像密码: '; stty -echo 2>/dev/null; IFS= read -r pass; stty echo 2>/dev/null; echo
    fi
    [ -n "$pass" ] || { echo "FAIL:密码为空"; return 1; }

    mnt=$(mktemp -d)
    attached=0
    if ! printf '%s\n' "$pass" | hdiutil attach -stdinpass -nobrowse -readonly -mountpoint "$mnt" "$file" >/dev/null 2>&1; then
        unset pass; rm -rf "$mnt"
        echo "FAIL:密码错误或镜像损坏"; return 1
    fi
    attached=1
    unset pass

    cleanup_import() {
        [ "$attached" = "1" ] && hdiutil detach "$mnt" >/dev/null 2>&1
        rm -rf "$mnt" "$BASE/accounts/$target.new"
    }

    marker="$mnt/.claude-switcher-snapshot.json"
    if [ ! -f "$marker" ]; then
        cleanup_import
        echo "FAIL:不是本项目导出的快照镜像"; return 1
    fi
    if ! python3 - "$marker" "$target" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: meta = json.load(f)
assert meta.get("format") == "claude-switcher-snapshot"
assert meta.get("version") == 1
assert meta.get("account") in ("A", "B", "C", "D")
sys.exit(0 if meta.get("account") == sys.argv[2] else 1)
PY
    then
        cleanup_import
        echo "FAIL:镜像元数据校验失败(账号不匹配或格式不支持)"; return 1
    fi

    rm -rf "$BASE/accounts/$target.new"
    if ! ditto "$mnt" "$BASE/accounts/$target.new"; then
        cleanup_import
        echo "FAIL:复制到账号目录失败"; return 1
    fi
    rm -f "$BASE/accounts/$target.new/.claude-switcher-snapshot.json"
    chmod 700 "$BASE/accounts/$target.new"
    if ! mv "$BASE/accounts/$target.new" "$BASE/accounts/$target"; then
        cleanup_import
        echo "FAIL:写入账号目录失败"; return 1
    fi
    cleanup_import
    echo "OK:已导入为账号$target(切换时生效)"
}

status() {
    local cur="none" hasA=0 hasB=0 hasC=0 hasD=0 a dir size stamp accounts="" extras=""
    [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    [ -d "$BASE/accounts/A" ] && hasA=1
    [ -d "$BASE/accounts/B" ] && hasB=1
    [ -d "$BASE/accounts/C" ] && hasC=1
    [ -d "$BASE/accounts/D" ] && hasD=1
    for a in A B C D; do
        dir="$BASE/accounts/$a"
        [ -d "$dir" ] || continue
        accounts="${accounts:+$accounts,}$a"
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        stamp=$(date -r "$dir" '+%Y-%m-%d' 2>/dev/null)
        extras="$extras acc$a=${size:-?}@${stamp:-?}"
    done
    echo "current=$cur hasA=$hasA hasB=$hasB hasC=$hasC hasD=$hasD accounts=${accounts:-none}$extras"
}

quit_claude() {
    pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
    osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

archive_current() {
    local cur="$1"
    local t0 staged current previous moved=0 had_old=0
    t0=$(date +%s)
    staged="$BASE/accounts/$cur.new"
    current="$BASE/accounts/$cur"
    previous="$BASE/accounts/$cur.previous"

    # An interrupted archive may be the only remaining copy. Never clear it
    # automatically, or delete the previous snapshot before the new one commits.
    if [ -e "$staged" ] || [ -L "$staged" ] || [ -e "$previous" ] || [ -L "$previous" ]; then
        log "FAIL:账号$cur 存在待恢复快照，拒绝覆盖"
        return 1
    fi
    if mv "$DATA" "$staged" 2>/dev/null; then
        moved=1
    else
        # A cross-volume move may leave a partial destination on failure.
        if [ -e "$staged" ] || [ -L "$staged" ]; then
            log "FAIL:账号$cur 归档移动不完整，保留现场"
            return 1
        fi
        if ! copy_tree "$DATA" "$staged"; then
            log "FAIL:账号$cur 归档复制失败，保留现场"
            return 1
        fi
    fi

    if [ -e "$current" ] || [ -L "$current" ]; then
        if ! mv "$current" "$previous"; then
            if [ "$moved" -eq 1 ]; then
                mv "$staged" "$DATA" || log "WARN:账号$cur 数据保留在暂存位置"
            fi
            log "FAIL:账号$cur 旧快照无法安全转存"
            return 1
        fi
        had_old=1
    fi
    if ! mv "$staged" "$current"; then
        if [ "$had_old" -eq 1 ]; then
            mv "$previous" "$current" || log "WARN:账号$cur 旧快照保留在恢复位置"
        fi
        if [ "$moved" -eq 1 ]; then
            mv "$staged" "$DATA" || log "WARN:账号$cur 当前数据保留在暂存位置"
        fi
        log "FAIL:账号$cur 归档提交失败"
        return 1
    fi
    if [ "$had_old" -eq 1 ]; then
        rm -rf "$previous" || log "WARN:账号$cur 旧快照副本需手动清理"
    fi
    log "已存档账号$cur ($(( $(date +%s) - t0 ))s)"
}

# 快照复制:APFS 上用 clonefile(COW) 近乎瞬时,不改写已有快照;不支持时回退 ditto 全量复制
copy_tree() {
    src="$1"; dst="$2"
    if [ "${CLAUDE_SWITCHER_NO_CLONE:-0}" != "1" ] && cp -cRp "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -rf "$dst"
    ditto "$src" "$dst"
}

# 只接受 A-D 四个账号槽位
valid_account() {
    case "${1:-}" in
        A|B|C|D) return 0 ;;
        *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;;
    esac
}

# ---------- 跨身份保留(可选) ----------
# 校验相对路径的每个分量都不是符号链接,避免把 DATA 外的内容带进快照
keep_path_safe() {
    local rel="$1" prefix="$DATA" part
    while [ -n "$rel" ]; do
        part="${rel%%/*}"
        if [ "$part" = "$rel" ]; then rel=""; else rel="${rel#*/}"; fi
        [ -z "$part" ] && continue
        prefix="$prefix/$part"
        [ -L "$prefix" ] && return 1
    done
    return 0
}

# 归档当前账号之前,把 keep 列表里存在的路径收进暂存目录
stage_keep_paths() {
    local keepf="$BASE/keep-in-workspace.txt"
    local stage="$BASE/keep-stage"
    local rel src dst count=0
    KEEP_STAGED=0
    [ -f "$keepf" ] || return 0
    # 上次还原失败时 stage 可能是唯一完整副本,不自动覆盖
    if [ -e "$stage" ] || [ -L "$stage" ]; then
        log "FAIL:跨身份保留暂存目录已存在，请检查或重试上次切换: $stage"
        return 1
    fi
    while IFS= read -r rel || [ -n "$rel" ]; do
        rel="${rel%$'\r'}"
        case "$rel" in
            ''|'#'*|[[:space:]]*'#'*) continue ;;
            /*) log "WARN:keep 路径必须是相对路径，已跳过: $rel"; continue ;;
            *..*) log "WARN:keep 路径不能包含 ..，已跳过: $rel"; continue ;;
        esac
        while [ "${rel%/}" != "$rel" ]; do rel="${rel%/}"; done
        while [ "${rel#./}" != "$rel" ]; do rel="${rel#./}"; done
        if [ -z "$rel" ] || [ "$rel" = "." ]; then
            log "WARN:keep 路径为空或指向数据目录本身，已跳过: $rel"
            continue
        fi
        if ! keep_path_safe "$rel"; then
            log "WARN:keep 路径含符号链接，已跳过: $rel"
            continue
        fi
        src="$DATA/$rel"
        [ -e "$src" ] || continue
        dst="$stage/$rel"
        if ! mkdir -p "$(dirname "$dst")" || ! ditto "$src" "$dst"; then
            rm -rf "$stage"
            log "FAIL:跨身份保留暂存失败"
            return 1
        fi
        count=$((count + 1))
    done < "$keepf"
    if [ "$count" -eq 0 ]; then
        rm -rf "$stage"
        log "跨身份保留:没有需要保留的路径"
        return 0
    fi
    KEEP_STAGED=$count
    log "跨身份保留:已收起 $count 条路径"
    return 0
}

# 还原目标账号后,把暂存内容合并回 DATA;失败时保留 stage 供排查
restore_keep_paths() {
    local stage="$BASE/keep-stage"
    [ -d "$stage" ] || return 0
    if ! ditto "$stage/" "$DATA/"; then
        log "FAIL:跨身份保留还原失败，暂存保留在 $stage"
        return 1
    fi
    rm -rf "$stage"
    log "跨身份保留:已还原 ${KEEP_STAGED:-0} 条路径到新账号"
    return 0
}

switch_to() {
    target="${1:-}"
    valid_account "$target" || return 1
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    just_archived=0

    # 首次运行:把当前登录中的状态收编为账号A
    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }
        if [ -s "$BASE/keep-in-workspace.txt" ]; then
            stage_keep_paths || { echo "FAIL:跨身份保留暂存失败，已停止切换"; return 1; }
        fi
        archive_current A || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:首次账号归档失败，已停止切换"; return 1
        }
        just_archived=1
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前登录状态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        # 归档是移动语义;首次收编或上次切换中断后,先用存档恢复 DATA
        if [ ! -d "$DATA" ]; then
            if [ ! -d "$BASE/accounts/$target" ]; then
                echo "FAIL:账号$target 数据目录缺失，已停止切换"; return 1
            fi
            if ! copy_tree "$BASE/accounts/$target" "$DATA"; then
                echo "FAIL:账号$target 还原失败，已停止切换"; return 1
            fi
        fi
        # 上次还原失败留下的 stage,在当前账号上重试合并
        if [ -d "$BASE/keep-stage" ]; then
            restore_keep_paths || { echo "FAIL:跨身份保留还原失败，暂存保留在 $BASE/keep-stage"; return 1; }
        fi
        open -a "Claude"
        echo "INFO:当前已是账号$target"
        return 0
    fi

    quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }

    if [ "$just_archived" = "0" ] && [ "$cur" != "none" ] && [ -d "$DATA" ]; then
        if [ -s "$BASE/keep-in-workspace.txt" ]; then
            stage_keep_paths || { echo "FAIL:跨身份保留暂存失败，已停止切换"; return 1; }
        fi
        archive_current "$cur" || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:账号$cur 归档失败，已停止切换"; return 1
        }
    fi

    rm -rf "$DATA.new"
    t0=$(date +%s)
    if [ -d "$BASE/accounts/$target" ]; then
        if ! copy_tree "$BASE/accounts/$target" "$DATA.new"; then
            log "FAIL:账号$target 存档载入失败"
            echo "FAIL:账号$target 存档载入失败，暂存保留在 $BASE/keep-stage"
            return 1
        fi
        log "已载入账号$target 存档 ($(( $(date +%s) - t0 ))s)"
    else
        if ! mkdir -p "$DATA.new"; then
            log "FAIL:无法创建账号$target 数据目录"
            echo "FAIL:无法创建账号$target 数据目录"
            return 1
        fi
        log "账号$target 无存档，将以全新状态初始化"
    fi
    if ! { rm -rf "$DATA" && mv "$DATA.new" "$DATA"; }; then
        log "FAIL:载入账号$target 失败"
        echo "FAIL:载入账号$target 失败，暂存保留在 $BASE/keep-stage"
        return 1
    fi
    echo "$target" > "$BASE/current"

    if [ -d "$BASE/keep-stage" ]; then
        if ! restore_keep_paths; then
            echo "FAIL:跨身份保留还原失败，暂存保留在 $BASE/keep-stage"
            return 1
        fi
    fi

    open -a "Claude"
    log "已切换到账号$target 并启动 ($(( $(date +%s) - t0 ))s)"
    echo "OK:已切换到账号$target ($(( $(date +%s) - t0 ))s)"
    return 0
}

case "${1:-}" in
    check)  check ;;
    checkdetail)
        OUT_FILE="$BASE/last-check.txt"
        {
            echo "# $(date '+%F %T') pid=$$ 开始"
            checkdetail
            echo "# 结束"
        } > "$OUT_FILE" 2>&1
        cat "$OUT_FILE"
        ;;
    fix) fix ;;
    status) status ;;
    switch) switch_to "${2:-}" ;;
    set-region) set_region ;;
    set-client) set_client "${2:-}" ;;
    update) self_update "${2:-}" ;;
    update-check) self_update --check ;;  # 只读检查;独立入口,避免旧版核心把 --check 当成真实更新
    open-safe) open_safe "${2:-}" ;;
    cli-info) cli_info ;;
    snapshot-export) snapshot_export "${2:-}" "${3:-}" "${4:-}" ;;
    snapshot-import) snapshot_import "${2:-}" "${3:-}" "${4:-}" ;;
    write-merge-rules) write_merge_rules ;;  # 隐藏入口:供安装器调用,保证两处合并逻辑一致
    fingerprint) fingerprint ;;
    *) echo "用法: claude-switch.sh check|checkdetail|fix|status|switch A|B|C|D|set-region|set-client <mode>|update [--check|--auto]|update-check|fingerprint|snapshot-export <A|B|C|D> <file>|snapshot-import <file> <A|B|C|D>|open-safe <url>|cli-info|diagnose-proxy [--proxy URL|--config FILE]"; exit 2 ;;
esac
