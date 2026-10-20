#!/bin/bash
# Claude 账号切换器 - 核心脚本 (通用版)
# 用法: claude-switch.sh check | status | switch A|B | checkdetail | fix
set -u
export LC_ALL=en_US.UTF-8

# ============ 安装时可配置项(安装程序会自动改写) ============
PROXY_GROUP="IpEqual"            # Clash 代理组名(安装时自动探测)
# 地区模板: 出口国家码 → 锁定时区 + AppleLocale,三者必须一致才判通过
tpl_tz()     { case "$1" in US) echo "America/Los_Angeles";; TW) echo "Asia/Taipei";; SG) echo "Asia/Singapore";; *) echo "";; esac; }
tpl_locale() { case "$1" in US) echo "en_US";; TW) echo "zh_TW";; SG) echo "en_SG";; *) echo "";; esac; }
# ============================================================

DATA="$HOME/Library/Application Support/Claude"
BASE="$HOME/.claude-switcher"
LOG="$HOME/Library/Logs/claude-switch.log"
CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
mkdir -p "$BASE/accounts"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

# 用户明确应用过模板后固定该目标；旧安装仍按最近检测的出口识别。
target_region() {
    if [ -f "$BASE/template" ]; then
        cat "$BASE/template"
    else
        printf '%s\n' "${1:-}"
    fi
}

# 只调整模板对应的时区和地区格式，不改 Clash 节点或账号数据。
apply_template() {
    local code="${1:-}" target_tz target_locale saved
    target_tz=$(tpl_tz "$code")
    target_locale=$(tpl_locale "$code")
    [ -n "$target_tz" ] || { echo "FAIL:未知模板，仅支持 US/TW/SG"; return 1; }
    if [ "$(readlink /etc/localtime 2>/dev/null)" != "/var/db/timezone/zoneinfo/$target_tz" ]; then
        if ! osascript - "$target_tz" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    do shell script ("/usr/sbin/systemsetup -settimezone " & quoted form of (item 1 of argv)) with prompt "应用地区模板需要调整系统时区" with administrator privileges
end run
APPLESCRIPT
        then
            echo "FAIL:时区调整被取消或失败，模板未保存"
            return 1
        fi
    fi
    [ "$(readlink /etc/localtime 2>/dev/null)" = "/var/db/timezone/zoneinfo/$target_tz" ] || {
        echo "FAIL:系统时区未生效，模板未保存"; return 1;
    }
    defaults write -g AppleLocale "$target_locale" &&
        [ "$(defaults read -g AppleLocale 2>/dev/null)" = "$target_locale" ] || {
        echo "FAIL:地区格式设置失败，请重新检查系统设置"; return 1;
    }
    saved=$(mktemp "$BASE/template.XXXXXX") || { echo "FAIL:无法保存模板"; return 1; }
    if ! printf '%s\n' "$code" > "$saved" || ! mv "$saved" "$BASE/template"; then
        rm -f "$saved"
        echo "FAIL:无法保存模板，请重新检查系统设置"
        return 1
    fi
    echo "OK:template=$code"
}

# TUN 在线判定:存在 fake-ip 网段地址即视为 TUN 已接管(兼容各种 TUN 设备名)
tun_up() { ifconfig 2>/dev/null | grep -q 'inet 198\.18\.'; }

# ---------- 安全检查 ----------
check() {
    fails=""

    pgrep -f verge-mihomo >/dev/null 2>&1 || fails="$fails;代理内核未运行"
    tun_up || fails="$fails;TUN网卡不在线"

    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    expected=$(target_region "$loc")
    exptz=$(tpl_tz "$expected")
    [ -n "$exptz" ] && [ "$loc" = "$expected" ] || fails="$fails;出口地区${loc:-未知}与模板${expected:-未知}不匹配"
    ipwarn=""
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    if [ -n "$ip" ] && [ -n "$lastip" ] && [ "$ip" != "$lastip" ]; then
        ipwarn="注意:出口IP与上次不同($lastip -> $ip)"
    fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"

    tz=$(readlink /etc/localtime 2>/dev/null)
    [ "$tz" = "/var/db/timezone/zoneinfo/$exptz" ] || fails="$fails;时区异常($tz,应为$exptz)"

    locale=$(defaults read -g AppleLocale 2>/dev/null)
    exploc=$(tpl_locale "$expected")
    [ "$locale" = "$exploc" ] || fails="$fails;地区异常($locale,应为$exploc)"

    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    echo "$v6" | grep -qi 'off' || fails="$fails;IPv6未关闭"

    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) ;;
        *) fails="$fails;DNS未走隧道(返回${dnsip:-空})" ;;
    esac

    wr=$(webrtc_test)
    if [ "$wr" != "RESULT:NONE" ]; then
        case "$wr" in
            RESULT:*)
                wips=${wr#RESULT:}
                leak=""
                OLDIFS=$IFS; IFS=','
                for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
                IFS=$OLDIFS
                [ -n "$leak" ] && fails="$fails;WebRTC泄漏($leak)" ;;
            *) fails="$fails;WebRTC检测异常" ;;
        esac
    fi

    launchctl print system/local.claude-bodyguard >/dev/null 2>&1 || fails="$fails;保镖未运行"

    grep -q "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" "$CLASH_DIR/clash-verge.yaml" 2>/dev/null || fails="$fails;置顶规则缺失"

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

# 逐项输出检查结果(供UI使用): 名称=ok|fail:细节
checkdetail() {
    if pgrep -f verge-mihomo >/dev/null 2>&1; then echo '代理内核=ok'; else echo '代理内核=fail:未运行'; fi
    if tun_up; then echo 'TUN网卡=ok'; else echo 'TUN网卡=fail:不在线'; fi
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    expected=$(target_region "$loc")
    exptz=$(tpl_tz "$expected")
    [ -n "$loc" ] && echo "$loc" > "$BASE/region"
    if [ -n "$exptz" ] && [ "$loc" = "$expected" ]; then
        echo "出口IP=ok:$ip/$loc"
    else
        echo "出口IP=fail:出口${loc:-未知}，模板${expected:-未知}；请在Clash选择对应节点"
    fi
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    if [ -z "$ip" ]; then echo 'IP一致=fail:未获取到出口IP'
    elif [ -z "$lastip" ]; then echo 'IP一致=ok:首次记录'
    elif [ "$ip" = "$lastip" ]; then echo 'IP一致=ok'
    else echo "IP一致=warn:$lastip → $ip"; fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"
    tz=$(readlink /etc/localtime 2>/dev/null)
    if [ -n "$exptz" ] && [ "$tz" = "/var/db/timezone/zoneinfo/$exptz" ]; then echo "时区=ok:$exptz"; else echo "时区=fail:$tz(应$exptz)"; fi
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    exploc=$(tpl_locale "$expected")
    if [ -n "$exploc" ] && [ "$locale" = "$exploc" ]; then echo "地区=ok:$exploc"; else echo "地区=fail:$locale(应$exploc)"; fi
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    if echo "$v6" | grep -qi 'off'; then echo 'IPv6=ok:已关闭'; else echo 'IPv6=fail:未关闭'; fi
    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) echo 'DNS=ok:走隧道' ;;
        *) echo "DNS=fail:未走隧道(${dnsip:-空})" ;;
    esac
    wr=$(webrtc_test)
    case "$wr" in
        RESULT:NONE) echo 'WebRTC=ok:UDP不出网,零暴露' ;;
        RESULT:*)
            wips=${wr#RESULT:}
            leak=""
            OLDIFS=$IFS; IFS=','
            for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
            IFS=$OLDIFS
            if [ -n "$leak" ]; then echo "WebRTC=fail:暴露非代理IP:$leak"; else echo 'WebRTC=ok:仅暴露代理IP'; fi ;;
        *) echo 'WebRTC=fail:检测异常' ;;
    esac
    if launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        lastkill=$(tail -1 "$HOME/Library/Logs/claude-bodyguard.log" 2>/dev/null | cut -c1-40)
        echo "保镖=ok:${lastkill:-待命}"
    else
        echo '保镖=fail:未安装'
    fi
    if grep -q "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" "$CLASH_DIR/clash-verge.yaml" 2>/dev/null; then
        echo '规则置顶=ok'
    else
        echo '规则置顶=fail:未生效'
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
    # 13. ASN 网络属性(住宅宽带 vs 机房)
    org=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null | grep '"org"' | cut -d'"' -f4)
    case "$org" in
        '') echo 'ASN属性=warn:未获取' ;;
        *Comcast*|*AT\&T*|*Verizon*|*Spectrum*|*Charter*|*Cox*|*T-Mobile*|*Cable*|*esidential*|*HiNet*|*hinet*|*Chunghwa*|*CHT*|*kbro*|*Taiwan*|*FarEasTone*|*Data\ Communication*|*Singtel*|*StarHub*|*M1\ *) echo "ASN属性=ok:$org" ;;
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

# 一键修复:按项自动修复,每步输出结果
fix() {
    echo "FIX:开始一键修复"

    # A. 代理内核 + TUN
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

    # B. 时区/IPv6/DNS缓存/保镖(需管理员权限,会弹一次密码框)
    tz=$(readlink /etc/localtime 2>/dev/null)
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    fixloc=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^loc=' | cut -d= -f2)
    fixloc=$(target_region "$fixloc")
    expTZ=$(tpl_tz "$fixloc")
    expLoc=$(tpl_locale "$fixloc")
    adminCmds=""
    [ -n "$expTZ" ] && [ "$tz" != "/var/db/timezone/zoneinfo/$expTZ" ] && adminCmds="${adminCmds}/usr/sbin/systemsetup -settimezone $expTZ; "
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

    # B1. 地区与出口一致(用户级,无需密码)
    if [ -n "$expLoc" ]; then
        curloc=$(defaults read -g AppleLocale 2>/dev/null)
        [ "$curloc" != "$expLoc" ] && defaults write -g AppleLocale "$expLoc" && echo "FIX:地区 → $expLoc ✓"
    fi

    # B3. Claude 客户端单独设英文(用户级,无需密码;系统首选语言已是英文则跳过)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if ! defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' && [[ "$syslang" != en* ]]; then
        defaults write com.anthropic.claudefordesktop AppleLanguages -array en-US
        echo "FIX:Claude 客户端语言 → en-US ✓(重启 Claude 后生效)"
    fi

    # B2. 置顶规则缺失 → 重写 Merge 配置并重启 Clash
    if ! grep -q "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" "$CLASH_DIR/clash-verge.yaml" 2>/dev/null; then
        echo "FIX:重写置顶规则..."
        cat > "$CLASH_DIR/profiles/Merge.yaml" <<MEOF
# Profile Enhancement Merge Template for Clash Verge

profile:
  store-selected: true

# Claude 全家族及生态域名置顶强制走代理(优先级高于任何国内规则集)
prepend-rules:
  - DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP
  - DOMAIN-SUFFIX,claude.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,anthropic.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,claudeusercontent.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,challenges.cloudflare.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,datadoghq.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,segment.io,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripe.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripe.network,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripecdn.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercom.io,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercomcdn.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercomassets.com,$PROXY_GROUP
MEOF
        osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
        sleep 3
        open -a "Clash Verge"
        for i in $(seq 1 40); do
            tun_up && break
            sleep 1
        done
        grep -q "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" "$CLASH_DIR/clash-verge.yaml" 2>/dev/null \
            && echo "FIX:置顶规则 ✓" || echo "FIX:置顶规则 ✗"
    fi

    # C. 出口IP最终验证
    sleep 2
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ -n "$(tpl_tz "$loc")" ] && [ "$loc" = "$(target_region "$loc")" ]; then
        echo "FIX:出口IP ✓ ($ip/$loc)"
    else
        echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知}) — 可能是节点故障,请到 Clash 里换条线路"
    fi
    echo "FIX:修复流程结束"
}

status() {
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    hasA=0; [ -d "$BASE/accounts/A" ] && hasA=1
    hasB=0; [ -d "$BASE/accounts/B" ] && hasB=1
    recent=$(cat "$BASE/region" 2>/dev/null)
    template=$(target_region "$recent")
    template_mode=auto; [ -f "$BASE/template" ] && template_mode=manual
    echo "current=$cur hasA=$hasA hasB=$hasB template=$template templateMode=$template_mode"
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
    cur="$1"
    rm -rf "$BASE/accounts/$cur.tmp"
    ditto "$DATA" "$BASE/accounts/$cur.tmp" && rm -rf "$BASE/accounts/$cur" && mv "$BASE/accounts/$cur.tmp" "$BASE/accounts/$cur"
    log "已存档账号$cur"
}

switch_to() {
    target="$1"
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")

    # 首次运行:把当前登录中的状态收编为账号A
    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }
        archive_current A
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前登录状态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        open -a "Claude"
        echo "INFO:当前已是账号$target"
        return 0
    fi

    quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }

    [ "$cur" != "none" ] && [ -d "$DATA" ] && archive_current "$cur"

    rm -rf "$DATA.new"
    if [ -d "$BASE/accounts/$target" ]; then
        ditto "$BASE/accounts/$target" "$DATA.new"
        log "已载入账号$target 存档"
    else
        mkdir -p "$DATA.new"
        log "账号$target 无存档，将以全新状态初始化"
    fi
    rm -rf "$DATA" && mv "$DATA.new" "$DATA"
    echo "$target" > "$BASE/current"

    open -a "Claude"
    log "已切换到账号$target 并启动"
    echo "OK:已切换到账号$target"
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
    apply-template) apply_template "${2:-}" ;;
    switch) switch_to "${2:-}" ;;
    *) echo "用法: claude-switch.sh check|checkdetail|fix|status|switch A|B|apply-template US|TW|SG"; exit 2 ;;
esac
