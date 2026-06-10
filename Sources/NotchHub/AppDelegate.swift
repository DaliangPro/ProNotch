import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupNotchWindow()

        // 屏幕配置变化（接显示器、合盖等）时重建刘海窗口
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 调试入口：命令行可触发展开/收起，便于不靠鼠标悬停验证
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugToggle),
            name: NSNotification.Name("com.jiliang.NotchHub.toggle"), object: nil)

        // 调试入口：把当前窗口内容渲染成 PNG，无需屏幕录制权限即可验证 UI
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugSnapshot),
            name: NSNotification.Name("com.jiliang.NotchHub.snapshot"), object: nil)
    }

    @objc private func debugSnapshot() {
        windowController?.saveSnapshot()
    }

    @objc private func screenParametersChanged() {
        setupNotchWindow()
    }

    @objc private func debugToggle() {
        windowController?.viewModel.debugToggle()
    }

    private func setupNotchWindow() {
        windowController?.close()
        windowController = NotchWindowController()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "sparkles.rectangle.stack",
                               accessibilityDescription: "NotchHub") {
            item.button?.image = image
        } else {
            item.button?.title = "凹"
        }
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "展开 / 收起（调试）",
                                    action: #selector(debugToggle), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 NotchHub",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}
