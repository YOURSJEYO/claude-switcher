#!/usr/bin/python3
"""Linux session monitor. The shell backend owns the checks and launch policy."""
import datetime
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading

import gi

gi.Repository.get_default().prepend_search_path(str(Path.home() / ".local/lib/girepository-1.0"))
gi.require_version("Gtk", "3.0")
from gi.repository import Gio, GLib, Gtk

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as Indicator
except (ValueError, ImportError):
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as Indicator
    except (ValueError, ImportError):
        Indicator = None

CHECKS = ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
          "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性")
STATES = {"ok": "通过", "warn": "警告", "fail": "失败", "skip": "跳过", "unknown": "未取得"}
COLORS = {"ok": "#26815b", "warn": "#ab6500", "fail": "#c13d37", "skip": "#777777", "unknown": "#777777"}
PRIVACY = re.compile(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)")
BASE = Path.home() / ".claude-switcher"
APP_ID = "io.github.YOURSJEYO.ClaudeSwitcher"


def parse_report(output):
    rows = {}
    for line in output.splitlines():
        key, _, value = line.partition("=")
        state, _, detail = value.partition(":")
        if key in CHECKS and state in STATES and key not in rows:
            rows[key] = state, PRIVACY.sub("•••", detail)
    return rows


class Monitor(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.window = None
        self.child = None
        self.indicator = None

    def do_command_line(self, command):
        if self.window is None:
            self.build()
            self.refresh()
            GLib.timeout_add_seconds(120, self.periodic)
        if "--background" in command.get_arguments() and self.indicator:
            GLib.timeout_add_seconds(5, self.show_if_no_tray)
        else:
            self.present()
        return 0

    def show_if_no_tray(self):
        if not self.indicator.get_property("connected"):
            self.present()
        return False

    def present(self, *_):
        self.window.show_all()
        self.window.present()

    def build(self):
        self.window = Gtk.ApplicationWindow(application=self, title="Claude 切换器 · Linux")
        self.window.set_default_size(500, 640)
        self.window.connect("delete-event", self.hide_window)
        header = Gtk.HeaderBar(title="Claude 切换器", subtitle="Linux Desktop Beta", show_close_button=True)
        self.window.set_titlebar(header)
        self.button = Gtk.Button(label="重新检查")
        self.button.connect("clicked", self.refresh)
        header.pack_end(self.button)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=18)
        self.window.add(body)
        title = Gtk.Label(xalign=0)
        title.set_markup('<span size="x-large" weight="bold">环境监测</span>')
        body.pack_start(title, False, False, 0)
        self.summary = Gtk.Label(xalign=0)
        body.pack_start(self.summary, False, False, 0)
        installed = BASE / "claude-switch.sh"
        self.core = installed if installed.is_file() else Path(__file__).with_name("claude-switch.sh")
        distro = GLib.get_os_info("PRETTY_NAME") or "Linux"
        mode = "已配置核心" if self.core == installed else "独立监测 · 参考目标 US / 纽约 · 保护未配置"
        body.pack_start(Gtk.Label(label=f"{distro}   ·   {mode}", xalign=0), False, False, 0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        body.pack_start(scroll, True, True, 0)
        grid = Gtk.Grid(column_spacing=18, row_spacing=10, margin=12)
        scroll.add(grid)
        self.labels = {}
        for i, key in enumerate(CHECKS):
            name = Gtk.Label(label=key, xalign=0)
            state = Gtk.Label(label="待检查", xalign=0)
            detail = Gtk.Label(xalign=0, hexpand=True, wrap=True)
            grid.attach(name, 0, i, 1, 1)
            grid.attach(state, 1, i, 1, 1)
            grid.attach(detail, 2, i, 1, 1)
            self.labels[key] = state, detail
        footer = Gtk.Box(spacing=12)
        body.pack_start(footer, False, False, 0)
        self.stamp = Gtk.Label(label="每 2 分钟自动检查", xalign=0, hexpand=True)
        footer.pack_start(self.stamp, True, True, 0)
        quit_button = Gtk.Button(label="退出")
        quit_button.connect("clicked", lambda *_: self.quit())
        footer.pack_end(quit_button, False, False, 0)
        self.menu_status = Gtk.MenuItem(label="环境监测 · 尚未检查")
        self.menu_status.connect("activate", self.present)
        self.menu_detail = Gtk.MenuItem(label="等待首轮检查")
        self.menu_detail.connect("activate", self.present)
        if Indicator:
            menu = Gtk.Menu()
            menu.append(self.menu_status)
            menu.append(self.menu_detail)
            menu.append(Gtk.SeparatorMenuItem())
            for label, action in (("打开监测窗口", self.present), ("重新检查", self.refresh),
                                  ("退出切换器", lambda *_: self.quit())):
                item = Gtk.MenuItem(label=label)
                item.connect("activate", action)
                menu.append(item)
            menu.show_all()
            self.indicator = Indicator.Indicator.new("claude-switcher", "security-medium-symbolic",
                                                    Indicator.IndicatorCategory.APPLICATION_STATUS)
            self.indicator.set_title("Claude 切换器")
            self.indicator.set_menu(menu)
            self.indicator.set_status(Indicator.IndicatorStatus.ACTIVE)
        body.show_all()

    def hide_window(self, *_):
        if self.indicator and self.indicator.get_property("connected"):
            self.window.hide()
            return True
        self.quit()
        return True

    def periodic(self):
        self.refresh()
        return True

    def refresh(self, *_):
        if self.child:
            return
        self.summary.set_text("正在检查 14 项环境指标…")
        self.menu_status.set_label("环境监测 · 检查中…")
        self.button.set_sensitive(False)
        try:
            self.child = subprocess.Popen(["bash", str(self.core), "monitor-check"], stdout=subprocess.PIPE,
                                          stderr=subprocess.DEVNULL, text=True, errors="replace",
                                          start_new_session=True)
        except OSError:
            self.finish({}, "无法运行监测核心")
            return
        threading.Thread(target=self.collect, args=(self.child,), daemon=True).start()

    def collect(self, child):
        try:
            output, _ = child.communicate(timeout=90)
            reason = "" if child.returncode == 0 else "检查进程异常退出"
        except subprocess.TimeoutExpired:
            self.stop_child(child)
            output, _ = child.communicate()
            reason = "检查超时"
        GLib.idle_add(self.finish, parse_report(output), reason)

    @staticmethod
    def stop_child(child):
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def finish(self, rows, reason):
        self.child = None
        self.button.set_sensitive(True)
        counts = {state: 0 for state in STATES}
        for key, (label, explanation) in self.labels.items():
            state, detail = rows.get(key, ("unknown", reason or "没有返回结果"))
            counts[state] += 1
            label.set_markup(f'<span foreground="{COLORS[state]}" weight="bold">{STATES[state]}</span>')
            explanation.set_text(detail)
        result = "  ·  ".join(f"{count} {STATES[state]}" for state, count in counts.items() if count)
        self.summary.set_text(result)
        self.menu_status.set_label(result)
        failed = [name for name in CHECKS if rows.get(name, ("unknown",))[0] in ("fail", "unknown")]
        brief = "、".join(failed[:3]) + (" 等" if len(failed) > 3 else "")
        self.menu_detail.set_label("需处理：" + brief if brief else "查看 14 项详情")
        now = datetime.datetime.now().strftime("%H:%M:%S")
        self.stamp.set_text(f"最近检查 {now}   ·   每 2 分钟刷新")
        if self.indicator:
            icon = "security-low" if counts["fail"] or counts["unknown"] else (
                "security-medium" if counts["warn"] or counts["skip"] else "security-high")
            self.indicator.set_icon_full(icon + "-symbolic", result)
        return False

    def do_shutdown(self):
        if self.child and self.child.poll() is None:
            self.stop_child(self.child)
        Gtk.Application.do_shutdown(self)


if __name__ == "__main__":
    sys.exit(Monitor().run(sys.argv))
