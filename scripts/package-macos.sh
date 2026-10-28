#!/bin/bash
# Claude 切换器 - macOS 打包脚本（本地与 CI 共用）
# 用法: bash scripts/package-macos.sh [版本号]
# 产物: build/ClaudeSwitcher-<版本>-macos-<架构>.zip
#       build/ClaudeSwitcher-<版本>-macos-<架构>.dmg
#       build/ClaudeSwitcher-<版本>-installer-kit.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.0.0-dev}"
case "$VERSION" in
    ''|*[!0-9A-Za-z._-]*)
        echo "✗ 版本号只能包含字母、数字、点、下划线和连字符: $VERSION" >&2
        exit 1
        ;;
esac

APP_NAME="Claude切换器"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  ARCH_LABEL="arm64" ;;
    x86_64) ARCH_LABEL="x86_64" ;;
    *)      ARCH_LABEL="$ARCH" ;;
esac
ZIP="$BUILD/ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-app-only.zip"
DMG="$BUILD/ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-app-only.dmg"
KIT_NAME="ClaudeSwitcher-$VERSION"
KIT_ZIP="$BUILD/ClaudeSwitcher-$VERSION-installer-kit.zip"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-package.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$BUILD"
rm -rf "$APP" "$ZIP" "$DMG" "$KIT_ZIP"

echo "==> 编译 $APP_NAME $VERSION ($ARCH_LABEL)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -warnings-as-errors \
    -target "$ARCH-apple-macos13.0" \
    "$ROOT/app/main.swift" \
    -o "$APP/Contents/MacOS/ClaudeSwitcher" \
    -framework SwiftUI -framework AppKit

echo "==> 生成图标"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for SZ in 16 32 128 256 512; do
    sips -z "$SZ" "$SZ" "$ROOT/assets/icon-2048.png" \
        --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
    sips -z $((SZ * 2)) $((SZ * 2)) "$ROOT/assets/icon-2048.png" \
        --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 写入 Info.plist"
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
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSUIElement</key><true/>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if codesign --force --deep -s - "$APP" >/dev/null 2>&1; then
    echo "✓ ad-hoc 签名完成"
else
    echo "⚠️ ad-hoc 签名失败，继续打包"
fi

NOTE="$WORK/安装说明.txt"
cat > "$NOTE" <<'NOTE_EOF'
这是仅包含 macOS 界面 App 的安装包，不含核心脚本与守护进程。

首次使用请下载 installer-kit.zip，解压后双击 installer/安装.command。
若已安装过核心脚本，可把本 App 拖入「应用程序」覆盖旧版界面。

未安装核心脚本时，App 会提示「还差一步：安装核心脚本」并提供下载入口。
NOTE_EOF

echo "==> 生成 macOS zip(app-only)"
APP_STAGE="$WORK/appstage"
mkdir -p "$APP_STAGE"
ditto "$APP" "$APP_STAGE/$APP_NAME.app"
cp "$NOTE" "$APP_STAGE/安装说明.txt"
ditto -c -k --norsrc --noextattr "$APP_STAGE" "$ZIP"

echo "==> 生成 DMG(app-only)"
DMG_STAGE="$WORK/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
cp "$NOTE" "$DMG_STAGE/安装说明.txt"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> 生成 installer kit"
KIT_ROOT="$WORK/$KIT_NAME"
mkdir -p "$KIT_ROOT"
for FILE in README.md README.en.md AGENTS.md SECURITY.md LICENSE; do
    cp "$ROOT/$FILE" "$KIT_ROOT/"
done
for DIR in core daemons installer app; do
    ditto "$ROOT/$DIR" "$KIT_ROOT/$DIR"
done
mkdir -p "$KIT_ROOT/assets" "$KIT_ROOT/docs"
cp "$ROOT/assets/icon-2048.png" "$KIT_ROOT/assets/"
cp "$ROOT/docs/screenshot.png" "$KIT_ROOT/docs/"
chmod +x "$KIT_ROOT/installer/安装.command" "$KIT_ROOT/installer/卸载.command"
for ITEM in \
    README.md README.en.md AGENTS.md SECURITY.md LICENSE \
    core/claude-switch.sh daemons/claude-bodyguard.sh installer/安装.command \
    app/main.swift assets/icon-2048.png docs/screenshot.png; do
    if [ ! -e "$KIT_ROOT/$ITEM" ]; then
        echo "✗ installer kit 缺少 $ITEM" >&2
        exit 1
    fi
done
ditto -c -k --keepParent --norsrc --noextattr "$KIT_ROOT" "$KIT_ZIP"

echo ""
echo "✓ 打包完成:"
for FILE in "$ZIP" "$DMG" "$KIT_ZIP"; do
    [ -f "$FILE" ] || { echo "✗ 缺少产物 $FILE" >&2; exit 1; }
    printf '  %-58s %8s\n' "$(basename "$FILE")" "$(du -h "$FILE" | cut -f1)"
done
