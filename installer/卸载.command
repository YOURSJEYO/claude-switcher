#!/bin/bash
clear
echo "=============================="
echo "  Claude 账号切换器 - 卸载"
echo "=============================="
echo ""
sudo launchctl bootout system/local.claude-bodyguard 2>/dev/null
sudo launchctl bootout system/local.tz-watchdog 2>/dev/null
sudo rm -f /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist
rm -rf "$HOME/Desktop/Claude切换器.app"
rm -f "$HOME/.local/bin/claude-switch.sh" "$HOME/.local/bin/claude-bodyguard.sh" "$HOME/.local/bin/tz-watchdog.sh" "$HOME/.local/bin/local.claude-bodyguard.plist" "$HOME/.local/bin/local.tz-watchdog.plist"
echo ""
echo "✅ 已卸载。"
echo "注意: 账号存档保留在 ~/.claude-switcher/(含你的登录态),要删干净可手动: rm -rf ~/.claude-switcher"
echo "Shadowrocket 的配置与规则未被本程序修改,无需清理。"
echo ""
read -n 1 -s -r -p "按任意键关闭窗口..."
