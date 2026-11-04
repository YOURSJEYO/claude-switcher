#!/usr/bin/python3
"""Linux session monitor. The shell backend owns the checks and launch policy."""
from collections import deque
import datetime
import ipaddress
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
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango

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
TRAY_ICON = "claude-switcher-shield-symbolic"
APP_ID = "io.github.YOURSJEYO.ClaudeSwitcher"


def mask_egress(detail):
    address, separator, region = detail.partition("/")
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return PRIVACY.sub("•••", detail)
    if ip.version == 4:
        first, _, _, last = address.split(".")
        visible = f"{first}.….{last}"
    else:
        groups = ip.exploded.split(":")
        visible = f"{int(groups[0], 16):x}:…:{int(groups[-1], 16):x}"
    return visible + separator + region


def parse_report(output):
    rows = {}
    for line in output.splitlines():
        key, _, value = line.partition("=")
        state, _, detail = value.partition(":")
        if key not in CHECKS:
            continue
        if key in rows:
            rows[key] = "fail", "检测输出存在重复项"
        elif state not in ("ok", "warn", "skip", "fail"):
            rows[key] = "fail", "检测状态无效"
        else:
            rows[key] = state, detail if key == "出口IP" else PRIVACY.sub("•••", detail)
    return rows


NOTICE_SECTIONS = (
    ('Full-Tunnel 全流量接管',
     '基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。'),
    ('Environment Audit 环境一致性审计',
     '每次启动前执行 14 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。硬性安全项失败即 Block-on-Fail；仅显式配置的非关键项可跳过或降级，skip 不表示通过。'),
    ('Kill-Switch 断网急停',
     '常驻守护进程以 10 秒周期巡检隧道健康度，隧道中断即刻终止受保护进程，将裸连窗口压缩到秒级。进程级急停，非防火墙级保证，边界详见 SECURITY.md。'),
    ('Pinned Routing 域名置顶路由',
     '目标服务全家族域名及其生态依赖（Turnstile 人机验证、Telemetry 遥测、Payment 支付、Support 组件）置顶锁定代理路由，优先级高于任何第三方分流规则集，免疫规则库误判。'),
    ('Session Isolation 会话隔离快照',
     '多账号采用完整快照隔离：各账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换即物理交换数据卷，账号间零交叉污染。'),
    ('Proxy Watchdog 代理健康巡检',
     '内置保镖以 10 秒周期检查代理内核与 TUN 状态，异常时请求关闭受保护的 Claude 进程；不自动修改系统时区或客户端配置。'),
    ('Privacy Boundary 隐私边界',
     '界面仅展示脱敏后的出口信息，诊断日志只包含检查状态与必要的脱敏摘要，不包含出口 IP、账号数据或凭据。'),
)

DISPLAY_NAMES = ("代理内核", "TUN 网卡", "出口 IP", "IP 与上次一致", "时区", "地区格式", "IPv6 关闭",
                 "DNS 走隧道", "WebRTC", "保镖在线", "规则置顶", "客户端语言", "ASN 属性", "生态可达性")
# Linux equivalents of the SF Symbols used by the macOS check rows.
ROW_PATHS = {
    "代理内核": "M6 6h12v12H6z M9 9h6v6H9z M9 3v3m6-3v3M9 18v3m6-3v3M3 9h3m-3 6h3m12-6h3m-3 6h3",
    "TUN网卡": "M9 8h6v8H9z M10 5h4v3h-4z M12 16v5",
    "出口IP": "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M5 7l4-1 2 3-3 2 1 3-4-2 M12 13l4-2 3 3-3 1-1 4-2-3z",
    "IP一致": "M12 2l3 2 3 .5 1.5 3 2 3-1.5 3-.5 3-3 1.5-3 2-3-1.5-3-.5-1.5-3-2-3 1.5-3 .5-3 3-1.5z M8 12l3 3 5-6",
    "时区": "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M12 6v6H7",
    "地区": "M5 21V4c5-3 9 4 15 0v10c-6 4-10-3-15 0",
    "IPv6": "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M15 8c-6-3-8 9-2 8 5-1 2-7-3-4",
    "DNS": "M16 10a6 6 0 1 1-12 0 6 6 0 0 1 12 0z M15 15l6 6",
    "WebRTC": "M2 3l20 18 M3 9l-2 3s5 7 11 7c2 0 4-1 5-2 M7 6c6-3 12 1 16 6l-3 3 M9 10a4 4 0 0 0 5 6",
    "保镖": "M7 13V6a1.5 1.5 0 0 1 3 0v6-8a1.5 1.5 0 0 1 3 0v8-7a1.5 1.5 0 0 1 3 0v7-5a1.5 1.5 0 0 1 3 0v8c0 7-8 9-11 4l-4-6c-1-2 1-3 3 0z",
    "规则置顶": "M3 5l2-1v5 M3 13q4-3 3 0l-3 4h4 M10 6h11m-11 6h11m-11 6h11",
    "客户端语言": "M1 17l3-10 3 10m-5-3h4 M10 7v10h3q5-1 0-5 4-4 0-5z M22 8q-6-4-6 4t6 4",
    "ASN属性": "M2 8l10-6 10 6z M5 10v8m4-8v8m6-8v8m4-8v8M3 19h18M2 22h20",
    "生态可达性": "M12 13v8 M13.5 11a1.5 1.5 0 1 1-3 0 1.5 1.5 0 1 1 3 0z M8 7q-3 4 0 8m8-8q3 4 0 8M5 4q-5 7 0 14m14-14q5 7 0 14",
    "代理客户端": "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M12 3q-9 9 0 18 9-9 0-18z M3 12h18 M5 7q7 4 14 0M5 17q7-4 14 0",
}
BASIS = {"时区": "原脚本读取 timedatectl 的 Timezone，与安装时的 TZ_TARGET 比较。此项不读取 /etc/timezone。",
         "地区": "原脚本优先使用 GNOME 地区格式；未设置时使用 LANG，与 LOCALE_TARGET 匹配。"}


def styled(widget, *classes):
    for cls in classes:
        widget.get_style_context().add_class(cls)
    return widget


def icon(name, size=Gtk.IconSize.MENU):
    return Gtk.Image.new_from_icon_name(name + "-symbolic", size)


def header_icon(path, color, size, fill="none"):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24">'
           f'<path d="{path}" fill="{fill}" stroke="{color}" stroke-width="1.8" '
           'stroke-linecap="round" stroke-linejoin="round"/></svg>')
    return Gtk.Image.new_from_pixbuf(svg_pixbuf(svg))


def svg_pixbuf(svg):
    stream = Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(svg.encode()))
    return GdkPixbuf.Pixbuf.new_from_stream(stream, None)


def row_icon(key):
    image = styled(header_icon(ROW_PATHS[key], "#756e67", 14), "glyph")
    image.set_valign(Gtk.Align.CENTER)
    return image


def status_pixbuf(state):
    color = COLORS[state]
    shape, mark = {
        "ok": ('<circle cx="12" cy="12" r="10"/>', 'M7 12l3.5 3.5 6-7'),
        "warn": ('<path d="M10.4 3.6q1.6-3 3.2 0l8 15q1 2-1.5 2h-16q-2.5 0-1.5-2z"/>', 'M12 8v5m0 3v.4'),
        "fail": ('<path d="M8 2h8l6 6v8l-6 6H8l-6-6V8z"/>', 'M8 8l8 8m0-8-8 8'),
        "skip": ('<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/>', 'M8 12h8'),
        "unknown": ('<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/>', 'M9 9q0-4 4-3 5 2 0 6l-1 1m0 3v.4'),
    }[state]
    ink = color if state in ("skip", "unknown") else "white"
    return svg_pixbuf(f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" '
                      f'color="{color}" fill="{color}">{shape}<path d="{mark}" fill="none" stroke="{ink}" '
                      'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>')


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

    def present_from_tray(self, *_):
        # Wayland can ignore present() on a mapped background window when the
        # indicator forwards its activation over D-Bus without a focus token.
        target = next((w for w in Gtk.Window.list_toplevels()
                       if w.get_transient_for() == self.window and w.get_visible() and w.get_modal()), self.window)
        target.deiconify()
        if target.get_mapped() and not target.is_active():
            target.hide()
        def restore():
            self.window.show_all()
            target.show_all()
            target.present()
            return False
        GLib.idle_add(restore)

    def build(self):
        self.window = Gtk.ApplicationWindow(application=self, title="Claude 切换器 · Linux")
        self.window.set_default_size(520, 907)
        self.window.connect("delete-event", self.hide_window)
        styled(self.window, "monitor")
        css = Gtk.CssProvider()
        css.load_from_path(str(Path(__file__).with_name("monitor.css")))
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.window.set_titlebar(Gtk.HeaderBar(show_close_button=True))
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.window.add(layout)
        layout.pack_start(scroll, True, True, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=15)
        scroll.add(body)
        brand = Gtk.Box(spacing=8)
        body.pack_start(brand, False, False, 0)
        shield_svg = Path(__file__).with_name(TRAY_ICON + ".svg").read_text()
        white_shield = svg_pixbuf(shield_svg.replace("#2e3436", "white"))
        shield = Gtk.Image.new_from_pixbuf(white_shield.scale_simple(20, 20, GdkPixbuf.InterpType.BILINEAR))
        shield.set_valign(Gtk.Align.CENTER)
        brand.pack_start(styled(shield, "brand"), False, False, 0)
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER)
        titles.add(styled(Gtk.Label(label="Claude 账号切换器", xalign=0), "app-title"))
        titles.add(styled(Gtk.Label(label="安全检查 · 切换 · 启动", xalign=0), "secondary"))
        brand.pack_start(titles, True, True, 0)
        pulse = header_icon("M2 12h5l2-8 4 16 3-11 2 3h4", "#665e58", 17)
        self.button = styled(Gtk.Button(image=pulse), "tool")
        self.button.set_tooltip_text("设备指纹体检（字体、GPU、虚拟化）")
        self.button.connect("clicked", self.show_fingerprint)
        self.button.set_valign(Gtk.Align.CENTER)
        brand.pack_start(self.button, False, False, 0)
        gear = styled(Gtk.Button(image=icon("emblem-system")), "tool")
        gear.set_tooltip_text("检查设置")
        gear.connect("clicked", self.settings)
        gear.set_valign(Gtk.Align.CENTER)
        brand.pack_start(gear, False, False, 0)
        about = styled(Gtk.Button(image=icon("dialog-information")), "tool")
        about.set_tooltip_text("安全防护体系公告")
        about.connect("clicked", self.show_notice)
        about.set_valign(Gtk.Align.CENTER)
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
        self.status_icons = {state: status_pixbuf(state) for state in STATES}
        for key, name in zip(CHECKS, DISPLAY_NAMES):
            line = styled(Gtk.Box(spacing=9), "check-line")
            if key != CHECKS[-1]:
                styled(line, "check-divider")
            table.add(line)
            line.pack_start(row_icon(key), False, False, 0)
            line.pack_start(styled(Gtk.Label(label=name), "check-name"), False, False, 0)
            detail = styled(Gtk.Label(xalign=1, hexpand=True), "detail")
            detail.set_ellipsize(Pango.EllipsizeMode.END)
            detail.set_width_chars(8)
            line.pack_start(detail, True, True, 0)
            state = Gtk.Image.new_from_pixbuf(self.status_icons["unknown"])
            state.get_accessible().set_name("待检查")
            line.pack_end(state, False, False, 0)
            self.labels[key] = state, detail
        proxy = styled(Gtk.Box(spacing=9, margin_top=2), "card", "check-line")
        proxy.pack_start(row_icon("代理客户端"), False, False, 0)
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
        self.stamp = styled(Gtk.Label(xalign=0), "secondary")
        body.pack_end(self.stamp, False, False, 0)
        footer = styled(Gtk.Box(spacing=4), "footer")
        layout.pack_end(footer, False, False, 0)
        footer.pack_start(icon("security-high"), False, False, 0)
        note = styled(Gtk.Label(label="硬性安全项必须通过；灰色跳过不表示检查通过", xalign=0), "secondary")
        note.set_line_wrap(True)
        footer.pack_start(note, True, True, 0)
        self.update_button = styled(Gtk.Button(label="检查更新"), "footer-action")
        self.update_button.set_tooltip_text("检查上游版本，不更改已安装的文件")
        self.update_button.connect("clicked", lambda *_: self.start_update(True))
        footer.add(self.update_button)
        handoff = styled(Gtk.Button(label="AI 配置"), "footer-action")
        handoff.set_tooltip_text("查看和复制 AI 交接提示词")
        handoff.connect("clicked", self.show_handoff)
        footer.add(handoff)
        if self.core != installed:
            body.add(Gtk.Label(label="独立监测 · 完整保护尚未配置"))
        self.menu_status = Gtk.MenuItem(label="环境监测 · 尚未检查")
        self.menu_status.connect("activate", self.present_from_tray)
        self.menu_detail = Gtk.MenuItem(label="等待首轮检查")
        self.menu_detail.connect("activate", self.present_from_tray)
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
            for label, action in (("打开主窗口", self.present_from_tray), ("重新检查", self.refresh)):
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
            self.indicator = Indicator.Indicator.new_with_path(
                "claude-switcher", TRAY_ICON, Indicator.IndicatorCategory.APPLICATION_STATUS,
                str(Path(__file__).resolve().parent))
            self.indicator.set_title("Claude 切换器")
            self.indicator.set_menu(menu)
            self.indicator.set_status(Indicator.IndicatorStatus.ACTIVE)
        body.show_all()

    def show_handoff(self, *_):
        prompt = """这是「Claude 切换器」Linux 版的 AI 交接提示词。请先阅读仓库根目录的 AGENTS.md 和 linux/README.md，再开始安装、配置或排障。

仓库地址：https://github.com/YOURSJEYO/claude-switcher

1. 先确认 Linux 发行版、代理客户端和 TUN 状态。完整安装后，使用 ~/.local/bin/claude-switch checkdetail 运行 14 项检查。硬性安全项必须通过；只有明确配置的非关键项可跳过或降为警告。skip 表示未执行。
2. 分别核对有效时区和地区格式。时区读取 timedatectl，GNOME 地区格式读取 org.gnome.system.locale 的 region 设置。启动前还须确认出口国家与配置目标一致。
3. 桌面账号有 A–D 四个槽位。A 使用现有配置，B–D 分别使用独立配置。切换前提醒我保存工作，由切换器安检并等待旧会话退出。保留 ~/.claude-switcher/accounts/ 的存档结构。
4. Linux 保镖使用 systemd 用户服务 claude-bodyguard.service。用 systemctl --user is-active claude-bodyguard.service 检查状态。
5. 检查更新只运行 ~/.local/bin/claude-switch update-check。安装、覆盖已安装版本、修改代理或系统设置前，请说明影响并取得我的同意。
6. 诊断只记录检查项和状态。日志、文档和回复中不得暴露出口 IP、代理地址、账号数据或凭据。"""
        dialog, box = self.sheet("AI 交接提示词", "复制后粘贴给本地 AI，让它先读 AGENTS.md 再动手", (600, 450))
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        card = styled(Gtk.Box(), "prompt-card")
        box.pack_start(card, True, True, 0)
        card.pack_start(scroll, True, True, 0)
        scroll.set_shadow_type(Gtk.ShadowType.NONE)
        view = styled(Gtk.TextView(editable=False, wrap_mode=Gtk.WrapMode.WORD_CHAR,
                                   monospace=True, cursor_visible=False, pixels_below_lines=2), "prompt")
        view.get_buffer().set_text(prompt)
        scroll.add(view)
        copy = styled(Gtk.Button(label="复制", image=icon("edit-copy"), always_show_image=True,
                                 halign=Gtk.Align.START), "copy-prompt")

        def copy_prompt(button):
            clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            clipboard.set_text(prompt, -1)
            clipboard.store()
            button.set_label("已复制")

        copy.connect("clicked", copy_prompt)
        box.pack_end(copy, False, False, 0)
        dialog.show_all()
        dialog.run()
        dialog.destroy()

    def show_fingerprint(self, *_):
        devices = []
        for path in sorted(Path("/sys/class/drm").glob("card[0-9]*/device")):
            driver = path / "driver"
            if driver.is_symlink():
                devices.append(driver.resolve().name)
        try:
            virt = subprocess.run(["systemd-detect-virt"], capture_output=True, text=True, timeout=2).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            virt = ""
        fonts = len(self.window.get_pango_context().list_families())
        self.message("设备指纹体检", f"字体族：{fonts}\nGPU 驱动：{'、'.join(devices) or '未识别'}\n虚拟化：{virt or '未知'}")

    def sheet(self, title, subtitle, size):
        dialog = Gtk.Dialog(title=title, transient_for=self.window, modal=True)
        styled(dialog, "monitor")
        dialog.set_default_size(*size)
        styled(dialog, "handoff")
        header = styled(Gtk.HeaderBar(show_close_button=False), "handoff-header")
        heading = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        heading.add(styled(Gtk.Label(label=title, xalign=0), "handoff-title"))
        heading.add(styled(Gtk.Label(label=subtitle, xalign=0), "secondary"))
        header.pack_start(heading)
        cross = icon("window-close")
        cross.set_pixel_size(12)
        cross.set_halign(Gtk.Align.CENTER)
        cross.set_valign(Gtk.Align.CENTER)
        close = styled(Gtk.Button(image=cross), "handoff-close")
        close.set_valign(Gtk.Align.CENTER)
        close.get_accessible().set_name("关闭")
        close.connect("clicked", lambda *_: dialog.response(Gtk.ResponseType.CLOSE))
        header.pack_end(close)
        dialog.set_titlebar(header)
        box = dialog.get_content_area()
        box.set_border_width(20)
        box.set_spacing(10)
        return dialog, box

    def show_notice(self, *_):
        dialog, box = self.sheet("安全防护体系公告", "Security Architecture Bulletin", (510, 620))
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        box.pack_start(scroll, True, True, 0)
        sections = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        scroll.add(sections)

        def paragraph(text):
            label = styled(Gtk.Label(label=text, xalign=0, wrap=True), "notice-text")
            label.set_max_width_chars(52)
            return label

        sections.add(paragraph('本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。'))
        for index, (title, text) in enumerate(NOTICE_SECTIONS, 1):
            card = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5), "notice-card")
            card.add(styled(Gtk.Label(label=f"{index}. {title}", xalign=0), "notice-title"))
            card.add(paragraph(text))
            sections.add(card)
        sections.add(paragraph('本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。'))
        sections.add(paragraph("以上为项目原版公告。Linux 桌面账号使用独立配置目录，实际保护状态请以本机检查结果为准。"))
        dialog.show_all()
        dialog.run()
        dialog.destroy()

    def slot_text(self):
        return "当前账号（最近请求）：" + (self.last_slot if self.last_slot in tuple("ABCD") else "尚无记录")

    def update_slots(self):
        try:
            slot = (BASE / "desktop-last").read_text().strip()
            if slot not in tuple("ABCD"):
                slot = None
        except FileNotFoundError:
            slot = ""
        except (OSError, UnicodeError):
            slot = None
        if slot != self.last_slot:
            self.last_slot = slot
            if hasattr(self, "account_item"):
                self.account_item.set_label(self.slot_text())
            for key, button in self.slot_buttons.items():
                style = button.get_style_context()
                hint = "现有配置" if key == "A" else "独立配置"
                if key == slot:
                    style.add_class("primary")
                    hint = "最近请求"
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
        self.update_button.set_label("检查中…")
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
        self.update_button.set_label("检查更新")
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
            try:
                run = subprocess.run(["bash", str(self.core), "set-check-config", json.dumps(config)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     text=True, timeout=10)
                failed = run.returncode != 0
            except (OSError, subprocess.SubprocessError):
                failed = True
            if failed:
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
        self.badge("检查中", "pending")
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
            label.set_from_pixbuf(self.status_icons[state])
            label.set_tooltip_text(STATES[state])
            label.get_accessible().set_name(STATES[state])
            if state == "ok" and not detail:
                detail = {"时区": "系统时区匹配", "地区": "地区格式匹配"}.get(key, "")
            if key == "出口IP":
                masked = mask_egress(detail)
                explanation.set_text(masked)
                explanation.get_parent().set_tooltip_text(masked)
            else:
                explanation.set_text(detail)
                explanation.set_tooltip_text("\n".join(filter(None, (detail, BASIS.get(key)))))
        proxy_detail = rows.get("代理内核", ("unknown", ""))[1]
        self.proxy.set_text(proxy_detail or "未取得")
        result = "  ·  ".join(f"{count} {STATES[state]}" for state, count in counts.items() if count)
        self.update_slots()
        if self.last_slot is None:
            reason = reason or "无法读取账号状态"
        if reason or counts["fail"] or counts["unknown"]:
            self.badge("检查未过", "fail")
        else:
            self.badge("环境安全", "")
        self.summary.set_tooltip_text(reason or result)
        self.menu_status.set_label("最近检查：" + result)
        self.latest = {key: rows.get(key, ("unknown",))[0] for key in CHECKS}
        self.record_history(self.latest)
        failed = [name for name in CHECKS if rows.get(name, ("unknown",))[0] in ("fail", "unknown")]
        brief = "、".join(failed[:3]) + (" 等" if len(failed) > 3 else "")
        self.menu_detail.set_label("需处理：" + brief if brief else "查看 14 项详情")
        now = datetime.datetime.now().strftime("%H:%M:%S")
        self.stamp.set_text(f"{now}   ·   {result}")
        if self.indicator:
            self.indicator.set_icon_full(TRAY_ICON, result)
        return False

    def record_history(self, latest):
        # Keep subprocesses off the GTK main loop; history append returns on idle.
        def task():
            try:
                logging = bool(self.config().get("logging"))
            except (OSError, ValueError, subprocess.SubprocessError):
                return
            if not logging:
                return
            entry = datetime.datetime.now().isoformat(timespec="seconds") + " " + \
                " ".join(f"{key}={state}" for key, state in latest.items())
            GLib.idle_add(self.append_history, entry)
        threading.Thread(target=task, daemon=True).start()

    def append_history(self, entry):
        self.history.append(entry)
        return False

    def do_shutdown(self):
        if self.child and self.child.poll() is None:
            self.stop_child(self.child)
        Gtk.Application.do_shutdown(self)


if __name__ == "__main__":
    sys.exit(Monitor().run(sys.argv))
