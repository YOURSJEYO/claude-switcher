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

# ---- 2. 地区自适应(按出口IP自动锁定 国家/时区/地区格式;必须先挂代理) ----
IPINFO=$(curl -fs --max-time 20 --retry 2 --retry-all-errors https://ipinfo.io/json 2>/dev/null)
CTRY=$(echo "$IPINFO" | grep '"country"' | cut -d'"' -f4)
if [ "$CTRY" = "CN" ] && [ -z "$FORCE" ]; then
    echo ""
    echo "❌ 检测到当前出口在国内(国家: CN)。"
    echo "   请先在代理客户端里开启代理(TUN模式)并确认节点可用,再运行本安装程序。"
    echo "   (否则时区/地区会被错误锁定)"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if [ -z "$CTRY" ]; then
    echo "⚠️  未能识别出口国家,请确认代理已开启后重试(或用 FORCE=1 跳过)。"
    [ -z "$FORCE" ] && { read -n 1 -s -r -p "按任意键退出..."; exit 1; }
    CTRY="US"
fi
TZV=$(echo "$IPINFO" | grep '"timezone"' | cut -d'"' -f4)
[ -z "$TZV" ] && TZV="America/New_York"
LOCALE=$(locale_for "$CTRY")
echo "✓ 地区自适应: 国家=$CTRY 时区=$TZV 地区格式=$LOCALE (按当前出口IP自动识别)"

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
    echo "✗ App 编译失败,请确认 Xcode 命令行工具完整: xcode-select --install"
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
</dict>
</plist>
EOF
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "✓ App 已放到桌面"

# ---- 5. 写入置顶规则(仅 Clash Verge;智能合并不覆盖已有配置;其他客户端自行配置) ----
if [ "$MODE" = "clash-verge" ]; then
    # 复用核心脚本里的 write_merge_rules(隐藏入口),保证与 fix() 行为一致
    if "$H/.local/bin/claude-switch.sh" write-merge-rules; then
        echo "✓ Claude 域名置顶规则已写入(智能合并,不动已有配置;重启 Clash Verge 后生效)"
    else
        echo "⚠️  置顶规则写入失败,可稍后运行 claude-switch.sh fix 重试"
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
