#!/bin/bash
# 时区看门狗 —— 按 ~/.claude-switcher/region 记录的最近出口地区映射目标时区
BASE="__HOME__/.claude-switcher"
LOG="__HOME__/Library/Logs/tz-watchdog.log"
if [ -f "$BASE/template" ]; then
    LOC=$(cat "$BASE/template")
else
    LOC=$(cat "$BASE/region" 2>/dev/null)
fi
case "$LOC" in
    US) TARGET="America/Los_Angeles" ;;
    SG) TARGET="Asia/Singapore" ;;
    TW) TARGET="Asia/Taipei" ;;
    *) exit 0 ;;
esac
current=$(readlink /etc/localtime 2>/dev/null)
if [ "$current" != "/var/db/timezone/zoneinfo/$TARGET" ]; then
    /usr/sbin/systemsetup -settimezone "$TARGET" >>"$LOG" 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') 时区异常: [$current] 已自动恢复为 $TARGET (loc=$LOC)" >>"$LOG"
fi
