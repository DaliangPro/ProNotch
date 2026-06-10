import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?

    // 数据层在应用级持有：换屏重建刘海窗口时状态不丢失
    private var launcherStore: LauncherStore!
    private var clipboardStore: ClipboardStore!
    private var snippetStore: SnippetStore!
    private var chatStore: ChatStore!
    private var captureStore: CaptureStore!
    private var quickActions: QuickActionsStore!
    private var settingsStore: SettingsStore!
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        launcherStore = LauncherStore()
        clipboardStore = ClipboardStore()
        snippetStore = SnippetStore()
        chatStore = ChatStore()
        captureStore = CaptureStore()
        quickActions = QuickActionsStore()
        settingsStore = SettingsStore()
        launcherStore.refreshIfNeeded()
        clipboardStore.startMonitoring()

        setupMainMenu()
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

        // 调试入口：走真实代码路径启动计算器，验证启动台逻辑
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestLaunch),
            name: NSNotification.Name("com.jiliang.NotchHub.testlaunch"), object: nil)

        // 调试入口：循环切换标签页 / 把历史第一条复制回剪贴板
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugNextTab),
            name: NSNotification.Name("com.jiliang.NotchHub.nexttab"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestPaste),
            name: NSNotification.Name("com.jiliang.NotchHub.testpaste"), object: nil)

        // 调试入口：走真实代码路径发送一条 AI 对话消息 / 拉取模型列表
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestChat),
            name: NSNotification.Name("com.jiliang.NotchHub.testchat"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestModels),
            name: NSNotification.Name("com.jiliang.NotchHub.testmodels"), object: nil)

        // 调试入口：执行一次联网搜索验证搜索链路
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestSearch),
            name: NSNotification.Name("com.jiliang.NotchHub.testsearch"), object: nil)

        // 调试入口：探测 SkyLight 外观接口可用性
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestTheme),
            name: NSNotification.Name("com.jiliang.NotchHub.testtheme"), object: nil)

        // 调试入口：切换防休眠 / 打开设置窗口
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestCaffeinate),
            name: NSNotification.Name("com.jiliang.NotchHub.testcaffeinate"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openSettings),
            name: NSNotification.Name("com.jiliang.NotchHub.opensettings"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestFullscreen),
            name: NSNotification.Name("com.jiliang.NotchHub.testfullscreen"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugSnapshotSettings),
            name: NSNotification.Name("com.jiliang.NotchHub.snapsettings"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugToggleSnippets),
            name: NSNotification.Name("com.jiliang.NotchHub.snippets"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestCapture),
            name: NSNotification.Name("com.jiliang.NotchHub.testcapture"), object: nil)
    }

    /// 调试用：写入一条测试速记
    @objc private func debugTestCapture() {
        captureStore.capture("测试速记：验证写入格式与今日列表解析")
    }

    /// 调试用：切换剪贴板页的「历史/话术」子视图
    @objc private func debugToggleSnippets() {
        clipboardStore.showingSnippets.toggle()
        print("[NotchHub] 剪贴板子视图: \(clipboardStore.showingSnippets ? "话术库" : "历史")")
    }

    /// 调试用：离屏渲染设置界面到 PNG（无需打开窗口与屏幕录制权限）
    @objc private func debugSnapshotSettings() {
        let root = SettingsView()
            .environmentObject(settingsStore!)
            .environmentObject(chatStore!)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 478)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/notchhub-settings-snapshot.png"))
            print("[NotchHub] 设置界面快照已保存")
        }
    }

    @objc private func debugTestFullscreen() {
        windowController?.debugTestFullscreen()
    }

    @objc private func debugTestCaffeinate() {
        windowController?.debugTestCaffeinate()
    }

    @objc private func debugTestTheme() {
        windowController?.debugTestTheme()
    }

    @objc private func debugTestSearch() {
        windowController?.debugTestSearch()
    }

    @objc private func debugTestModels() {
        windowController?.debugTestModels()
    }

    @objc private func debugTestChat() {
        windowController?.debugTestChat()
    }

    @objc private func debugNextTab() {
        windowController?.debugNextTab()
    }

    @objc private func debugTestPaste() {
        windowController?.debugTestPaste()
    }

    @objc private func debugTestLaunch() {
        windowController?.debugTestLaunch()
    }

    @objc private func debugSnapshot() {
        windowController?.saveSnapshot()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前清理子进程（caffeinate）、监听与窗口
        clipboardStore?.stop()
        chatStore?.stopStreaming()
        quickActions?.stop()
        windowController?.close()
    }

    @objc private func openSettings() {
        settingsWindow.show(settings: settingsStore, chatStore: chatStore)
    }

    @objc private func screenParametersChanged() {
        // 系统会成批发送参数变更通知（应用启动、色彩配置切换都可能触发），
        // 刘海几何没变就不重建，避免面板使用中突然消失
        let screen = NotchGeometry.targetScreen()
        let rect = NotchGeometry.notchRect(on: screen)
        if let existing = windowController, existing.viewModel.notchRect == rect {
            return
        }
        setupNotchWindow()
    }

    @objc private func debugToggle() {
        windowController?.viewModel.debugToggle()
    }

    private func setupNotchWindow() {
        windowController?.close()
        windowController = NotchWindowController(
            launcherStore: launcherStore,
            clipboardStore: clipboardStore,
            snippetStore: snippetStore,
            chatStore: chatStore,
            quickActions: quickActions,
            captureStore: captureStore,
            settingsStore: settingsStore)
    }

    /// 代理应用没有可见菜单栏，但 ⌘V/⌘C 等快捷键依赖主菜单路由，
    /// 挂一个隐藏的编辑菜单让文本框支持粘贴、拷贝、全选与撤销
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
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
        let toggleItem = NSMenuItem(title: "展开 / 收起",
                                    action: #selector(debugToggle), keyEquivalent: "t")
        toggleItem.target = self
        toggleItem.image = nil
        menu.addItem(toggleItem)
        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = nil
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 NotchHub",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.image = nil
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }
}
