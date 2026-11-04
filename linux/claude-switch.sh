#!/bin/bash
# Claude 账号切换器 - Linux 核心脚本
# 用法: claude-switch.sh checkdetail|status|fix|switch A|B|menu  (隐藏: write-merge-rules 供安装器调用)
set -u
export LC_ALL=en_US.UTF-8

# ============ 安装时可配置项(安装器自动改写) ============
PROXY_MODE="clash-verge"       # 代理客户端: clash-verge|mihomo|sing-box|v2raya|nekobox|hiddify|wireguard|other|auto
PROXY_GROUP="GLOBAL"           # Clash 代理组名(安装时自动探测)
COUNTRY_TARGET="US"            # 目标出口国家(安装时按出口自动识别)
TZ_TARGET="America/New_York"   # 锁定时区,应与出口IP所在国家一致
LOCALE_TARGET="en_US"          # 锁定地区格式
# =======================================================

umask 077
BASE="$HOME/.claude-switcher"
PROBE="$BASE/stun-probe.py"
if [ "${1:-}" = monitor-check ] && [ ! -f "$BASE/claude-switch.sh" ]; then
    BASE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-switcher-monitor"
    PROBE="$(dirname "$0")/stun-probe.py"
    PROXY_MODE="auto"
fi
DATA="$HOME/.config/google-chrome"   # Web 版登录态目录(Chrome)
[ -d "$HOME/.config/chromium" ] && [ ! -d "$DATA" ] && DATA="$HOME/.config/chromium"
LOG="$BASE/claude-switch.log"
CLASH_DIR="$HOME/.config/io.github.clash-verge-rev.clash-verge-rev"
[ -d "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" ] && CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
# Clash Verge Rev on Linux stores runtime profiles under XDG_DATA_HOME.
data_clash="${XDG_DATA_HOME:-$HOME/.local/share}/io.github.clash-verge-rev.clash-verge-rev"
if [ ! -f "$CLASH_DIR/clash-verge.yaml" ] && [ -f "$data_clash/clash-verge.yaml" ]; then
    CLASH_DIR="$data_clash"
fi
ROUTE_MISSED=""
mkdir -p "$BASE/accounts"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

# TUN 在线判定:存在 fake-ip 网段地址即视为 TUN 已接管(兼容各种 TUN 设备名)
tun_up() { ip addr 2>/dev/null | grep -q 'inet 198\.18\.'; }

# 通用虚拟网卡兜底:tun/utun/wg/tailscale 接口存在且 UP(WireGuard 等无 fake-ip 网段的场景)
tun_any() { ip link show 2>/dev/null | grep -E '^[0-9]+: (tun|utun|wg|tailscale)[0-9]*:' | grep -q 'UP'; }

# 代理链路在线:fake-ip 或任一通用虚拟网卡
net_up() { tun_up || tun_any; }

# 代理客户端显示名(供检查细节输出)
proxy_name() {
    case "$PROXY_MODE" in
        clash-verge) echo "Clash Verge" ;;
        mihomo)      echo "mihomo" ;;
        sing-box)    echo "sing-box" ;;
        v2raya)      echo "V2RayA" ;;
        nekobox)     echo "NekoBox" ;;
        hiddify)     echo "Hiddify" ;;
        wireguard)   echo "WireGuard" ;;
        other)       echo "其他代理" ;;
        auto)        echo "代理客户端" ;;
        *)           echo "$PROXY_MODE" ;;
    esac
}

# WireGuard 在线判定:存在活动的 wg-quick@ 服务(通配符加引号,交给 systemctl 自己展开)
wg_up() { systemctl list-units --type=service --state=active 'wg-quick@*' 2>/dev/null | grep -q 'wg-quick@'; }

# 代理内核在线判定:按安装时识别的客户端分派;other 看虚拟网卡,auto 任一命中即活
proxy_alive() {
    case "$PROXY_MODE" in
        clash-verge) pgrep -f 'verge-mihomo|mihomo' >/dev/null 2>&1 ;;
        mihomo)      pgrep -f mihomo >/dev/null 2>&1 ;;
        sing-box)    pgrep -f sing-box >/dev/null 2>&1 ;;
        v2raya)      pgrep -f v2raya >/dev/null 2>&1 ;;
        nekobox)     pgrep -f 'nekobox|nekoray' >/dev/null 2>&1 ;;
        hiddify)     pgrep -f hiddify >/dev/null 2>&1 ;;
        wireguard)   wg_up ;;
        other)       net_up ;;
        auto)        pgrep -f 'verge-mihomo|mihomo' >/dev/null 2>&1 \
                     || pgrep -f sing-box >/dev/null 2>&1 \
                     || pgrep -f v2raya >/dev/null 2>&1 \
                     || pgrep -f 'nekobox|nekoray' >/dev/null 2>&1 \
                     || pgrep -f hiddify >/dev/null 2>&1 \
                     || wg_up ;;
        *)           pgrep -f 'verge-mihomo|mihomo' >/dev/null 2>&1 ;;
    esac
}

dns_query() {
    # dig → nslookup → getent 逐级回退
    if command -v dig >/dev/null 2>&1; then dig +short +time=3 +tries=1 "$1" 2>/dev/null | head -1
    elif command -v nslookup >/dev/null 2>&1; then nslookup -timeout=3 "$1" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1
    else getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; fi
}

egress() {
    local t
    t=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    echo "$(echo "$t" | grep '^ip=' | cut -d= -f2) $(echo "$t" | grep '^loc=' | cut -d= -f2)"
}

webrtc_test() { python3 "$PROBE" 2>/dev/null; }

# 与 macOS 使用同一个规则管理入口，直接查询当前内核。
clash_rules() {
    local script_dir helper
    script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    helper="$script_dir/clash-support.sh"
    [ -f "$helper" ] || helper="$script_dir/../core/claude-switch.sh"
    [ -f "$helper" ] || { echo "缺少 Clash 规则组件，请重新安装" >&2; return 1; }
    bash "$helper" clash-rules "$1" "$CLASH_DIR" "$BASE" "$PROXY_GROUP" "${WEBRTC_POLICY:-}"
}

merge_ok() { clash_rules verify >/dev/null 2>&1; }

# 置顶规则行为检测:三个生态域名全部解析到 fake-ip 段(198.18.x.x)即视为已置顶;未命中域名记入 ROUTE_MISSED
route_ok() {
    ROUTE_MISSED=""
    local d a
    for d in claude.ai api.anthropic.com claudeusercontent.com; do
        a=$(dns_query "$d")
        case "$a" in
            198.18.*) ;;
            *) ROUTE_MISSED="$ROUTE_MISSED $d" ;;
        esac
    done
    [ -z "$ROUTE_MISSED" ]
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

# 逐项输出检查结果: 名称=ok|warn|fail:细节
checkdetail() {
    # 1. 代理内核(按安装时识别的客户端判定)
    if proxy_alive; then
        echo "代理内核=ok:$(proxy_name) 运行中"
    else
        echo "代理内核=fail:$(proxy_name) 未运行"
    fi
    # 2. TUN 网卡(fake-ip 段优先,通用虚拟网卡兜底)
    if tun_up; then
        echo 'TUN网卡=ok'
    elif tun_any; then
        echo 'TUN网卡=ok:通用虚拟网卡'
    else
        echo 'TUN网卡=fail:不在线'
    fi

    read -r ip loc <<< "$(egress)"
    # 3. 出口IP(按安装时锁定的目标国家)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then echo "出口IP=ok:$ip/$loc"; else echo "出口IP=fail:${ip:-无}/${loc:-未知}(期望$COUNTRY_TARGET)"; fi
    # 4. IP 一致(含 48h 审查)
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

    # 5. 时区
    tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [ "$tz" = "$TZ_TARGET" ] && echo '时区=ok' || echo "时区=fail:$tz"

    # 6. 地区(LANG 未设时回退 localectl)
    lang="${LANG:-$(localectl status 2>/dev/null | grep 'LANG=' | head -1 | cut -d= -f2)}"
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] && command -v gsettings >/dev/null; then
        region=$(gsettings get org.gnome.system.locale region 2>/dev/null | tr -d "'")
        [ -z "$region" ] || lang="$region"
    fi
    case "$lang" in ${LOCALE_TARGET}*) echo '地区=ok' ;; *) echo "地区=fail:$lang(期望$LOCALE_TARGET)" ;; esac

    # 7. IPv6
    v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    [ "$v6" = "1" ] && echo 'IPv6=ok:已关闭' || echo 'IPv6=fail:未关闭'

    # 8. DNS
    dnsip=$(dns_query claude.ai)
    case "$dnsip" in 198.18.*) echo 'DNS=ok:走隧道' ;; *) echo "DNS=fail:未走隧道(${dnsip:-空})" ;; esac

    # 9. WebRTC
    wr=$(webrtc_test)
    case "$wr" in
        RESULT:NONE) echo 'WebRTC=fail:STUN 未返回结果，无法验证' ;;
        RESULT:*)
            wips=${wr#RESULT:}; leak=""
            OLDIFS=$IFS; IFS=','
            for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
            IFS=$OLDIFS
            [ -n "$leak" ] && echo "WebRTC=fail:暴露非代理IP:$leak" || echo 'WebRTC=ok:仅暴露代理IP' ;;
        *) echo 'WebRTC=fail:检测异常' ;;
    esac

    # 10. 保镖
    if systemctl --user is-active claude-bodyguard.service >/dev/null 2>&1; then
        lastkill=$(tail -1 "$BASE/bodyguard.log" 2>/dev/null | cut -c1-40)
        echo "保镖=ok:${lastkill:-待命}"
    else
        echo '保镖=fail:未运行'
    fi

    # 11. 规则置顶:Clash Verge 配置/行为双保险,其他客户端只看行为
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if merge_ok; then
            echo '规则置顶=ok'
        else
            echo '规则置顶=fail:运行中的内核规则未通过验证'
        fi
    else
        if route_ok; then
            echo '规则置顶=ok:行为检测通过'
        else
            echo "规则置顶=fail:未命中(${ROUTE_MISSED# }),请在 $(proxy_name) 中自行加置顶规则"
        fi
    fi

    # 12. 客户端语言
    echo '客户端语言=ok:跟随系统'

    # 13. ASN 网络属性(住宅宽带 vs 机房)
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

write_merge_rules() { clash_rules write; }

fix() {
    echo "FIX:开始一键修复"

    # A. 代理内核 + TUN(仅 Clash Verge 代为启动,其他客户端只提示手动)
    if ! proxy_alive; then
        if [ "$PROXY_MODE" = "clash-verge" ]; then
            echo "FIX:正在尝试启动 Clash Verge..."
            (clash-verge >/dev/null 2>&1 &) || (clash-verge-rev >/dev/null 2>&1 &) || echo "FIX:未找到启动命令,请手动启动 Clash Verge"
        else
            echo "FIX:请手动启动 $(proxy_name)(各客户端启动方式不同,不代为执行)"
        fi
    fi
    for i in $(seq 1 40); do
        proxy_alive && net_up && break
        sleep 1
    done
    if proxy_alive && net_up; then
        echo "FIX:代理内核+TUN ✓"
    else
        echo "FIX:代理内核/TUN ✗(请检查 $(proxy_name) 的 TUN 开关与节点)"
    fi

    # B. 时区/IPv6/DNS(sudo)
    adminCmds=""
    tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [ "$tz" != "$TZ_TARGET" ] && adminCmds="${adminCmds}timedatectl set-timezone $TZ_TARGET; "
    [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" != "1" ] && adminCmds="${adminCmds}sysctl -w net.ipv6.conf.all.disable_ipv6=1; "
    if [ -n "$adminCmds" ]; then
        echo "FIX:修复时区/IPv6(需要 sudo 密码)..."
        sudo bash -c "$adminCmds" && echo "FIX:时区/IPv6 ✓" || echo "FIX:时区/IPv6 ✗"
    else
        echo "FIX:时区/IPv6 无需修复 ✓"
    fi
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null
    command -v systemd-resolve >/dev/null 2>&1 && systemd-resolve --flush-caches 2>/dev/null

    # C. 保镖(systemd user 服务,免 sudo)
    if ! systemctl --user is-active claude-bodyguard.service >/dev/null 2>&1; then
        echo "FIX:注册并启动保镖服务..."
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/claude-bodyguard.service" <<EOF
[Unit]
Description=Claude Bodyguard (kill claude CLI when proxy down)

[Service]
ExecStart=/bin/bash $BASE/claude-bodyguard.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now claude-bodyguard.service >/dev/null 2>&1 \
            && echo "FIX:保镖 ✓" || echo "FIX:保镖 ✗"
    fi

    # D. 置顶规则(仅 Clash Verge 智能合并写入;其他客户端行为检测不通过时提示手动)
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if ! merge_ok; then
            echo "FIX:写入置顶规则(智能合并,不动你的已有配置)..."
            write_merge_rules && echo "FIX:置顶规则已写入(请重启 Clash Verge 生效)" || echo "FIX:置顶规则 ✗(写入失败)"
        fi
    else
        if ! route_ok; then
            echo "FIX:置顶规则 ✗(未命中:${ROUTE_MISSED# }) — 请在 $(proxy_name) 中自行添加 DOMAIN-SUFFIX 置顶规则"
        fi
    fi

    # E. 出口IP最终验证
    sleep 2
    read -r ip loc <<< "$(egress)"
    if [ "$loc" = "$COUNTRY_TARGET" ]; then
        echo "FIX:出口IP ✓ ($ip/$loc)"
    else
        echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET) — 请换节点/线路"
    fi
    echo "FIX:修复流程结束"
}

status() {
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    hasA=0; [ -d "$BASE/accounts/A" ] && hasA=1
    hasB=0; [ -d "$BASE/accounts/B" ] && hasB=1
    echo "current=$cur hasA=$hasA hasB=$hasB"
}

quit_browser() {
    pgrep -f 'chrome|chromium' >/dev/null 2>&1 || return 0
    pkill -f "$DATA" 2>/dev/null
    for i in $(seq 1 15); do
        pgrep -f "$DATA" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

archive_current() {
    cur="$1"
    t0=$(date +%s)
    # 归档=整体移走(同卷瞬时),跨卷 mv 自动退化为复制
    rm -rf "$BASE/accounts/$cur.new"
    if mv "$DATA" "$BASE/accounts/$cur.new" 2>/dev/null; then
        rm -rf "$BASE/accounts/$cur"
        mv "$BASE/accounts/$cur.new" "$BASE/accounts/$cur"
    else
        rm -rf "$BASE/accounts/$cur.tmp"
        copy_tree "$DATA" "$BASE/accounts/$cur.tmp" && rm -rf "$BASE/accounts/$cur" && mv "$BASE/accounts/$cur.tmp" "$BASE/accounts/$cur"
    fi
    log "已存档账号$cur(浏览器登录态) ($(( $(date +%s) - t0 ))s)"
}

# 快照复制:btrfs/XFS 等支持 reflink 的文件系统上走 COW 秒级复制,其余回退普通全量复制
copy_tree() {
    src="$1"; dst="$2"
    if [ "${CLAUDE_SWITCHER_NO_CLONE:-0}" != "1" ] && cp -a --reflink=auto "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -rf "$dst"
    cp -a "$src" "$dst"
}

switch_to() {
    target="$1"
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    just_archived=0

    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        quit_browser || { echo "FAIL:浏览器未能退出,请手动关闭后重试"; return 1; }
        archive_current A
        just_archived=1
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前浏览器登录态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        if [ "$just_archived" = "1" ] && [ ! -d "$DATA" ] && [ -d "$BASE/accounts/$target" ]; then
            copy_tree "$BASE/accounts/$target" "$DATA"
        fi
        echo "INFO:当前已是账号$target"
        return 0
    fi

    quit_browser || { echo "FAIL:浏览器未能退出,请手动关闭后重试"; return 1; }
    [ "$just_archived" = "0" ] && [ "$cur" != "none" ] && [ -d "$DATA" ] && archive_current "$cur"

    rm -rf "$DATA.new"
    t0=$(date +%s)
    if [ -d "$BASE/accounts/$target" ]; then
        copy_tree "$BASE/accounts/$target" "$DATA.new"
        log "已载入账号$target 存档 ($(( $(date +%s) - t0 ))s)"
    else
        mkdir -p "$DATA.new"
        log "账号$target 无存档,将以全新状态初始化"
    fi
    rm -rf "$DATA" && mv "$DATA.new" "$DATA"
    echo "$target" > "$BASE/current"
    log "已切换到账号$target ($(( $(date +%s) - t0 ))s)"
    echo "OK:已切换到账号$target(请重新打开浏览器, 耗时$(( $(date +%s) - t0 ))s)"
}

desktop_info() {
    local PRETTY_NAME=Linux
    [ ! -r /etc/os-release ] || . /etc/os-release
    echo "Claude 切换器 · Linux Desktop Beta（基于 v1.8.0，187a8d6）"
    echo "系统: ${PRETTY_NAME} ($(uname -m))"
    if command -v claude-desktop >/dev/null; then
        echo "Claude Code 桌面客户端: $(command -v claude-desktop)"
    else
        echo "Claude Code 桌面客户端: 未找到 claude-desktop"
    fi
}

desktop_open() (
    local slot="${1:-A}" report name
    case "$slot" in A|B) ;; *) echo "桌面槽位必须是 A 或 B"; return 2 ;; esac
    command -v claude-desktop >/dev/null || { echo "请先安装带有 Code 入口的 claude-desktop"; return 1; }
    exec 9>"$BASE/desktop.lock" || return 1
    flock -n 9 || { echo "桌面启动正在进行，请先退出已有会话"; return 1; }
    if pgrep -u "$(id -u)" -x claude-desktop >/dev/null; then
        echo "请先完全退出 Claude 桌面客户端，再选择槽位"
        return 1
    fi
    report=$(checkdetail) || return 1
    printf '%s\n' "$report"
    for name in 代理内核 TUN网卡 出口IP IP一致 时区 地区 IPv6 DNS WebRTC 保镖 规则置顶 客户端语言 ASN属性 生态可达性; do
        grep -Eq "^${name}=(ok|warn)(:|$)" <<< "$report" || { echo "启动已阻止：$name 未通过"; return 1; }
    done
    if [ "$slot" = B ]; then
        umask 077
        export CLAUDE_CONFIG_DIR="$BASE/desktop/B/code"
        export XDG_CONFIG_HOME="$BASE/desktop/B/config"
        mkdir -p "$CLAUDE_CONFIG_DIR" "$XDG_CONFIG_HOME" || return 1
        set -- "--user-data-dir=$BASE/desktop/B/profile"
    else
        set --
    fi
    claude-desktop "$@" 'claude://code/new?source=desktop_action'
)

menu() {
    while true; do
        clear
        echo "=============================="
        echo "  Claude 账号切换器 (Linux)"
        echo "=============================="
        echo ""
        desktop_info
        echo "  1) 安全检查 (checkdetail)"
        echo "  2) 一键修复 (fix)"
        echo "  3) 切换到账号 A"
        echo "  4) 切换到账号 B"
        echo "  5) 查看状态 (status)"
        echo "  6) 打开 Claude Code 桌面版 (A，现有配置)"
        echo "  7) 打开 Claude Code 桌面版 (B，独立配置)"
        echo "  0) 退出"
        echo ""
        read -r -p "选择: " c || return
        case "$c" in
            1) checkdetail; read -r -p "回车继续..." _ ;;
            2) fix; read -r -p "回车继续..." _ ;;
            3) switch_to A; read -r -p "回车继续..." _ ;;
            4) switch_to B; read -r -p "回车继续..." _ ;;
            5) status; read -r -p "回车继续..." _ ;;
            6|7) if [ "$c" = 6 ]; then desktop_open A; else desktop_open B; fi; read -r -p "回车继续..." _ ;;
            0) exit 0 ;;
        esac
    done
}

case "${1:-menu}" in
    monitor-check) checkdetail ;;
    checkdetail) OUT="$BASE/last-check.txt"; { checkdetail; } > "$OUT" 2>&1; cat "$OUT" ;;
    desktop-info) desktop_info ;;
    desktop) desktop_open "${2:-A}" ;;
    status) status ;;
    fix) fix ;;
    switch) case "${2:-}" in A|B) switch_to "$2" ;; *) echo "槽位必须是 A 或 B"; exit 2 ;; esac ;;
    write-merge-rules) write_merge_rules ;;  # 隐藏入口:供安装器调用,保证两处合并逻辑一致
    menu) menu ;;
    *) echo "用法: claude-switch.sh checkdetail|status|fix|switch A|B|desktop [A|B]|desktop-info|menu"; exit 2 ;;
esac
