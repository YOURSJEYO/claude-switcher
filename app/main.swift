import SwiftUI
import AppKit

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

struct CoreResult {
    let output: String
    let succeeded: Bool
}

struct AccountStamp: Equatable {
    let size: String
    let date: String
}

// 超时回调与 waitUntilExit 在不同队列上执行。
private final class ProcessDeadline {
    private let lock = NSLock()
    private var expired = false

    func expire(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        expired = true
        process.terminate()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}

final class VM: ObservableObject {
    @Published var rows: [CheckRow] = [
        CheckRow(name: "代理内核", icon: "cpu"),
        CheckRow(name: "TUN 网卡", icon: "cable.connector"),
        CheckRow(name: "出口 IP", icon: "globe.americas"),
        CheckRow(name: "IP 与上次一致", icon: "checkmark.seal"),
        CheckRow(name: "时区", icon: "clock"),
        CheckRow(name: "地区", icon: "flag"),
        CheckRow(name: "IPv6 关闭", icon: "6.circle"),
        CheckRow(name: "DNS 走隧道", icon: "magnifyingglass"),
        CheckRow(name: "WebRTC", icon: "eye.slash"),
        CheckRow(name: "保镖在线", icon: "hand.raised"),
        CheckRow(name: "规则置顶", icon: "list.number"),
        CheckRow(name: "客户端语言", icon: "abc"),
        CheckRow(name: "ASN 属性", icon: "building.columns"),
        CheckRow(name: "生态可达性", icon: "antenna.radiowaves.left.and.right"),
    ]
    @Published var phase: Phase = .checking
    @Published var current = "?"
    @Published var archived: Set<String> = []
    @Published var stamps: [String: AccountStamp] = [:]
    @Published var banner = ""
    @Published var note = ""
    @Published var fingerprint = ""
    @Published private(set) var isBusy = false
    @Published private(set) var lastCheckSummary = "尚未检查"
    @Published var updateText = ""
    @Published var showUpdateSheet = false
    @Published private(set) var coreMissing = false

    let core: String
    private let checkTimeout: TimeInterval
    private let operationTimeout: TimeInterval
    private var started = false
    private var switchRequested = false
    private var checkingUpdate = false
    private var hideAfterSwitch: DispatchWorkItem?
    var onSwitchCompleted: (() -> Void)?

    init(core: String = NSHomeDirectory() + "/.local/bin/claude-switch.sh",
         checkTimeout: TimeInterval = 45, operationTimeout: TimeInterval = 180) {
        self.core = core
        self.checkTimeout = checkTimeout
        self.operationTimeout = operationTimeout
    }

    var canQuit: Bool { !switchRequested && phase != .fixing && phase != .switching }

    func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    func prepareToShow() {
        hideAfterSwitch?.cancel()
        if phase == .done { phase = .ready }
    }

    private func run(_ args: [String], timeout: TimeInterval = 45, done: @escaping (CoreResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-out-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let fh = try? FileHandle(forWritingTo: tmp) else {
                DispatchQueue.main.async { done(CoreResult(output: "无法创建检查输出文件", succeeded: false)) }
                return
            }
            defer {
                try? fh.close()
                try? FileManager.default.removeItem(at: tmp)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [self.core] + args
            p.standardOutput = fh
            p.standardError = fh
            do { try p.run() } catch {
                DispatchQueue.main.async { done(CoreResult(output: "无法启动脚本：\(error.localizedDescription)", succeeded: false)) }
                return
            }
            let deadline = ProcessDeadline()
            let watchdog = DispatchWorkItem { deadline.expire(p) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            p.waitUntilExit()
            watchdog.cancel()
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let result: CoreResult
            if deadline.timedOut {
                result = CoreResult(output: "操作超时，请重试", succeeded: false)
            } else if p.terminationStatus != 0 {
                result = CoreResult(output: "脚本执行失败（退出码 \(p.terminationStatus)）\n\(out)", succeeded: false)
            } else {
                result = CoreResult(output: out, succeeded: true)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    func refresh() {
        guard !isBusy else { return }
        hideAfterSwitch?.cancel()
        if !coreAvailable() { markCoreMissing(); return }
        isBusy = true
        checkEnvironment { _ in self.isBusy = false }
    }

    private func coreAvailable() -> Bool {
        FileManager.default.isReadableFile(atPath: core)
    }

    private func markCoreMissing() {
        coreMissing = true
        phase = .failed
        lastCheckSummary = "未安装核心脚本"
        banner = "未安装核心脚本：请下载 installer-kit 安装包并双击 installer/安装.command，或运行源码安装"
        for i in rows.indices {
            rows[i].state = .fail
            rows[i].detail = "未安装核心脚本"
        }
    }

    func refreshAccountStatus() {
        // 菜单展开时只读取本地账号状态，不触发网络审计；启动审计优先。
        guard started, !isBusy else { return }
        isBusy = true
        run(["status"], timeout: checkTimeout) { result in
            self.updateStatus(result)
            self.isBusy = false
        }
    }

    private func checkEnvironment(done: @escaping (Bool) -> Void) {
        if !coreAvailable() {
            markCoreMissing()
            done(false)
            return
        }
        coreMissing = false
        phase = .checking
        lastCheckSummary = "检查中"
        banner = ""
        note = ""
        for i in rows.indices { rows[i].state = .pending; rows[i].detail = "" }
        run(["checkdetail"], timeout: checkTimeout) { result in
            var allOk = result.succeeded
            var matched = Set<Int>()
            var duplicated = false
            let keyMap: [String: String] = [
                "代理内核": "代理内核", "TUN网卡": "TUN 网卡", "出口IP": "出口 IP",
                "IP一致": "IP 与上次一致", "时区": "时区", "地区": "地区",
                "IPv6": "IPv6 关闭", "DNS": "DNS 走隧道", "WebRTC": "WebRTC",
                "保镖": "保镖在线", "规则置顶": "规则置顶",
                "客户端语言": "客户端语言", "ASN属性": "ASN 属性", "生态可达性": "生态可达性",
            ]
            for line in result.output.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let rowName = keyMap[parts[0]],
                      let idx = self.rows.firstIndex(where: { $0.name == rowName }) else { continue }
                // 重复行不能补齐缺失项，也不能用后来的 ok 覆盖先前的 fail。
                guard matched.insert(idx).inserted else { allOk = false; duplicated = true; continue }
                let status = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                switch status.first ?? "" {
                case "ok": self.rows[idx].state = .ok
                case "warn": self.rows[idx].state = .warn
                default: self.rows[idx].state = .fail; allOk = false
                }
                self.rows[idx].detail = status.count > 1 ? status[1] : ""
            }
            if !result.succeeded {
                self.banner = result.output.isEmpty ? "核心脚本执行失败" : result.output
                for i in self.rows.indices where self.rows[i].state == .pending {
                    self.rows[i].state = .fail
                    self.rows[i].detail = "核心脚本执行失败"
                }
            } else if duplicated {
                self.banner = "检测输出存在重复项，请重新检查"
            } else if matched.count != self.rows.count {
                self.banner = "检测输出不完整(\(matched.count)/\(self.rows.count))，请点重新检查"
            }
            let passed = allOk && matched.count == self.rows.count
            self.lastCheckSummary = passed ? (self.rows.contains { $0.state == .warn } ? "有警告" : "通过") : "失败"
            self.run(["status"], timeout: self.checkTimeout) { status in
                let statusOK = self.updateStatus(status)
                if !statusOK {
                    if !passed || self.banner.isEmpty {
                        self.banner = "无法读取账号状态，请重新检查"
                    }
                    self.lastCheckSummary = "失败"
                }
                self.phase = passed && statusOK ? .ready : .failed
                done(passed && statusOK)
            }
        }
    }

    @discardableResult
    private func updateStatus(_ result: CoreResult) -> Bool {
        let fields = result.output.split(whereSeparator: { $0.isWhitespace }).reduce(into: [String: String]()) { values, field in
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        func reset() -> Bool {
            current = "未知"; archived = []; stamps = [:]
            return false
        }
        guard result.succeeded, let account = fields["current"],
              ["A", "B", "C", "D", "none"].contains(account) else {
            return reset()
        }
        var known = Set<String>()
        if let list = fields["accounts"] {
            if list != "none" {
                for piece in list.split(separator: ",", omittingEmptySubsequences: true) {
                    let letter = String(piece)
                    guard Self.accountLetters.contains(letter) else { return reset() }
                    known.insert(letter)
                }
            }
        } else {
            // 旧版核心只输出 current/hasA/hasB,继续兼容已安装的旧脚本。
            for letter in ["A", "B"] {
                guard let flag = fields["has\(letter)"], ["0", "1"].contains(flag) else { return reset() }
                if flag == "1" { known.insert(letter) }
            }
        }
        var parsed: [String: AccountStamp] = [:]
        for letter in Self.accountLetters {
            guard let raw = fields["acc\(letter)"] else { continue }
            let parts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return reset() }
            parsed[letter] = AccountStamp(size: String(parts[0]), date: String(parts[1]))
        }
        current = account == "none" ? "未初始化" : account
        stamps = parsed
        archived = known
        return true
    }

    static let accountLetters = ["A", "B", "C", "D"]

    func fixAll() {
        guard !isBusy else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        hideAfterSwitch?.cancel()
        isBusy = true
        phase = .fixing
        banner = "正在修复…（若弹出密码框请输入开机密码）"
        run(["fix"], timeout: operationTimeout) { result in
            guard result.succeeded else {
                self.banner = result.output; self.phase = .failed; self.isBusy = false
                return
            }
            self.checkEnvironment { _ in self.isBusy = false }
        }
    }

    func inspectFingerprint() {
        guard !isBusy else { return }
        isBusy = true
        fingerprint = "正在体检…"
        run(["fingerprint"], timeout: 90) { result in
            self.fingerprint = result.output
            self.isBusy = false
        }
    }

    func checkUpdate() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        updateText = "正在检查更新…"
        run(["update-check"], timeout: 120) { result in
            self.updateText = result.output.isEmpty
                ? (result.succeeded ? "检查完成，核心脚本没有返回结果" : "检查失败，请重试")
                : result.output
            self.checkingUpdate = false
        }
    }

    var aiPrompt: String {
        let home = NSHomeDirectory()
        let agents = home + "/.claude-switcher/AGENTS.md"
        let agentsLine = FileManager.default.fileExists(atPath: agents)
            ? "本机交接文档：\(agents)"
            : "本机交接文档：\(agents)（~/.claude-switcher 不存在或其中没有 AGENTS.md，请从仓库根目录读取 AGENTS.md）"
        return """
        这是「Claude 切换器」的 AI 交接提示词。请先完整阅读交接文档，再开始安装、配置或排障。

        仓库地址：https://github.com/YOURSJEYO/claude-switcher
        \(agentsLine)

        执行要求：
        1. 先读 AGENTS.md，按其中的安装步骤、验收标准与安全红线执行，不要只凭本段提示词猜测。
        2. 安装或排障时先跑环境审计：14 项检查全部通过才算就绪；任何一项不过都不要启动 Claude。
        3. 账号切换前先完全退出 Claude；账号快照按 AGENTS.md 的规则保留，不要改动 ~/.claude-switcher/accounts/ 的结构。
        4. 保镖等常驻脚本只放在 root 所有的系统目录，不要改回用户可写路径；需要变更时引导我重跑安装器。
        5. 不要未经我明确同意更新、覆盖或重装已安装版本（~/.local/bin、桌面 App、launchd 与系统目录），也不要执行 update 或安装器；先说明影响并征得同意。
        6. 检查新版本只运行 `~/.local/bin/claude-switch.sh update-check`，看到结果后先问我是否执行更新。
        7. 不要在日志、文档或回复里暴露我的出口 IP、代理地址或任何凭据。
        """
    }

    func switchTo(_ target: String) {
        guard !isBusy, Self.accountLetters.contains(target) else { return }
        hideAfterSwitch?.cancel()
        isBusy = true
        switchRequested = true
        // 常驻后旧检查可能已经过期。每次切换都重新审计，不使用落盘的旧结果放行。
        checkEnvironment { passed in
            guard passed else {
                self.switchRequested = false; self.isBusy = false
                return
            }
            self.performSwitch(target)
        }
    }

    private func performSwitch(_ target: String) {
        phase = .switching
        banner = "正在切换到账号 \(target)…"
        run(["switch", target], timeout: operationTimeout) { [self] result in
            let lines = result.output.split(separator: "\n").map(String.init)
            let failure = lines.first { $0.hasPrefix("FAIL:") }
            let success = lines.contains { $0.hasPrefix("OK:") || $0.hasPrefix("INFO:") }
            guard result.succeeded, failure == nil, success else {
                self.phase = .failed
                self.banner = failure.map { String($0.dropFirst(5)) } ?? (result.output.isEmpty ? "切换未返回成功结果，请重新检查" : result.output)
                self.switchRequested = false; self.isBusy = false
                return
            }
            var extra = ""
            if target != "A" && !self.archived.contains(target) {
                extra = "\(target) 号首次使用：请在打开的 Claude 里登录 \(target) 账号，登录一次即可。"
            }
            let unchanged = lines.contains { $0.hasPrefix("INFO:") }
            if unchanged { extra = "" }
            self.current = target
            self.phase = .done
            self.banner = unchanged ? "当前已是账号 \(target)" : "已切换到账号 \(target)"
            self.note = extra
            self.switchRequested = false; self.isBusy = false
            let hide = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .done, !self.isBusy else { return }
                self.onSwitchCompleted?()
                self.phase = .ready
            }
            self.hideAfterSwitch = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: hide)
        }
    }
}

// MARK: - Claude 风格外观

enum ClaudeTheme {
    // 纸感暖色基底 (Warm Parchment / Alabaster)
    static let bgTop = Color(red: 0.984, green: 0.976, blue: 0.961)         // #FAF9F5
    static let bgBottom = Color(red: 0.957, green: 0.945, blue: 0.925)      // #F4F1EC
    static let card = Color.white                                           // #FFFFFF
    static let cardBorder = Color(red: 0.898, green: 0.882, blue: 0.855)   // #E5E1DA
    static let divider = Color(red: 0.941, green: 0.929, blue: 0.910)      // #F0ECE8
    static let iconWell = Color(red: 0.965, green: 0.953, blue: 0.937)     // #F6F3EF

    // 字体色阶 (Editorial Ink & Warm Stone)
    static let ink = Color(red: 0.165, green: 0.153, blue: 0.141)          // #2A2724
    static let muted = Color(red: 0.455, green: 0.435, blue: 0.412)        // #746F69

    // Claude 标志性陶土橙 (Anthropic Claude Terracotta)
    static let terracotta = Color(red: 0.847, green: 0.447, blue: 0.329)   // #D87254
    static let terracottaDeep = Color(red: 0.761, green: 0.369, blue: 0.259) // #C25E42
    static let terracottaTint = Color(red: 0.847, green: 0.447, blue: 0.329).opacity(0.09)

    // 自然柔和状态色
    static let success = Color(red: 0.180, green: 0.490, blue: 0.322)       // #2E7D52 (Sage Green)

    static let warning = Color(red: 0.722, green: 0.431, blue: 0.094)       // #B86E18 (Warm Amber)
    static let warningBorder = Color(red: 0.961, green: 0.863, blue: 0.718) // #F5DCB7

    static let error = Color(red: 0.761, green: 0.282, blue: 0.212)         // #C24836 (Claude Terracotta Red)
}

// MARK: - Claude 优雅背景

struct ClaudeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ClaudeTheme.bgTop, ClaudeTheme.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [ClaudeTheme.terracotta.opacity(0.04), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 辅助样式组件

struct ClaudeIconButton: View {
    let systemName: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovered ? ClaudeTheme.ink : ClaudeTheme.muted)
                .frame(width: 28, height: 28)
                .background(isHovered ? ClaudeTheme.iconWell : ClaudeTheme.card.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 7.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 7.5)
                        .stroke(isHovered ? ClaudeTheme.cardBorder : ClaudeTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(help)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 视图

struct ContentView: View {
    @ObservedObject var vm: VM
    var height: CGFloat = 900
    @State private var showNotice = false
    @State private var showFingerprint = false
    @State private var showAIPrompt = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 12) {
                header
                HStack {
                    Text("环境检查").font(.caption.weight(.semibold)).foregroundColor(ClaudeTheme.muted)
                    Spacer()
                    statusPill
                }
                // 小屏上窗口高度会被系统可见区域压缩,让卡片区可滚动而不是被裁切
                ScrollView {
                    VStack(spacing: 16) {
                        checksCard
                        if vm.phase == .ready || vm.phase == .switching || vm.phase == .done {
                            accountCard
                        } else if vm.coreMissing {
                            setupCard
                        } else if vm.phase == .failed || vm.phase == .fixing {
                            retryCard
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                footer
            }
            .padding(16)
        }
        .sheet(isPresented: $showAIPrompt) { AIPromptSheet(text: vm.aiPrompt) }
        .frame(width: 440, height: height)
        .preferredColorScheme(.light)
    }

    var header: some View {
        HStack(spacing: 11) {
            // Claude 风格陶土盾牌徽标
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: ClaudeTheme.terracotta.opacity(0.24), radius: 3.5, x: 0, y: 1.5)

                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude 账号切换器")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundColor(ClaudeTheme.ink)
                Text("安全检查 · 切换 · 启动")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(ClaudeTheme.muted)
            }

            Spacer()

            ClaudeIconButton(
                systemName: "waveform.path.ecg",
                help: "设备指纹体检(字体/GPU/虚拟机)",
                disabled: vm.isBusy
            ) {
                showFingerprint = true
                vm.inspectFingerprint()
            }

            ClaudeIconButton(
                systemName: "info.circle",
                help: "安全防护体系公告"
            ) {
                showNotice = true
            }

        }
        .sheet(isPresented: $showNotice) { NoticeView() }
        .sheet(isPresented: $showFingerprint) { FingerprintView(text: vm.fingerprint) }
    }

    var statusPill: some View {
        let (txt, color): (String, Color) = {
            switch vm.phase {
            case .checking: return ("检查中", ClaudeTheme.terracottaDeep)
            case .ready: return ("环境安全", ClaudeTheme.success)
            case .failed: return ("检查未过", ClaudeTheme.error)
            case .switching: return ("切换中", ClaudeTheme.terracottaDeep)
            case .fixing: return ("修复中", ClaudeTheme.terracottaDeep)
            case .done: return ("完成", ClaudeTheme.success)
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
                    // 左侧图标容器
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ClaudeTheme.iconWell)
                            .frame(width: 24, height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(ClaudeTheme.divider, lineWidth: 0.5)
                            )
                        Image(systemName: row.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(ClaudeTheme.muted)
                    }

                    Text(row.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ClaudeTheme.ink)

                    Spacer(minLength: 8)

                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11.5, weight: .regular, design: isMonospace(row.detail) ? .monospaced : .default))
                            .foregroundColor(row.state == .warn ? ClaudeTheme.warning : ClaudeTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    stateIcon(row.state)
                }
                .padding(.vertical, 5.5)
                .padding(.horizontal, 12)

                if idx < vm.rows.count - 1 {
                    Divider()
                        .overlay(ClaudeTheme.divider)
                        .padding(.leading, 46)
                }
            }
        }
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(ClaudeTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color(red: 0.2, green: 0.16, blue: 0.12).opacity(0.035), radius: 6, x: 0, y: 2)
    }

    private func isMonospace(_ str: String) -> Bool {
        str.contains(".") || str.contains(":") || str.contains("/")
    }

    func stateIcon(_ s: RowState) -> some View {
        Group {
            switch s {
            case .pending: ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(ClaudeTheme.success)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(ClaudeTheme.warning)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundColor(ClaudeTheme.error)
            }
        }
        .font(.callout)
    }

    var accountCard: some View {
        VStack(spacing: 12) {
            if vm.phase == .switching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.ink)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else if vm.phase == .done {
                VStack(spacing: 4) {
                    Label(vm.banner, systemImage: "checkmark.circle.fill").foregroundColor(ClaudeTheme.success).font(.callout.bold())
                    if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundColor(ClaudeTheme.warning).multilineTextAlignment(.center) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                HStack(spacing: 6) {
                    Text("当前账号").font(.caption).foregroundColor(ClaudeTheme.muted)
                    Text(vm.current).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(ClaudeTheme.terracottaTint).foregroundColor(ClaudeTheme.terracottaDeep)
                        .clipShape(Capsule())
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(VM.accountLetters, id: \.self) { t in
                        accountButton(t, subtitle: accountSubtitle(t))
                    }
                }
            }
        }
        .padding(12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }

    func accountSubtitle(_ t: String) -> String {
        if vm.current == t { return "当前" }
        guard vm.archived.contains(t) else { return "未初始化" }
        guard let stamp = vm.stamps[t] else { return "已建档" }
        return "已建档 · \(stamp.size) · \(shortDate(stamp.date))"
    }

    func shortDate(_ value: String) -> String {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4 else { return value }
        return "\(parts[1])-\(parts[2])"
    }

    func accountButton(_ t: String, subtitle: String) -> some View {
        Button { vm.switchTo(t) } label: {
            VStack(spacing: 4) {
                Text("账号 \(t)").font(.headline).foregroundColor(vm.current == t ? .white : ClaudeTheme.ink)
                Text(subtitle).font(.caption2).foregroundColor(vm.current == t ? .white.opacity(0.9) : ClaudeTheme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(
                vm.current == t
                ? LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [ClaudeTheme.iconWell, ClaudeTheme.iconWell], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(vm.current == t ? ClaudeTheme.terracotta : ClaudeTheme.cardBorder, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
    }

    var setupCard: some View {
        VStack(spacing: 10) {
            Text("还差一步：安装核心脚本").font(.callout.bold()).foregroundColor(ClaudeTheme.ink)
            Text(vm.banner).font(.caption).foregroundColor(ClaudeTheme.muted).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { openURL("https://github.com/YOURSJEYO/claude-switcher/releases/latest") } label: {
                    Label("打开下载页", systemImage: "arrow.down.circle")
                        .font(.callout.bold())
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { openURL("https://github.com/YOURSJEYO/claude-switcher#安装") } label: {
                    Label("安装说明", systemImage: "book")
                        .font(.callout.bold())
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(ClaudeTheme.iconWell)
                        .foregroundColor(ClaudeTheme.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(ClaudeTheme.error.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.error.opacity(0.25)))
    }

    private func openURL(_ text: String) {
        if let url = URL(string: text) { NSWorkspace.shared.open(url) }
    }

    var retryCard: some View {
        VStack(spacing: 10) {
            if vm.phase == .fixing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.ink)
                }
            } else {
                if !vm.banner.isEmpty {
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.error).multilineTextAlignment(.center)
                }
                Text("存在未通过项，可一键修复或手动处理后重试").font(.caption).foregroundColor(ClaudeTheme.muted)
                HStack(spacing: 10) {
                    Button { vm.fixAll() } label: {
                        Label("一键修复", systemImage: "wand.and.stars")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)
                    Button { vm.refresh() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.warningBorder))
    }

    var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.caption2)
            Text("任何一项检查不过，都不会启动 Claude").font(.caption2)
            Spacer()
            Button {
                vm.checkUpdate()
                vm.showUpdateSheet = true
            } label: {
                Text("检查更新").font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("检查更新")
            Button { showAIPrompt = true } label: {
                Text("AI 配置").font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI 配置")
        }
        .foregroundColor(ClaudeTheme.muted)
        .sheet(isPresented: $vm.showUpdateSheet) { UpdateSheet(vm: vm) }
    }
}

// MARK: - 设备指纹体检

struct FingerprintView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设备指纹体检").font(.headline).foregroundColor(ClaudeTheme.ink)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
            }
            Text("字体地区特征 + GPU/虚拟机特征；Canvas/WebGL 请用 Web 检测页")
                .font(.caption).foregroundColor(ClaudeTheme.muted)
            ScrollView {
                Text(text.isEmpty ? "正在体检…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(ClaudeTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .preferredColorScheme(.light)
        .background(ClaudeTheme.bgTop)
    }
}

// MARK: - 版本更新

struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM
    @State private var copied = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("版本更新").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("只检查，不写入任何文件").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(vm.updateText.isEmpty ? "尚未检查" : vm.updateText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(height: 110)
                .background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))

                HStack(spacing: 10) {
                    Button { vm.checkUpdate() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { copyUpdateCommand() } label: {
                        Label(copied ? "已复制" : "复制更新命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout.bold())
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Text("复制后到终端执行即可更新；更新前会做 SHA256 校验，自检不通过会自动回滚。")
                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .padding(20)
        }
        .frame(width: 520, height: 300)
        .preferredColorScheme(.light)
    }

    private func copyUpdateCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString("~/.local/bin/claude-switch.sh update", forType: .string)
        copied = true
    }
}

// MARK: - AI 交接提示词

struct AIPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var copied = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 交接提示词").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("复制后粘贴给本地 AI，让它先读 AGENTS.md 再动手").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))

                HStack {
                    Button { copyPrompt() } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
        .preferredColorScheme(.light)
    }

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        copied = true
    }
}

// MARK: - 公告页

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    let sections: [(String, String)] = [
        ("Full-Tunnel 全流量接管", "基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。"),
        ("Environment Audit 环境一致性审计", "每次启动前执行 14 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。任一指标不达标即 Block-on-Fail，杜绝带病启动。"),
        ("Kill-Switch 断网急停", "常驻守护进程以 10 秒周期巡检隧道健康度，隧道中断即刻终止受保护进程，将裸连窗口压缩到秒级。进程级急停，非防火墙级保证，边界详见 SECURITY.md。"),
        ("Pinned Routing 域名置顶路由", "目标服务全家族域名及其生态依赖（Turnstile 人机验证、Telemetry 遥测、Payment 支付、Support 组件）置顶锁定代理路由，优先级高于任何第三方分流规则集，免疫规则库误判。"),
        ("Session Isolation 会话隔离快照", "多账号采用完整快照隔离：各账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换即物理交换数据卷，账号间零交叉污染。"),
        ("Drift Self-Healing 配置漂移自愈", "针对系统时区漂移、代理组件升级导致的配置重置等常见问题，内置 Watchdog 周期性校验并自动回滚至基线状态，全程留痕、可审计。"),
        ("Anti-Tracking 反追踪卫生", "验证链接（Magic Link）闭环于受保护环境内打开；邮件追踪像素（Tracking Pixel）经由邮箱服务商代理层屏蔽；全程固定单一住宅出口，不产生 Geo 跳变。"),
    ]

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安全防护体系公告").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("Security Architecture Bulletin").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(spacing: 10) {
                        Text("本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。")
                            .font(.callout)
                            .foregroundColor(ClaudeTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)

                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, s in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(idx + 1). \(s.0)").font(.callout.bold()).foregroundColor(ClaudeTheme.terracottaDeep)
                                Text(s.1).font(.caption).foregroundColor(ClaudeTheme.muted).lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(ClaudeTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。")
                            .font(.caption2)
                            .foregroundColor(ClaudeTheme.muted)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .frame(width: 460, height: 620)
        .preferredColorScheme(.light)
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let vm: VM
    private(set) var mainWindow: NSWindow?

    override init() {
        vm = VM()
        super.init()
    }

    // 隔离测试可注入假核心脚本，不需要修改 HOME 或接触真实账号。
    init(vm: VM) {
        self.vm = vm
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        vm.onSwitchCompleted = { [weak self] in self?.mainWindow?.orderOut(nil) }
        showMainWindow()
        vm.start()
    }

    func showMainWindow() {
        vm.prepareToShow()
        if mainWindow == nil {
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            let titleHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
            let height = min(CGFloat(900), (NSScreen.main?.visibleFrame.height ?? 900) - titleHeight)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
                styleMask: style,
                backing: .buffered, defer: false
            )
            window.title = "Claude切换器"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.contentView = NSHostingView(rootView: ContentView(vm: vm, height: height))
            window.delegate = self
            window.center()
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vm.canQuit ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }
}

struct MenuBarContent: View {
    @ObservedObject var vm: VM
    let showWindow: () -> Void

    var body: some View {
        Text("Claude 切换器")
        Text("当前账号：\(vm.current)")
        Text("最近检查：\(vm.lastCheckSummary)")
        if vm.phase == .fixing { Text("正在修复…") }
        if vm.phase == .switching { Text("正在切换账号…") }
        Divider()
        Button("打开主窗口", action: showWindow)
            .keyboardShortcut("o")
        Button("重新检查") {
            showWindow()
            vm.refresh()
        }
        .disabled(vm.isBusy)
        Button("检查更新") {
            showWindow()
            vm.checkUpdate()
            vm.showUpdateSheet = true
        }
        Divider()
        Button("退出 Claude 切换器") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(!vm.canQuit)
            .onAppear { vm.refreshAccountStatus() }
    }
}

// 生产应用与 UI 测试共用完全相同的菜单和窗口管理。
struct SwitcherMenu: Scene {
    @ObservedObject var vm: VM
    let controller: AppDelegate

    private static let statusImage: NSImage = {
        let image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Claude 切换器")!
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(vm: vm, showWindow: controller.showMainWindow)
        } label: {
            Image(nsImage: Self.statusImage)
                .accessibilityLabel("Claude 切换器")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Claude 切换器") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .disabled(!vm.canQuit)
            }
        }
    }
}

#if !CLAUDE_SWITCHER_TESTS
@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        SwitcherMenu(vm: appDelegate.vm, controller: appDelegate)
    }
}
#endif
