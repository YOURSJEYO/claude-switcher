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
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango

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


DISPLAY_NAMES = ("代理内核", "TUN 网卡", "出口 IP", "IP 与上次一致", "时区", "地区格式", "IPv6 关闭",
                 "DNS 走隧道", "WebRTC", "保镖在线", "规则置顶", "客户端语言", "ASN 属性", "生态可达性")
ICONS = ("system-run", "network-wired", "network-server", "emblem-ok", "appointment-soon",
         "preferences-desktop-locale", "changes-prevent", "edit-find", "network-wireless",
         "security-high", "view-list", "preferences-desktop-font", "network-workgroup", "network-transmit-receive")
BASIS = {"时区": "原脚本读取 timedatectl 的 Timezone，与安装时的 TZ_TARGET 比较。此项不读取 /etc/timezone。",
         "地区": "原脚本优先使用 GNOME 地区格式；未设置时使用 LANG，与 LOCALE_TARGET 匹配。"}


def styled(widget, *classes):
    for cls in classes:
        widget.get_style_context().add_class(cls)
    return widget


def icon(name, size=Gtk.IconSize.MENU):
    return Gtk.Image.new_from_icon_name(name + "-symbolic", size)


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
        self.window.set_default_size(520, 810)
        self.window.connect("delete-event", self.hide_window)
        styled(self.window, "monitor")
        css = Gtk.CssProvider()
        css.load_from_path(str(Path(__file__).with_name("monitor.css")))
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.window.set_titlebar(Gtk.HeaderBar(show_close_button=True))
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.window.add(scroll)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=15)
        scroll.add(body)
        brand = Gtk.Box(spacing=10)
        body.pack_start(brand, False, False, 0)
        brand.pack_start(styled(icon("security-high", Gtk.IconSize.LARGE_TOOLBAR), "brand"), False, False, 0)
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER)
        titles.add(styled(Gtk.Label(label="Claude 账号切换器", xalign=0), "app-title"))
        titles.add(styled(Gtk.Label(label="安全检查 · 切换 · 启动", xalign=0), "secondary"))
        brand.pack_start(titles, True, True, 0)
        self.button = styled(Gtk.Button(image=icon("view-refresh")), "tool")
        self.button.set_tooltip_text("重新运行 14 项检查")
        self.button.connect("clicked", self.refresh)
        brand.pack_start(self.button, False, False, 0)
        about = styled(Gtk.Button(image=icon("help-about")), "tool")
        about.set_tooltip_text("查看时区与地区的判定依据")
        about.connect("clicked", self.show_basis)
        brand.pack_end(about, False, False, 0)
        heading = Gtk.Box()
        body.add(heading)
        heading.pack_start(styled(Gtk.Label(label="环境检查"), "section"), False, False, 0)
        self.summary = styled(Gtk.Label(), "badge", "pending")
        heading.pack_end(self.summary, False, False, 0)
        installed = BASE / "claude-switch.sh"
        self.core = installed if installed.is_file() else Path(__file__).with_name("claude-switch.sh")
        table = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL), "card")
        body.add(table)
        self.labels = {}
        for key, name, glyph in zip(CHECKS, DISPLAY_NAMES, ICONS):
            line = styled(Gtk.Box(spacing=9), "check-line")
            if key != CHECKS[-1]:
                styled(line, "check-divider")
            table.add(line)
            line.pack_start(styled(icon(glyph), "glyph"), False, False, 0)
            line.pack_start(styled(Gtk.Label(label=name), "check-name"), False, False, 0)
            detail = styled(Gtk.Label(xalign=1, hexpand=True), "detail")
            detail.set_ellipsize(Pango.EllipsizeMode.END)
            detail.set_width_chars(8)
            line.pack_start(detail, True, True, 0)
            state = Gtk.Label(label="·", width_chars=2)
            line.pack_end(state, False, False, 0)
            self.labels[key] = state, detail
        proxy = styled(Gtk.Box(spacing=9, margin_top=2), "card", "check-line")
        proxy.pack_start(styled(icon("network-server"), "glyph"), False, False, 0)
        proxy.pack_start(Gtk.Label(label="代理客户端"), False, False, 0)
        self.proxy = styled(Gtk.Label(label="检查中"), "detail")
        proxy.pack_end(self.proxy, False, False, 0)
        body.add(proxy)
        slots = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6), "card")
        body.add(slots)
        slots.add(styled(Gtk.Label(label="桌面账号", xalign=0, margin_top=4), "section"))
        buttons = Gtk.Box(spacing=8, homogeneous=True, margin_bottom=5)
        slots.add(buttons)
        for slot, hint in (("A", "现有配置"), ("B", "独立配置")):
            button = styled(Gtk.Button(label=f"账号 {slot}\n{hint}"), "slot")
            if slot == "A":
                styled(button, "primary")
            button.set_sensitive(self.core == installed)
            button.set_tooltip_text(f"重新安检并启动账号 {slot}")
            button.connect("clicked", self.open_slot, slot)
            buttons.add(button)
        footer = Gtk.Box(spacing=8)
        body.add(footer)
        self.stamp = styled(Gtk.Label(xalign=0), "secondary")
        footer.pack_start(self.stamp, True, True, 0)
        footer.pack_end(styled(Gtk.Label(label="Linux Desktop Beta"), "secondary"), False, False, 0)
        if self.core != installed:
            body.add(Gtk.Label(label="独立监测 · 完整保护尚未配置"))
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

    def show_basis(self, *_):
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True, buttons=Gtk.ButtonsType.CLOSE,
                                   text="时区与地区如何判断")
        dialog.format_secondary_text("\n\n".join(BASIS.values()))
        dialog.run()
        dialog.destroy()

    def open_slot(self, _, slot):
        # The terminal preserves the core's refusal message and normal launch checks.
        script = 'bash "$1" desktop "$2" || read -r -p "按回车关闭…"'
        args = ("bash", "-c", script, "claude-switch", str(self.core), slot)
        try:
            app = Gio.AppInfo.create_from_commandline(" ".join(GLib.shell_quote(arg) for arg in args),
                                                      "Claude Code", Gio.AppInfoCreateFlags.NEEDS_TERMINAL)
            app.launch([], None)
        except GLib.Error:
            self.stamp.set_text("未能打开终端，请从应用菜单打开终端启动。")

    def badge(self, text, tone):
        style = self.summary.get_style_context()
        for cls in ("pending", "warn", "fail"):
            style.remove_class(cls)
        if tone:
            style.add_class(tone)
        self.summary.set_text(text)

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
        self.badge("检查中…", "pending")
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
            symbol = {"ok": "✔", "warn": "▲", "fail": "✖", "skip": "–", "unknown": "?"}[state]
            label.set_markup(f'<span foreground="{COLORS[state]}" weight="bold">{symbol}</span>')
            label.set_tooltip_text(STATES[state])
            label.get_accessible().set_name(STATES[state])
            if state == "ok" and not detail:
                detail = {"时区": "系统时区匹配", "地区": "地区格式匹配"}.get(key, "")
            explanation.set_text(detail)
            explanation.set_tooltip_text("\n".join(filter(None, (detail, BASIS.get(key)))))
        proxy_detail = rows.get("代理内核", ("unknown", ""))[1]
        self.proxy.set_text(proxy_detail or "未取得")
        result = "  ·  ".join(f"{count} {STATES[state]}" for state, count in counts.items() if count)
        if counts["fail"] or counts["unknown"]:
            self.badge("需要处理", "fail")
        elif counts["warn"] or counts["skip"]:
            self.badge("环境有提示", "warn")
        else:
            self.badge("环境安全", "")
        self.summary.set_tooltip_text(result)
        self.menu_status.set_label(result)
        failed = [name for name in CHECKS if rows.get(name, ("unknown",))[0] in ("fail", "unknown")]
        brief = "、".join(failed[:3]) + (" 等" if len(failed) > 3 else "")
        self.menu_detail.set_label("需处理：" + brief if brief else "查看 14 项详情")
        now = datetime.datetime.now().strftime("%H:%M:%S")
        self.stamp.set_text(f"{now}   ·   {result}")
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
