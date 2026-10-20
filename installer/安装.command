#!/bin/bash
# Claude 切换器 - 安装程序 (macOS · Shadowrocket 版)
set -u
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
H="$HOME"
VPN_NAME="Shadowrocket"
VPN_ID="com.liguangming.Shadowrocket"
clear
echo "=================================="
echo "  Claude 账号切换器 · 安装程序"
echo "  (Shadowrocket 版)"
echo "=================================="
echo ""

# ---- 0. 前置检查 ----
if ! scutil --nc list 2>/dev/null | grep -q "$VPN_ID"; then
    echo "❌ 未检测到 Shadowrocket。请先安装 Shadowrocket,打开并连接一次后再运行本安装程序。"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if ! scutil --nc list 2>/dev/null | grep "$VPN_ID" | grep -q '(Connected)'; then
    echo "❌ Shadowrocket 未连接。请先打开 Shadowrocket 并连上节点,再运行本安装程序。"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if [ ! -d /Applications/Claude.app ]; then
    echo "⚠️  未检测到 Claude 桌面版(/Applications/Claude.app),请先安装。"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if ! python3 --version >/dev/null 2>&1; then
    echo "⚠️  未检测到 python3,请先安装 Xcode 命令行工具: xcode-select --install"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "⚠️  未检测到 swiftc(编译界面需要),请先安装 Xcode 命令行工具: xcode-select --install"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if ! ifconfig 2>/dev/null | grep -q 'inet 198\.18\.'; then
    echo "❌ TUN 网卡未接管(fake-ip 198.18.x.x 不存在)。请确认 Shadowrocket 已连接且为全局/TUN 模式。"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
echo "✓ 前置检查通过(Shadowrocket / Claude / python3 / swiftc / TUN)"

# ---- 1. 自动探测时区(应与出口IP城市一致;必须先挂代理) ----
IPINFO=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null)
CTRY=$(echo "$IPINFO" | grep '"country"' | cut -d'"' -f4)
if [ "$CTRY" != "US" ] && [ -z "${FORCE:-}" ]; then
    echo ""
    echo "❌ 检测到当前出口不在美国(国家: ${CTRY:-未知})。"
    echo "   请先在 Shadowrocket 里连上美国节点,再运行本安装程序。"
    echo "   (否则时区会被错误识别)"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
TZV=$(echo "$IPINFO" | grep '"timezone"' | cut -d'"' -f4)
[ -z "$TZV" ] && TZV="America/New_York"
echo "✓ 锁定时区: $TZV (按当前出口IP自动识别)"

# ---- 2. 安装核心文件(直接从仓库源码,无需 installer/files/) ----
mkdir -p "$H/.local/bin" "$H/.claude-switcher" "$H/Library/Logs"
cp "$REPO/core/claude-switch.sh" "$H/.local/bin/"
cp "$REPO/core/stun-probe.py" "$H/.claude-switcher/"
chmod +x "$H/.local/bin/claude-switch.sh"
sed -i '' "s|^TZ_TARGET=\".*\"|TZ_TARGET=\"$TZV\"|" "$H/.local/bin/claude-switch.sh"

# 保镖脚本 + 时区看门狗(由 daemons/ 模板物化)
sed "s|__HOME__|$H|g" "$REPO/daemons/claude-bodyguard.sh" > "$H/.local/bin/claude-bodyguard.sh"
sed -e "s|__HOME__|$H|g" -e "s|__TZ_TARGET__|$TZV|g" "$REPO/daemons/tz-watchdog.sh" > "$H/.local/bin/tz-watchdog.sh"
chmod +x "$H/.local/bin/claude-bodyguard.sh" "$H/.local/bin/tz-watchdog.sh"

# launchd 配置
sed "s|__HOME__|$H|g" "$REPO/daemons/local.claude-bodyguard.plist" > "$H/.local/bin/local.claude-bodyguard.plist"
sed -e "s|__HOME__|$H|g" -e "s|__TZ_TARGET__|$TZV|g" "$REPO/daemons/local.tz-watchdog.plist" > "$H/.local/bin/local.tz-watchdog.plist"
echo "✓ 核心文件已安装"

# ---- 3. 现场编译界面 App(单文件 SwiftUI,无第三方依赖) ----
echo "⏳ 正在编译界面 App(约 20~60 秒)..."
pkill -x ClaudeSwitcher 2>/dev/null
APP="$H/Desktop/Claude切换器.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 必须显式指定部署目标:否则新工具链会把二进制标成当前 SDK 版本,导致在旧系统上拒绝启动
if ! swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" "$REPO/app/main.swift" \
        -o "$APP/Contents/MacOS/ClaudeSwitcher" \
        -framework SwiftUI -framework AppKit 2>"$H/Library/Logs/claude-switcher-build.log"; then
    echo "❌ 界面编译失败,日志: ~/Library/Logs/claude-switcher-build.log"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
chmod +x "$APP/Contents/MacOS/ClaudeSwitcher"

# 图标(从 assets/ 的 PNG 生成 icns)
if [ -f "$REPO/assets/icon-2048.png" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$REPO/assets/icon-2048.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
        sips -z "$((s*2))" "$((s*2))" "$REPO/assets/icon-2048.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1
    rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
    <key>CFBundleIdentifier</key><string>local.claude-switcher</string>
    <key>CFBundleName</key><string>Claude切换器</string>
    <key>CFBundleDisplayName</key><string>Claude切换器</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "✓ App 已编译并放到桌面"

# ---- 4. 系统级配置(需要一次密码) ----
# 已经是目标值时不做多余改动,避免 systemsetup/网络命令的副作用与噪音
CUR_TZ=$(readlink /etc/localtime 2>/dev/null)
NEED_TZ=0
[ "$CUR_TZ" != "/var/db/timezone/zoneinfo/$TZV" ] && NEED_TZ=1
V6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
NEED_V6=0
echo "$V6" | grep -qi 'off' || NEED_V6=1

if [ -n "${DRYRUN:-}" ]; then
    echo "[演练模式] 跳过系统级配置(守护进程/时区/IPv6)"
else
    TZ_CMD=""; [ "$NEED_TZ" -eq 1 ] && TZ_CMD="/usr/sbin/systemsetup -settimezone '$TZV'; "
    V6_CMD=""; [ "$NEED_V6" -eq 1 ] && V6_CMD="networksetup -setv6off Wi-Fi; "
    REASON="安装守护进程"
    [ "$NEED_TZ" -eq 1 ] && REASON="$REASON + 锁定时区($TZV)"
    [ "$NEED_V6" -eq 1 ] && REASON="$REASON + 关闭IPv6"
    echo ""
    echo "接下来需要输入一次开机密码,用于: $REASON"
    sudo bash -c "
        cp '$H/.local/bin/local.claude-bodyguard.plist' '$H/.local/bin/local.tz-watchdog.plist' /Library/LaunchDaemons/
        chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist
        chmod 644 /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist
        launchctl bootout system/local.claude-bodyguard 2>/dev/null; launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist
        launchctl bootout system/local.tz-watchdog 2>/dev/null; launchctl bootstrap system /Library/LaunchDaemons/local.tz-watchdog.plist
        ${TZ_CMD}${V6_CMD}dscacheutil -flushcache; killall -HUP mDNSResponder
    " && echo "✓ 系统级配置完成" || echo "✗ 系统级配置被取消,可稍后重新运行安装程序"
    [ "$NEED_TZ" -eq 1 ] && echo "✓ 时区已锁定为 $TZV" || echo "✓ 时区已是 $TZV,未改动"
    [ "$NEED_V6" -eq 1 ] && echo "✓ IPv6 已关闭" || echo "✓ IPv6 已是关闭状态,未改动"
fi

# ---- 5. 自检 ----
echo ""
echo "⏳ 执行安装后自检..."
"$H/.local/bin/claude-switch.sh" checkdetail | sed 's/^/   /'

echo ""
echo "=================================="
echo "  ✅ 安装完成!"
echo "  使用: 双击桌面「Claude切换器」"
echo "  首次使用: 打开后选账号A(自动收编当前登录)"
echo ""
echo "  说明: Shadowrocket 的路由规则不会被本程序改写;"
echo "        若「路由覆盖」为红,请在 Shadowrocket 配置里为"
echo "        claude.ai / anthropic.com 添加代理规则。"
echo "=================================="
read -n 1 -s -r -p "按任意键关闭窗口..."
