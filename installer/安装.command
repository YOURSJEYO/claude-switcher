#!/bin/bash
# Claude 切换器 - 通用安装程序 (macOS)
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
H="$HOME"
clear
echo "=================================="
echo "  Claude 账号切换器 · 安装程序"
echo "=================================="
echo ""

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
detect_geo() {
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

# ---- 0. 前置检查 ----
CLASH_DIR="$H/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
if [ -d "$CLASH_DIR" ]; then
    MODE="clash-verge"
elif scutil --nc list 2>/dev/null | grep -q 'com.liguangming.Shadowrocket'; then
    MODE="shadowrocket"
else
    echo "未自动识别到代理客户端,请手动选择:"
    echo "  1) clash-verge    2) shadowrocket    3) sing-box"
    echo "  4) clashx         5) surge           6) auto(任一命中即活)"
    read -r -p "请输入序号或名称: " pick
    case "$pick" in
        1|clash-verge)  MODE="clash-verge" ;;
        2|shadowrocket) MODE="shadowrocket" ;;
        3|sing-box)     MODE="sing-box" ;;
        4|clashx)       MODE="clashx" ;;
        5|surge)        MODE="surge" ;;
        6|auto)         MODE="auto" ;;
        *) echo "未识别的选择,退出"; exit 1 ;;
    esac
fi
echo "✓ 代理客户端: $MODE"
if [ ! -d /Applications/Claude.app ]; then
    echo "⚠️  未检测到 Claude 桌面版(/Applications/Claude.app),请先安装。"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if ! python3 --version >/dev/null 2>&1; then
    echo "⚠️  未检测到 python3,请先安装 Xcode 命令行工具: xcode-select --install"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "⚠️  未检测到 swiftc(界面 App 需要现场编译),请先运行: xcode-select --install"
    echo "   注意:macOS 26/27 上仅装 Command Line Tools 可能因缺少 SwiftUIMacros 插件编译失败,"
    echo "   如遇失败请安装完整 Xcode 并执行: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
echo "✓ 前置检查通过($MODE / Claude / python3 / swiftc)"

# ---- 1. 自动探测代理组名(仅 Clash Verge;多个 select 组时让用户选,避免静默选错专线) ----
GRP=""
if [ "$MODE" = "clash-verge" ]; then
    GRPS=()
    while IFS= read -r g; do GRPS+=("$g"); done < <(awk '
        /^proxy-groups:/ {f=1; next}
        f && /^[a-zA-Z]/ {f=0}
        f && /- name:/ { n=$0; sub(/.*- name: */, "", n); gsub(/"/, "", n) }
        f && /type: *select/ { print n }
    ' "$CLASH_DIR/clash-verge.yaml" 2>/dev/null)
    if [ "${#GRPS[@]}" -eq 0 ]; then
        echo ""
        echo "未能自动识别你的代理组名,请打开 Clash Verge 查看「代理」页面顶部的组名。"
        read -r -p "请输入代理组名: " GRP
        [ -z "$GRP" ] && { echo "未输入,退出"; exit 1; }
    elif [ "${#GRPS[@]}" -eq 1 ]; then
        GRP="${GRPS[0]}"
    else
        echo ""
        echo "检测到多个代理组,请选择用于 Claude 专线的那个:"
        i=1
        for g in "${GRPS[@]}"; do echo "  $i) $g"; i=$((i+1)); done
        read -r -p "请输入序号: " pick
        case "$pick" in ''|*[!0-9]*) echo "输入无效,退出"; exit 1 ;; esac
        if [ "$pick" -lt 1 ] || [ "$pick" -gt "${#GRPS[@]}" ]; then
            echo "序号超范围,退出"; exit 1
        fi
        GRP="${GRPS[$((pick-1))]}"
    fi
    echo "✓ 代理组: $GRP"
fi

# ---- 2. 地区自适应(多源探测出口国家;失败可手动选择;FORCE=1 强制 US) ----
GEO_DIAG_FILE=$(mktemp "${TMPDIR:-/tmp}/claude-geo.XXXXXX" 2>/dev/null) || GEO_DIAG_FILE=""
GEO=$(detect_geo)
CTRY=$(echo "$GEO" | cut -d'|' -f1)
TZV=$(echo "$GEO" | cut -d'|' -f2)
SOURCE=$(echo "$GEO" | cut -d'|' -f3)
GEO_DIAG=$(cat "$GEO_DIAG_FILE" 2>/dev/null)
[ -n "$GEO_DIAG_FILE" ] && rm -f "$GEO_DIAG_FILE"
unset GEO_DIAG_FILE
if [ -z "$CTRY" ]; then
    echo ""
    echo "⚠️  未能识别出口国家,各源探测结果:"
    printf '%s\n' "${GEO_DIAG:-无诊断信息}" | sed 's/^/   /'
    if [ -n "$FORCE" ]; then
        CTRY="US"; TZV="America/New_York"; SOURCE="force"
        echo "   FORCE=1,按 US / America/New_York 继续"
    else
        echo ""
        echo "请手动选择当前出口所在地区:"
        echo "  1) US   2) JP   3) TW   4) HK   5) SG   6) GB"
        echo "  7) DE   8) FR   9) KR  10) AU  11) CA"
        while true; do
            read -r -p "请输入序号: " pick || { echo "未读取到输入,退出"; exit 1; }
            case "$pick" in
                1|US|us) CTRY="US" ;; 2|JP|jp) CTRY="JP" ;; 3|TW|tw) CTRY="TW" ;;
                4|HK|hk) CTRY="HK" ;; 5|SG|sg) CTRY="SG" ;; 6|GB|gb) CTRY="GB" ;;
                7|DE|de) CTRY="DE" ;; 8|FR|fr) CTRY="FR" ;; 9|KR|kr) CTRY="KR" ;;
                10|AU|au) CTRY="AU" ;; 11|CA|ca) CTRY="CA" ;;
                '') echo "未输入,请重试" >&2; continue ;;
                *) echo "未识别的选择,请重试" >&2; continue ;;
            esac
            break
        done
        TZV=$(default_tz_for "$CTRY"); SOURCE="manual"
    fi
fi
if [ "$CTRY" = "CN" ] && [ -z "$FORCE" ]; then
    echo ""
    echo "❌ 检测到当前出口在国内(国家: CN)。"
    echo "   请先在代理客户端里开启代理(TUN模式)并确认节点可用,再运行本安装程序。"
    echo "   (否则时区/地区会被错误锁定)"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if [ "$CTRY" = "CN" ]; then
    CTRY="US"; TZV="America/New_York"; SOURCE="force"
fi
[ -n "$TZV" ] || TZV=$(default_tz_for "$CTRY")
[ "$SOURCE" = "cloudflare" ] && echo "ℹ️  时区使用国家默认(可手动改)"
LOCALE=$(locale_for "$CTRY")
echo "✓ 地区识别: 国家=$CTRY 时区=$TZV 来源=$SOURCE"
echo "✓ 地区格式: $LOCALE"

# ---- 3. 安装文件 ----
mkdir -p "$H/.local/bin" "$H/.claude-switcher" "$H/Library/Logs"
cp "$REPO/core/claude-switch.sh" "$H/.local/bin/"
cp "$REPO/core/stun-probe.py" "$H/.claude-switcher/"
chmod +x "$H/.local/bin/claude-switch.sh"
# 写入探测到的客户端/代理组名/地区目标
sed -i '' \
    -e "s|^PROXY_MODE=\".*\"|PROXY_MODE=\"$MODE\"|" \
    -e "s|^PROXY_GROUP=\".*\"|PROXY_GROUP=\"$GRP\"|" \
    -e "s|^COUNTRY_TARGET=\".*\"|COUNTRY_TARGET=\"$CTRY\"|" \
    -e "s|^TZ_TARGET=\".*\"|TZ_TARGET=\"$TZV\"|" \
    -e "s|^LOCALE_TARGET=\".*\"|LOCALE_TARGET=\"$LOCALE\"|" \
    "$H/.local/bin/claude-switch.sh"

# 保镖/时区看门狗脚本:物化到临时目录,由 sudo 段装入 root 所有的系统目录(用户态不可写,防提权)
STAGE=$(mktemp -d)
sed -e "s|__HOME__|$H|g" -e "s|__PROXY_MODE__|$MODE|g" \
    "$REPO/daemons/claude-bodyguard.sh" > "$STAGE/claude-bodyguard.sh"
sed -e "s|__HOME__|$H|g" -e "s|__TZ_TARGET__|$TZV|g" \
    "$REPO/daemons/tz-watchdog.sh" > "$STAGE/tz-watchdog.sh"
chmod +x "$STAGE/claude-bodyguard.sh" "$STAGE/tz-watchdog.sh"
# 清理旧版本装在用户目录下的守护脚本(用户可写=提权面)
rm -f "$H/.local/bin/claude-bodyguard.sh" "$H/.local/bin/tz-watchdog.sh" \
      "$H/.local/bin/claude-bodyguard.sh.bak" "$H/.local/bin/tz-watchdog.sh.bak"

# launchd 配置(保镖/看门狗的 ProgramArguments 已指向系统目录,直接拷贝;自动更新为 LaunchAgent)
cp "$REPO/daemons/local.claude-bodyguard.plist" "$REPO/daemons/local.tz-watchdog.plist" "$H/.local/bin/"
sed "s|__HOME__|$H|g" "$REPO/daemons/local.claude-update.plist" > "$H/.local/bin/local.claude-update.plist"
echo "✓ 核心文件已安装"

# ---- 4. 现场编译 App 到桌面 ----
APP="$H/Desktop/Claude切换器.app"
mkdir -p "$H/Desktop"
pkill -x ClaudeSwitcher 2>/dev/null
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 必须带 -target,否则新 SDK 编出的二进制在老系统被拒启动
if swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    "$REPO/app/main.swift" -o "$APP/Contents/MacOS/ClaudeSwitcher" \
    -framework SwiftUI -framework AppKit; then
    echo "✓ App 编译完成"
else
    echo "✗ App 编译失败。若日志提示 SwiftUIMacros/插件缺失(macOS 26/27 常见),"
    echo "  请安装完整 Xcode 后执行: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
# 图标: assets/ 里有 PNG 源文件时现场生成 icns
PNG="$REPO/assets/icon-2048.png"
if [ -f "$PNG" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz" "$PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1
        sips -z $((sz*2)) $((sz*2)) "$PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
        && echo "✓ 图标已生成" || echo "⚠️  图标生成失败(不影响使用)"
fi
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
	<key>CFBundleIdentifier</key><string>local.claude-switcher</string>
	<key>CFBundleName</key><string>Claude切换器</string>
	<key>CFBundleDisplayName</key><string>Claude切换器</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "✓ App 已放到桌面"

# ---- 5. 生成全局扩展脚本(仅 Clash Verge;保留已有 main 与无关配置) ----
if [ "$MODE" = "clash-verge" ]; then
    # 复用核心脚本里的 write_merge_rules(隐藏入口),保证与 fix() 行为一致
    if "$H/.local/bin/claude-switch.sh" write-merge-rules; then
        echo "✓ 全局 Script.js 已写入(含 UDP 端口策略;保留已有 main;待重启后验证内核加载)"
    else
        echo "⚠️  全局脚本未写入:请检查代理组、节点 UDP 支持和本机控制接口后运行 claude-switch.sh fix"
    fi
else
    echo "ℹ️  当前客户端为 $MODE,请自行在客户端中添加 DOMAIN-SUFFIX 置顶规则:"
    echo "    claude.ai / claude.com / anthropic.com / claudeusercontent.com"
    echo "    challenges.cloudflare.com / datadoghq.com / segment.io"
    echo "    stripe.com / stripe.network / stripecdn.com"
    echo "    intercom.io / intercomcdn.com / intercomassets.com"
fi

# ---- 6. 系统级配置(需要一次密码;时区/IPv6 已是目标值则跳过对应命令) ----
if [ -n "$DRYRUN" ]; then
    echo "[演练模式] 跳过系统级配置(守护进程/时区/IPv6)"
    rm -rf "$STAGE"
else
    # 守护脚本装入 root 所有的系统目录;同时清理旧版的 root 级自动更新(已改为用户态 LaunchAgent)
    SYSCMDS="mkdir -p '/Library/Application Support/claude-switcher';
        cp '$STAGE/claude-bodyguard.sh' '$STAGE/tz-watchdog.sh' '/Library/Application Support/claude-switcher/';
        chown root:wheel '/Library/Application Support/claude-switcher/claude-bodyguard.sh' '/Library/Application Support/claude-switcher/tz-watchdog.sh';
        chmod 755 '/Library/Application Support/claude-switcher/claude-bodyguard.sh' '/Library/Application Support/claude-switcher/tz-watchdog.sh';
        cp '$H/.local/bin/local.claude-bodyguard.plist' '$H/.local/bin/local.tz-watchdog.plist' /Library/LaunchDaemons/;
        chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist;
        chmod 644 /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist;
        launchctl bootout system/local.claude-bodyguard 2>/dev/null; launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist;
        launchctl bootout system/local.tz-watchdog 2>/dev/null; launchctl bootstrap system /Library/LaunchDaemons/local.tz-watchdog.plist;
        launchctl bootout system/local.claude-update 2>/dev/null; rm -f /Library/LaunchDaemons/local.claude-update.plist;"
    curt=$(readlink /etc/localtime 2>/dev/null)
    [ "$curt" != "/var/db/timezone/zoneinfo/$TZV" ] && SYSCMDS="$SYSCMDS /usr/sbin/systemsetup -settimezone '$TZV';"
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    echo "$v6" | grep -qi 'off' || SYSCMDS="$SYSCMDS networksetup -setv6off Wi-Fi;"
    SYSCMDS="$SYSCMDS dscacheutil -flushcache; killall -HUP mDNSResponder"
    echo ""
    echo "接下来需要输入一次开机密码,用于: 安装守护进程(系统目录) + 锁定时区($TZV) + 关闭IPv6"
    sudo bash -c "$SYSCMDS" && echo "✓ 系统级配置完成" || echo "✗ 系统级配置被取消,可稍后重新运行安装程序"
    rm -rf "$STAGE"

    # 自动更新:用户态 LaunchAgent(每12小时),不走 root,降低供应链风险
    mkdir -p "$H/Library/LaunchAgents"
    cp "$H/.local/bin/local.claude-update.plist" "$H/Library/LaunchAgents/local.claude-update.plist"
    launchctl bootout "gui/$(id -u)/local.claude-update" 2>/dev/null
    if launchctl bootstrap "gui/$(id -u)" "$H/Library/LaunchAgents/local.claude-update.plist" 2>/dev/null; then
        echo "✓ 自动更新服务已注册(每12小时检查一次)"
    else
        echo "⚠️  自动更新服务注册失败,可手动保底: claude-switch.sh update"
    fi
fi

# ---- 7. 重启 Clash 使规则生效(仅 Clash Verge) ----
if [ -z "$DRYRUN" ] && [ "$MODE" = "clash-verge" ]; then
    osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
    sleep 2
    open -a "Clash Verge" >/dev/null 2>&1
fi

# ---- 8. 自检 ----
echo ""
echo "=================================="
echo "  自检结果 (checkdetail)"
echo "=================================="
"$H/.local/bin/claude-switch.sh" checkdetail 2>&1 || true

echo ""
echo "=================================="
echo "  ✅ 安装完成!"
echo "  使用: 双击桌面「Claude切换器」"
echo "  首次使用: 打开后选账号A(自动收编当前登录)"
echo "  换了其他国家节点后: 运行 claude-switch.sh set-region 一键重新适配"
echo "  自动更新已启用(每12小时检查一次),也可手动: claude-switch.sh update"
echo "=================================="
read -n 1 -s -r -p "按任意键关闭窗口..."
