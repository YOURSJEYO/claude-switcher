import SwiftUI
import AppKit
import Combine

// MARK: - 模型

enum RowState { case pending, ok, warn, fail }

struct CheckRow: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var state: RowState = .pending
    var detail: String = ""
}

enum Phase { case checking, ready, failed, switching, done, fixing }
enum NetStatus { case checking, safe, warn, danger }

enum EnvironmentTemplate: String, CaseIterable, Identifiable {
    case us = "US", taiwan = "TW", singapore = "SG"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .us: return "美国"
        case .taiwan: return "台湾"
        case .singapore: return "新加坡"
        }
    }
    var settings: String {
        switch self {
        case .us: return "洛杉矶时区 · 美国地区格式"
        case .taiwan: return "台北时区 · 台湾地区格式"
        case .singapore: return "新加坡时区 · 新加坡地区格式"
        }
    }
}

final class VM: ObservableObject {
    @Published var rows: [CheckRow] = [
        CheckRow(name: "代理内核", icon: "cpu"),
        CheckRow(name: "TUN 网卡", icon: "cable.connector"),
        CheckRow(name: "出口 IP", icon: "globe.americas"),
        CheckRow(name: "IP 与上次一致", icon: "checkmark.seal"),
        CheckRow(name: "时区一致", icon: "clock"),
        CheckRow(name: "地区一致", icon: "flag"),
        CheckRow(name: "IPv6 关闭", icon: "6.circle"),
        CheckRow(name: "DNS 走隧道", icon: "magnifyingglass"),
        CheckRow(name: "WebRTC", icon: "eye.slash"),
        CheckRow(name: "保镖在线", icon: "hand.raised"),
        CheckRow(name: "规则置顶", icon: "list.number"),
        CheckRow(name: "客户端语言", icon: "character.bubble"),
        CheckRow(name: "ASN 属性", icon: "network"),
        CheckRow(name: "生态可达性", icon: "link"),
    ]
    @Published var phase: Phase = .checking
    @Published var current = "?"
    @Published var hasB = false
    @Published var banner = ""
    @Published var note = ""
    @Published var netStatus: NetStatus = .checking
    var lastCheckAt = Date.distantPast
    var hasData = false
    @Published private(set) var isChecking = false
    @Published var selectedTemplate: EnvironmentTemplate = .taiwan
    @Published private(set) var currentTemplate: EnvironmentTemplate?
    @Published private(set) var templatePinned = false
    @Published private(set) var templateMessage = ""
    @Published private(set) var templateError = false
    @Published private(set) var isApplyingTemplate = false

    var isBusy: Bool { isChecking || phase == .fixing || phase == .switching }

    let core: String

    init(core: String = NSHomeDirectory() + "/.local/bin/claude-switch.sh", monitoring: Bool = true) {
        self.core = core
        guard monitoring else { return }
        // 菜单栏图标状态轮询: 10s 快检隧道, 60s 静默全量审计
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.fastCheck() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.quietCheck() }
        quietCheck()
    }

    // 快检: 内核+TUN 掉线立刻转红
    private func fastCheck() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.launchPath = "/bin/bash"
            p.arguments = ["-c", "pgrep -f verge-mihomo >/dev/null 2>&1 && ifconfig 2>/dev/null | grep -q 'inet 198\\.18\\.'"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.launch()
            p.waitUntilExit()
            let down = p.terminationStatus != 0
            DispatchQueue.main.async { if down { self.netStatus = .danger } }
        }
    }

    // 后台与手动检查共用结果，后台保留旧行直到新结果到达。
    private func quietCheck() {
        refresh(background: true)
    }

    func run(_ args: [String], timeout: TimeInterval = 45, done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let tmp = "/tmp/switcher-out-\(UUID().uuidString).txt"
            FileManager.default.createFile(atPath: tmp, contents: nil)
            let p = Process()
            p.launchPath = "/bin/bash"
            p.arguments = [self.core] + args
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: tmp)) {
                p.standardOutput = fh
                p.standardError = fh
            }
            var timedOut = false
            let watchdog = DispatchWorkItem {
                if p.isRunning { timedOut = true; p.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            do { try p.run() } catch {
                watchdog.cancel()
                if let fh = p.standardOutput as? FileHandle { try? fh.close() }
                try? FileManager.default.removeItem(atPath: tmp)
                DispatchQueue.main.async { done("FAIL:无法启动脚本 \(error.localizedDescription)") }
                return
            }
            p.waitUntilExit()
            watchdog.cancel()
            if let fh = p.standardOutput as? FileHandle { try? fh.close() }
            let data = (try? Data(contentsOf: URL(fileURLWithPath: tmp))) ?? Data()
            let out = String(decoding: data, as: UTF8.self)  // 容错解码:坏字节替换而非整体失败
            try? FileManager.default.removeItem(atPath: tmp)
            let dbg = "[\(Date())] args=\(args) timedOut=\(timedOut) exit=\(p.terminationStatus) 耗时\(String(format: "%.1f", Date().timeIntervalSince(started)))s stdout=\(out.count)字符\n"
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/switcher-debug.log")) {
                h.seekToEndOfFile(); h.write(dbg.data(using: .utf8)!); h.closeFile()
            } else { try? dbg.write(toFile: "/tmp/switcher-debug.log", atomically: true, encoding: .utf8) }
            if timedOut {
                DispatchQueue.main.async { done("FAIL:操作超时，请重试") }
                return
            }
            DispatchQueue.main.async { done(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    // 距上次检查超过 maxAge 才自动重跑; 手动按钮随时可调 refresh()
    func refreshIfStale(maxAge: TimeInterval = 60) {
        if !hasData || Date().timeIntervalSince(lastCheckAt) > maxAge { refresh() }
    }

    func refresh(background: Bool = false) {
        guard !isChecking, phase != .fixing, phase != .switching else { return }
        isChecking = true
        banner = ""
        note = ""
        if !background || !hasData {
            phase = .checking
            netStatus = .checking
            for i in rows.indices { rows[i].state = .pending; rows[i].detail = "" }
        }
        run(["checkdetail"], timeout: 60) { out in
            self.applyCheckOutput(out)
            self.run(["status"]) { st in
                self.applyStatusOutput(st)
                self.isChecking = false
            }
        }
    }

    func applyStatusOutput(_ out: String) {
        let fields = out.split(whereSeparator: { $0.isWhitespace }).reduce(into: [String: String]()) { result, word in
            let pair = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        current = fields["current"] == "B" ? "B" : (fields["current"] == "A" ? "A" : "未初始化")
        hasB = fields["hasB"] == "1"
        let detected = fields["template"].flatMap(EnvironmentTemplate.init(rawValue:))
        if let detected, currentTemplate == nil || selectedTemplate == currentTemplate {
            selectedTemplate = detected
        }
        currentTemplate = detected
        templatePinned = fields["templateMode"] == "manual"
    }

    func applySelectedTemplate() {
        guard !isBusy else { return }
        let target = selectedTemplate
        isApplyingTemplate = true
        phase = .fixing
        netStatus = .checking
        templateError = false
        templateMessage = "正在应用\(target.title)模板…"
        banner = "正在应用模板；调整时区时可能需要管理员授权"
        run(["apply-template", target.rawValue], timeout: 180) { out in
            self.isApplyingTemplate = false
            guard out == "OK:template=\(target.rawValue)" else {
                self.templateError = true
                self.templateMessage = out.hasPrefix("FAIL:") ? String(out.dropFirst(5)) : "应用失败，请重新检查系统设置"
                self.phase = .failed
                self.netStatus = .danger
                self.banner = self.templateMessage
                return
            }
            self.currentTemplate = target
            self.templatePinned = true
            self.templateMessage = "已应用\(target.title)模板；出口和环境检查见下方"
            self.phase = .checking
            self.refresh()
        }
    }

    // 仅使用本次结果；旧缓存不能替代超时、空输出或缺失的检查项。
    func applyCheckOutput(_ out: String) {
        let keyMap: [String: String] = [
            "代理内核": "代理内核", "TUN网卡": "TUN 网卡", "出口IP": "出口 IP",
            "IP一致": "IP 与上次一致", "时区": "时区一致", "地区": "地区一致",
            "IPv6": "IPv6 关闭", "DNS": "DNS 走隧道", "WebRTC": "WebRTC",
            "保镖": "保镖在线", "规则置顶": "规则置顶",
            "客户端语言": "客户端语言", "ASN属性": "ASN 属性", "生态可达性": "生态可达性",
        ]
        var updated = rows
        for i in updated.indices {
            updated[i].state = .fail
            updated[i].detail = "未收到本次检查结果，请重新检查"
        }
        var matched = Set<Int>()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let name = keyMap[parts[0]],
                  let idx = updated.firstIndex(where: { $0.name == name }) else { continue }
            let status = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let code = status.first, ["ok", "warn", "fail"].contains(code),
                  matched.insert(idx).inserted else { continue }
            updated[idx].state = code == "ok" ? .ok : (code == "warn" ? .warn : .fail)
            updated[idx].detail = status.count > 1 ? status[1] : ""
        }
        rows = updated
        hasData = matched.count == rows.count
        if hasData { lastCheckAt = Date() }
        banner = hasData ? "" : (out.hasPrefix("FAIL:") ? String(out.dropFirst(5)) :
            "检测输出不完整(\(matched.count)/\(rows.count))，请点重新检查")
        let failed = rows.contains { $0.state == .fail }
        phase = failed ? .failed : .ready
        netStatus = failed ? .danger : (rows.contains { $0.state == .warn } ? .warn : .safe)
    }

    func fixAll() {
        guard !isChecking, phase != .fixing, phase != .switching else { return }
        phase = .fixing
        banner = "正在修复…（若弹出密码框请输入开机密码）"
        run(["fix"], timeout: 180) { out in
            let steps = out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("FIX:") }.map { String($0.dropFirst(4)) }
            self.banner = steps.last ?? ""
            self.phase = .checking
            self.refresh()
        }
    }

    func switchTo(_ target: String) {
        guard !isChecking, phase == .ready, netStatus != .danger else { return }
        phase = .switching
        banner = "正在切换到账号 \(target)…"
        run(["switch", target], timeout: 180) { out in
            if out.hasPrefix("FAIL:") {
                self.phase = .failed
                self.banner = String(out.dropFirst(5))
                return
            }
            var extra = ""
            if target == "B" && !self.hasB { extra = "B 号首次使用：请在打开的 Claude 里登录 B 账号，登录一次即可。" }
            if out.hasPrefix("INFO:") { extra = "" }
            self.current = target
            self.phase = .done
            self.banner = out.hasPrefix("INFO:") ? "当前已是账号 \(target)" : "已切换到账号 \(target)"
            self.note = extra
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.refresh() }
        }
    }
}

// MARK: - 视图

struct ContentView: View {
    @ObservedObject var vm: VM
    @State private var showNotice = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.10, green: 0.07, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 16) {
                header
                templateCard
                ScrollView { checksCard }
                    .frame(maxHeight: 440)
                if vm.phase == .ready || vm.phase == .switching || vm.phase == .done {
                    accountCard
                } else if vm.phase == .failed || vm.phase == .fixing {
                    retryCard
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
        }
        .frame(width: 440, height: 740)
    }

    var templateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("地区模板").font(.callout.bold()).foregroundColor(.white)
                Spacer()
                Text(vm.currentTemplate.map {
                    "当前：\($0.title)" + (vm.templatePinned ? "" : "（按出口识别）")
                } ?? "当前：待识别")
                    .font(.caption).foregroundColor(.white.opacity(0.65))
            }
            Picker("地区模板", selection: $vm.selectedTemplate) {
                ForEach(EnvironmentTemplate.allCases) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isBusy)
            HStack {
                Text(vm.selectedTemplate.settings)
                    .font(.caption).foregroundColor(.white.opacity(0.75))
                Spacer()
                Button(vm.isApplyingTemplate ? "应用中…" : "应用模板") {
                    vm.applySelectedTemplate()
                }
                .disabled(vm.isBusy)
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            Text("先在 Clash 选择对应地区节点；模板调整系统时区与地区格式。")
                .font(.caption2).foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if !vm.templateMessage.isEmpty {
                Text(vm.templateMessage).font(.caption)
                    .foregroundColor(vm.templateError ? .red : .white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude 账号切换器").font(.title3.bold()).foregroundColor(.white)
                Text("安全检查 · 切换 · 启动").font(.caption).foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            Button { vm.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.title3).foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("重新检查")
            .disabled(vm.isChecking || vm.phase == .fixing || vm.phase == .switching)
            Button { showNotice = true } label: {
                Image(systemName: "info.circle").font(.title3).foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("安全防护体系公告")
            statusPill
        }
        .sheet(isPresented: $showNotice) { NoticeView() }
    }

    var statusPill: some View {
        let (txt, color): (String, Color) = {
            switch vm.phase {
            case .checking: return ("检查中", .orange)
            case .ready: return ("环境安全", .green)
            case .failed: return ("检查未过", .red)
            case .switching: return ("切换中", .blue)
            case .fixing: return (vm.isApplyingTemplate ? "应用中" : "修复中", .orange)
            case .done: return ("完成", .green)
            }
        }()
        return Text(txt)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    var checksCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(vm.rows.enumerated()), id: \.element.id) { idx, row in
                HStack(spacing: 10) {
                    Image(systemName: row.icon)
                        .frame(width: 20)
                        .foregroundColor(.white.opacity(0.65))
                    Text(row.name).font(.callout).foregroundColor(.white.opacity(0.9))
                    Spacer()
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.caption).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                    }
                    stateIcon(row.state)
                }
                .padding(.vertical, 7).padding(.horizontal, 12)
                if idx < vm.rows.count - 1 {
                    Divider().background(Color.white.opacity(0.08))
                }
            }
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
    }

    func stateIcon(_ s: RowState) -> some View {
        Group {
            switch s {
            case .pending: ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
            }
        }
        .font(.callout)
    }

    var accountCard: some View {
        VStack(spacing: 12) {
            if vm.phase == .switching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else if vm.phase == .done {
                VStack(spacing: 4) {
                    Label(vm.banner, systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.callout.bold())
                    if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundColor(.yellow.opacity(0.9)).multilineTextAlignment(.center) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                HStack(spacing: 6) {
                    Text("当前账号").font(.caption).foregroundColor(.white.opacity(0.5))
                    Text(vm.current).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.3)).foregroundColor(.indigo.opacity(1.4))
                        .clipShape(Capsule())
                    Spacer()
                }
                HStack(spacing: 10) {
                    accountButton("A", subtitle: vm.current == "A" ? "当前" : "已建档")
                    accountButton("B", subtitle: vm.current == "B" ? "当前" : (vm.hasB ? "已建档" : "未初始化"))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
    }

    func accountButton(_ t: String, subtitle: String) -> some View {
        Button { vm.switchTo(t) } label: {
            VStack(spacing: 4) {
                Text("账号 \(t)").font(.headline).foregroundColor(.white)
                Text(subtitle).font(.caption2).foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(
                vm.current == t
                ? LinearGradient(colors: [Color.indigo.opacity(0.6), Color.purple.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(vm.current == t ? Color.indigo : Color.white.opacity(0.1), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }

    var retryCard: some View {
        VStack(spacing: 10) {
            if vm.phase == .fixing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(.white.opacity(0.85))
                }
            } else {
                if !vm.banner.isEmpty {
                    Text(vm.banner).font(.callout).foregroundColor(.red.opacity(0.95)).multilineTextAlignment(.center)
                }
                Text("存在未通过项，可一键修复或手动处理后重试").font(.caption).foregroundColor(.white.opacity(0.6))
                HStack(spacing: 10) {
                    Button { vm.fixAll() } label: {
                        Label("一键修复", systemImage: "wand.and.stars")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { vm.refresh() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.25)))
    }

    var footer: some View {
        HStack {
            Image(systemName: "lock.shield").font(.caption2)
            Text("任何一项检查不过，都不会启动 Claude").font(.caption2)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Text("退出").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.45))
        }
        .foregroundColor(.white.opacity(0.35))
    }
}

// MARK: - 公告页

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    let sections: [(String, String)] = [
        ("Full-Tunnel 全流量接管", "基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。"),
        ("Environment Audit 环境一致性审计", "每次启动前执行 11 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。任一指标不达标即 Block-on-Fail，杜绝带病启动。"),
        ("Kill-Switch 断网急停", "常驻守护进程以 10 秒周期巡检隧道健康度，隧道中断即刻终止受保护进程，确保没有任何数据包经物理网卡直连——Zero-Egress Guarantee。"),
        ("Pinned Routing 域名置顶路由", "目标服务全家族域名及其生态依赖（Turnstile 人机验证、Telemetry 遥测、Payment 支付、Support 组件）置顶锁定代理路由，优先级高于任何第三方分流规则集，免疫规则库误判。"),
        ("Session Isolation 会话隔离快照", "多账号采用完整快照隔离：各账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换即物理交换数据卷，账号间零交叉污染。"),
        ("Drift Self-Healing 配置漂移自愈", "针对系统时区漂移、代理组件升级导致的配置重置等常见问题，内置 Watchdog 周期性校验并自动回滚至基线状态，全程留痕、可审计。"),
        ("Anti-Tracking 反追踪卫生", "验证链接（Magic Link）闭环于受保护环境内打开；邮件追踪像素（Tracking Pixel）经由邮箱服务商代理层屏蔽；全程固定单一住宅出口，不产生 Geo 跳变。"),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Color(red: 0.10, green: 0.07, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安全防护体系公告").font(.title3.bold()).foregroundColor(.white)
                        Text("Security Architecture Bulletin").font(.caption).foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(spacing: 10) {
                        Text("本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。")
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)

                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, s in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(idx + 1). \(s.0)").font(.callout.bold()).foregroundColor(.indigo.opacity(1.3))
                                Text(s.1).font(.caption).foregroundColor(.white.opacity(0.7)).lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .frame(width: 460, height: 620)
    }
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private let vm = VM()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)

        popover = NSPopover()
        popover.behavior = .transient          // 点面板外自动关闭
        popover.contentSize = NSSize(width: 440, height: 740)
        popover.contentViewController = NSHostingController(rootView: ContentView(vm: vm))

        cancellable = vm.$netStatus.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateIcon() }
        updateIcon()
    }

    // 纯像素染色图标: SF符号画进去再按 alpha 上色, isTemplate=false → 菜单栏显示真彩色
    private func icon(_ symbol: String, _ color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return false }
            let gs = glyph.size
            glyph.draw(in: NSRect(x: (18 - gs.width) / 2, y: (18 - gs.height) / 2, width: gs.width, height: gs.height))
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }

    private func updateIcon() {
        let (sym, color): (String, NSColor) = {
            switch vm.netStatus {
            case .checking: return ("shield", .systemGray)
            case .safe:     return ("checkmark.shield.fill", .systemGreen)
            case .warn:     return ("exclamationmark.shield.fill", .systemYellow)
            case .danger:   return ("xmark.shield.fill", .systemRed)
            }
        }()
        item.button?.image = icon(sym, color)
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            vm.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSStatusBar.system.removeStatusItem(item)
    }
}

// MARK: - App

@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var inserted = true

    init() {
        // 纯菜单栏附件模式: 无 Dock 图标(与 AgentMonitor 一致)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
