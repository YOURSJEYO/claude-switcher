#!/bin/bash
clear
echo "=============================="
echo "  Claude 账号切换器 - 卸载"
echo "=============================="
echo ""
sudo launchctl bootout system/local.claude-bodyguard 2>/dev/null
sudo launchctl bootout system/local.tz-watchdog 2>/dev/null
sudo launchctl bootout system/local.claude-update 2>/dev/null
sudo rm -f /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist /Library/LaunchDaemons/local.claude-update.plist
sudo rm -rf "/Library/Application Support/claude-switcher"
launchctl bootout "gui/$(id -u)/local.claude-update" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.claude-update.plist"
sudo rm -rf "/Applications/Claude切换器.app"
# 兼容旧版桌面安装路径。
rm -rf "$HOME/Desktop/Claude切换器.app"
rm -f "$HOME/.local/bin/claude-switch.sh" "$HOME/.local/bin/claude-bodyguard.sh" "$HOME/.local/bin/tz-watchdog.sh" "$HOME/.local/bin/local.claude-bodyguard.plist" "$HOME/.local/bin/local.tz-watchdog.plist" "$HOME/.local/bin/local.claude-update.plist" "$HOME/.local/bin/claude-switch.sh.bak" "$HOME/.local/bin/claude-bodyguard.sh.bak" "$HOME/.local/bin/tz-watchdog.sh.bak"
echo ""
echo "✅ 已卸载。"
echo "注意: 账号存档保留在 ~/.claude-switcher/(含你的登录态),要删干净可手动: rm -rf ~/.claude-switcher"
echo "置顶规则提示: 如曾在 Clash Verge 配置过置顶规则,可手动清空 全局扩展配置(Merge.yaml);其他客户端的规则请自行检查。"
echo ""
read -n 1 -s -r -p "按任意键关闭窗口..."
