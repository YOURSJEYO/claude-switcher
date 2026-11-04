#!/bin/bash
# Claude 保镖 (Linux) —— 代理离线时自动关闭 claude CLI 与当前用户的 claude-desktop 进程
# 安装器会把 __PROXY_MODE__ 替换为安装时识别的客户端;未替换(旧装)时按 Clash 内核判定,行为与旧版一致
LOG="$HOME/.claude-switcher/bodyguard.log"
MODE="__PROXY_MODE__"

while true; do
    ok=1
    # TUN 在线判定:fake-ip 网段优先,通用虚拟网卡(tun/utun/wg/tailscale 且 UP)兜底(WireGuard 无 fake-ip)
    if ! ip addr 2>/dev/null | grep -q 'inet 198\.18\.'; then
        ip link show 2>/dev/null | grep -E '^[0-9]+: (tun|utun|wg|tailscale)[0-9]*:' | grep -q 'UP' || ok=0
    fi
    # 内核在线判定:按安装时识别的客户端分派
    case "$MODE" in
        clash-verge) pgrep -f 'verge-mihomo|mihomo' >/dev/null 2>&1 || ok=0 ;;
        mihomo)      pgrep -f mihomo >/dev/null 2>&1 || ok=0 ;;
        sing-box)    pgrep -f sing-box >/dev/null 2>&1 || ok=0 ;;
        v2raya)      pgrep -f v2raya >/dev/null 2>&1 || ok=0 ;;
        nekobox)     pgrep -f 'nekobox|nekoray' >/dev/null 2>&1 || ok=0 ;;
        hiddify)     pgrep -f hiddify >/dev/null 2>&1 || ok=0 ;;
        wireguard)   systemctl list-units --type=service --state=active 'wg-quick@*' 2>/dev/null | grep -q 'wg-quick@' || ok=0 ;;
        other|auto)  : ;;  # other/auto 只查虚拟网卡(启发式,避免误杀)
        *)           pgrep -f 'verge-mihomo|mihomo' >/dev/null 2>&1 || ok=0 ;;
    esac
    if [ "$ok" -eq 0 ] && pgrep -x claude >/dev/null 2>&1; then
        pkill -x claude
        echo "$(date '+%Y-%m-%d %H:%M:%S') 代理离线(内核或TUN丢失),已自动关闭 claude CLI" >>"$LOG"
    fi
    if [ "$ok" -eq 0 ]; then
        pkill -u "$(id -u)" -x claude-desktop 2>/dev/null && echo "$(date) 代理离线，已请求关闭 Claude 桌面版" >>"$LOG"
    fi
    sleep 10
done
