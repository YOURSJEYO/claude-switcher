#!/usr/bin/python3
"""Linux session monitor. The shell backend owns the checks and launch policy."""
from collections import deque
import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import tempfile
import zipfile

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
        self.history = deque(maxlen=200)
        self.latest = {}
        self.checking_update = False

    def do_command_line(self, command):
        if self.window is None:
            self.build()
            self.refresh()
            GLib.timeout_add_seconds(120, self.periodic)
            GLib.timeout_add_seconds(12 * 3600, self.scheduled_update)
            self.start_update(False)
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
        self.window.set_default_size(520, 885)
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
        buttons = Gtk.Grid(column_spacing=8, row_spacing=8, column_homogeneous=True, margin_bottom=5)
        self.slot_buttons = {}
        slots.add(buttons)
        for i, slot in enumerate("ABCD"):
            hint = "现有配置" if slot == "A" else "独立配置"
            button = styled(Gtk.Button(label=f"账号 {slot}\n{hint}"), "slot")
            button.set_sensitive(self.core == installed)
            button.set_tooltip_text(f"通过安检后退出当前 Claude 桌面与 Code CLI 会话，并启动账号 {slot}")
            button.connect("clicked", self.open_slot, slot)
            buttons.attach(button, i % 2, i // 2, 1, 1)
            self.slot_buttons[slot] = button
        self.last_slot = None
        self.update_slots()
        GLib.timeout_add_seconds(2, self.update_slots)
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
        self.account_item = Gtk.MenuItem(label=self.slot_text())
        self.account_item.set_sensitive(False)
        self.update_item = Gtk.MenuItem(label="检查更新")
        self.update_item.connect("activate", lambda *_: self.start_update(True))
        if Indicator:
            menu = Gtk.Menu()
            title_item = Gtk.MenuItem(label="Claude 切换器")
            title_item.set_sensitive(False)
            for item in (title_item, self.account_item, self.menu_status, self.menu_detail, Gtk.SeparatorMenuItem()):
                menu.append(item)
            for label, action in (("打开主窗口", self.present), ("重新检查", self.refresh)):
                item = Gtk.MenuItem(label=label)
                item.connect("activate", action)
                menu.append(item)
            menu.append(self.update_item)
            for label, action in (("检查设置", self.settings), ("导出诊断日志", self.export_log)):
                item = Gtk.MenuItem(label=label)
                item.connect("activate", action)
                menu.append(item)
            menu.append(Gtk.SeparatorMenuItem())
            quit_item = Gtk.MenuItem(label="退出 Claude 切换器")
            quit_item.connect("activate", lambda *_: self.quit())
            menu.append(quit_item)
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

    def slot_text(self):
        return "当前账号（最近启动）：" + (self.last_slot if self.last_slot in tuple("ABCD") else "尚无记录")

    def update_slots(self):
        try:
            slot = (BASE / "desktop-last").read_text().strip()
        except OSError:
            slot = ""
        if slot != self.last_slot:
            self.last_slot = slot
            if hasattr(self, "account_item"):
                self.account_item.set_label(self.slot_text())
            for key, button in self.slot_buttons.items():
                style = button.get_style_context()
                hint = "现有配置" if key == "A" else "独立配置"
                if key == slot:
                    style.add_class("primary")
                    hint = "最近启动"
                else:
                    style.remove_class("primary")
                button.set_label(f"账号 {key}\n{hint}")
        return True

    def message(self, title, text):
        self.present()
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True, buttons=Gtk.ButtonsType.CLOSE, text=title)
        dialog.format_secondary_text(text)
        dialog.run()
        dialog.destroy()

    def scheduled_update(self):
        self.start_update(False)
        return True

    def start_update(self, interactive):
        self.show_update_result = interactive or (self.checking_update and self.show_update_result)
        if self.checking_update:
            return
        self.checking_update = True
        self.update_item.set_label("正在检查更新…")
        threading.Thread(target=self.fetch_update, daemon=True).start()

    def fetch_update(self):
        try:
            run = subprocess.run(["bash", str(self.core), "update-check"], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True, timeout=95)
            result = run.stdout.strip() or "更新检查未返回结果"
        except (OSError, subprocess.TimeoutExpired):
            result = "无法完成更新检查，请稍后重试"
        GLib.idle_add(self.finish_update, result)

    def finish_update(self, result):
        self.checking_update = False
        self.update_item.set_label("检查更新 · " + ("有差异" if "版本不同" in result else
                                  "已是最新" if "最新版本" in result else "未能确认"))
        if self.show_update_result:
            self.message("检查更新", result)
        return False

    def config(self):
        raw = subprocess.check_output(["bash", str(self.core), "get-check-config"], text=True,
                                      stderr=subprocess.DEVNULL, timeout=5)
        return json.loads(raw)

    def settings(self, *_):
        try:
            config = self.config()
        except (OSError, ValueError, subprocess.SubprocessError):
            self.message("检查设置", "配置无法读取，未修改现有设置。")
            return
        self.present()
        dialog = Gtk.Dialog(title="检查设置", transient_for=self.window, modal=True)
        dialog.add_buttons("取消", Gtk.ResponseType.CANCEL, "保存", Gtk.ResponseType.OK)
        box = dialog.get_content_area()
        box.set_border_width(16)
        box.set_spacing(6)
        box.add(Gtk.Label(label="可选检查 · 关闭后显示为跳过", xalign=0))
        toggles = {}
        for key in ("IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "生态可达性"):
            control = Gtk.CheckButton(label=key)
            control.set_active(key not in config["disabled"])
            toggles[key] = control
            box.add(control)
        warn = Gtk.CheckButton(label="将上述可选检查的失败显示为警告")
        warn.set_active(config["allowOptionalFailures"])
        box.add(warn)
        logging = Gtk.CheckButton(label="保留本次运行的脱敏检查历史")
        logging.set_active(config["logging"])
        box.add(logging)
        dialog.show_all()
        if dialog.run() == Gtk.ResponseType.OK:
            config.update(disabled=[k for k, v in toggles.items() if not v.get_active()],
                          allowOptionalFailures=warn.get_active(), logging=logging.get_active())
            run = subprocess.run(["bash", str(self.core), "set-check-config", json.dumps(config)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if run.returncode:
                self.message("检查设置", "保存失败，请检查配置和目录权限。")
            else:
                if not config["logging"]:
                    self.history.clear()
                self.refresh()
        dialog.destroy()

    def export_log(self, *_):
        self.present()
        chooser = Gtk.FileChooserDialog(title="导出诊断日志", transient_for=self.window,
                                        action=Gtk.FileChooserAction.SAVE)
        chooser.add_buttons("取消", Gtk.ResponseType.CANCEL, "导出", Gtk.ResponseType.OK)
        chooser.set_current_name("claude-switcher-diagnostics.zip")
        chooser.set_do_overwrite_confirmation(True)
        dest = chooser.get_filename() if chooser.run() == Gtk.ResponseType.OK else None
        chooser.destroy()
        if not dest:
            return
        tmp = None
        try:
            config = self.config()
            with tempfile.NamedTemporaryFile(dir=Path(dest).parent, delete=False) as handle:
                tmp = handle.name
            with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as archive:
                for name, data in (("checks", config), ("recent-status", self.latest),
                                   ("environment", {"platform": "Linux", "app": "Claude Switcher"})):
                    archive.writestr(name + ".json", json.dumps(data, ensure_ascii=False, indent=2))
                archive.writestr("client.log", "\n".join(self.history) if config["logging"] else "")
            os.replace(tmp, dest)
            self.message("诊断日志已导出", dest)
        except (OSError, ValueError, subprocess.SubprocessError):
            self.message("导出失败", "未能保存诊断文件。")
        finally:
            if tmp:
                Path(tmp).unlink(missing_ok=True)

    def open_slot(self, _, slot):
        # The terminal preserves the core's refusal message and normal launch checks.
        script = 'bash "$1" desktop-switch "$2" || read -r -p "按回车关闭…"'
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
        self.menu_status.set_label("最近检查：" + result)
        self.latest = {key: rows.get(key, ("unknown",))[0] for key in CHECKS}
        try:
            if self.config()["logging"]:
                self.history.append(datetime.datetime.now().isoformat(timespec="seconds") + " " +
                                    " ".join(f"{key}={state}" for key, state in self.latest.items()))
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
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
