import SwiftUI
import AppKit
import CryptoKit

// 仅供隔离 UI 验证。没有路径参数就拒绝启动，绝不回退到真实安装的核心脚本。
final class FixtureDelegate: AppDelegate {
    override init() {
        guard CommandLine.arguments.count >= 2,
              FileManager.default.fileExists(atPath: CommandLine.arguments[1]) else {
            fatalError("隔离演示需要显式传入 fake-core.sh 路径")
        }
        let core = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(core.utf8)).map { String(format: "%02x", $0) }.joined()
        let suiteName = "claude-switcher-demo.\(digest)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离演示偏好存储")
        }
        // 相同假脚本路径复用演示偏好，重启可验证持久化；不会读取生产偏好。
        if CommandLine.arguments.contains("--reset-notice") {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.init(vm: VM(core: core, noticeDefaults: defaults))
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        super.applicationDidFinishLaunching(notification)
        mainWindow?.title = "Claude 切换器 · 隔离演示"
        print("DEMO activation policy: \(NSApplication.shared.activationPolicy().rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let buttons = NSApplication.shared.windows.flatMap { window in
                Self.statusButtons(in: window.contentView)
            }
            print("DEMO native status buttons: \(buttons.count)")
            for button in buttons {
                print("DEMO status icon template: \(button.image?.isTemplate == true)")
                print("DEMO status label: \(button.accessibilityLabel() ?? "")")
                print("DEMO status title: \(button.accessibilityTitle() ?? "")")
                print("DEMO status help: \(button.accessibilityHelp() ?? "")")
                print("DEMO image description: \(button.image?.accessibilityDescription ?? "")")
            }
            fflush(stdout)
        }
        if let window = mainWindow {
            print("DEMO window frame: \(window.frame), visible screen: \(window.screen?.visibleFrame ?? .zero)")
        }
    }

    private static func statusButtons(in view: NSView?) -> [NSStatusBarButton] {
        guard let view = view else { return [] }
        return (view as? NSStatusBarButton).map { [$0] } ?? view.subviews.flatMap { statusButtons(in: $0) }
    }
}

@main
struct MenuBarFixture: App {
    @NSApplicationDelegateAdaptor(FixtureDelegate.self) var appDelegate

    var body: some Scene {
        SwitcherMenu(vm: appDelegate.vm, controller: appDelegate)
            .commands {
                // 同一份生产菜单内容；供无法定位 AXExtrasMenuBar 的 UI 工具验收。
                CommandMenu("菜单内容预览") {
                    MenuBarContent(vm: appDelegate.vm, showWindow: appDelegate.showMainWindow)
                }
                CommandMenu("演示外观") {
                    Button("浅色") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
                    Button("深色") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
                }
            }
    }
}
