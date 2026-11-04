#!/bin/bash
# Install the monitoring UI without changing accounts, network settings or daemons.
set -eu
dir="$(cd "$(dirname "$0")" && pwd)"
dest="${XDG_DATA_HOME:-$HOME/.local/share}/claude-switcher"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
autostart="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
bin="$HOME/.local/bin"
# Check GTK before replacing launchers on upgrade.
"/usr/bin/python3" -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk'
mkdir -p "$dest" "$apps" "$autostart" "$bin"
install -m 644 "$dir"/{monitor.py,claude-switch.sh,stun-probe.py} "$dest/"
cat > "$bin/claude-switch-monitor" <<'ENTRY'
#!/bin/sh
exec /usr/bin/python3 "${XDG_DATA_HOME:-$HOME/.local/share}/claude-switcher/monitor.py" "$@"
ENTRY
chmod +x "$bin/claude-switch-monitor"
# The shell expands ~ inside the command, including when HOME contains spaces.
cat > "$apps/claude-switcher.desktop" <<'ENTRY'
[Desktop Entry]
Type=Application
Name=Claude 切换器
Comment=查看 Linux 环境监测与 Claude 保护状态
Exec=/bin/bash -c "exec ~/.local/bin/claude-switch-monitor"
Icon=security-medium-symbolic
Terminal=false
Categories=Utility;
ENTRY
sed 's|claude-switch-monitor"|claude-switch-monitor --background"|' "$apps/claude-switcher.desktop" > "$autostart/claude-switcher.desktop"
desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [ -d "$desktop_dir" ] && [ "$desktop_dir" != "$HOME" ]; then
    install -m755 "$apps/claude-switcher.desktop" "$desktop_dir/claude-switcher.desktop"
    gio set "$desktop_dir/claude-switcher.desktop" metadata::trusted true 2>/dev/null || true
fi
if ! /usr/bin/python3 -c 'import runpy,sys; sys.exit(runpy.run_path(sys.argv[1], run_name="monitor_probe")["Indicator"] is None)' "$dest/monitor.py"; then
    echo "未检测到托盘绑定。Ubuntu 可安装 gir1.2-ayatanaappindicator3-0.1；监测窗口仍可使用。"
fi
echo "监测界面已安装。应用菜单打开「Claude 切换器」，下次登录自动驻留。"
