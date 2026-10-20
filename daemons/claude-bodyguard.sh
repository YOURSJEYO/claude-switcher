#!/bin/bash
# Claude 保镖 (Shadowrocket 版参考模板) —— 安装程序会把 __HOME__ 替换为实际用户目录后安装
# 作用: 代理(VPN 或 TUN)离线时,自动关闭 Claude,杜绝裸连重试
LOG="__HOME__/Library/Logs/claude-bodyguard.log"
VPN_ID="com.liguangming.Shadowrocket"

ok=1
# TUN 接管判定:fake-ip 网段地址存在
ifconfig 2>/dev/null | grep -q 'inet 198\.18\.' || ok=0
# Shadowrocket 连接状态(launchd 下查不到时以 TUN 为准,避免误杀)
line=$(scutil --nc list 2>/dev/null | grep "$VPN_ID" | head -1)
if [ -n "$line" ]; then
    echo "$line" | grep -q '(Connected)' || ok=0
fi

if [ "$ok" -eq 0 ]; then
    if pgrep -f '/Applications/Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1; then
        pkill -f '/Applications/Claude.app/Contents/MacOS/Claude'
        echo "$(date '+%Y-%m-%d %H:%M:%S') 代理离线(VPN或TUN丢失),已自动关闭 Claude" >>"$LOG"
    fi
fi
