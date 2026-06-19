import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var glowController: GlowController?
    private let updateChecker = UpdateChecker()
    private var updateMenuItem: NSMenuItem?
    private var updateSeparator: NSMenuItem?

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
        Self.migrateFromNotchHubIfNeeded()
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

        // 启动时静默检查更新：发现新版才提醒（不打扰）
        UNUserNotificationCenter.current().delegate = self
        updateChecker.check { [weak self] release in
            self?.handleUpdate(release, manual: false)
        }

        // 光晕提醒：常驻一个覆盖整屏的光晕层（默认不显示，等 pronotch:// 信号点亮）
        glowController = GlowController(settings: settingsStore)

        // 屏幕配置变化（接显示器、合盖等）时重建刘海窗口
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 调试通道仅存在于开发构建：正式版不暴露任何可被本机其他进程
        // 远程触发的接口
        #if DEBUG
        // 调试入口：命令行可触发展开/收起，便于不靠鼠标悬停验证
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugToggle),
            name: NSNotification.Name("com.daliangpro.ProNotch.toggle"), object: nil)

        // 调试入口：把当前窗口内容渲染成 PNG，无需屏幕录制权限即可验证 UI
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugSnapshot),
            name: NSNotification.Name("com.daliangpro.ProNotch.snapshot"), object: nil)

        // 调试入口：走真实代码路径启动计算器，验证启动台逻辑
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestLaunch),
            name: NSNotification.Name("com.daliangpro.ProNotch.testlaunch"), object: nil)

        // 调试入口：循环切换标签页 / 把历史第一条复制回剪贴板
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugNextTab),
            name: NSNotification.Name("com.daliangpro.ProNotch.nexttab"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestPaste),
            name: NSNotification.Name("com.daliangpro.ProNotch.testpaste"), object: nil)

        // 调试入口：走真实代码路径发送一条 AI 对话消息 / 拉取模型列表
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestChat),
            name: NSNotification.Name("com.daliangpro.ProNotch.testchat"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestModels),
            name: NSNotification.Name("com.daliangpro.ProNotch.testmodels"), object: nil)

        // 调试入口：执行一次联网搜索验证搜索链路
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestSearch),
            name: NSNotification.Name("com.daliangpro.ProNotch.testsearch"), object: nil)

        // 调试入口：探测 SkyLight 外观接口可用性
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestTheme),
            name: NSNotification.Name("com.daliangpro.ProNotch.testtheme"), object: nil)

        // 调试入口：切换防休眠 / 打开设置窗口
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestCaffeinate),
            name: NSNotification.Name("com.daliangpro.ProNotch.testcaffeinate"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openSettings),
            name: NSNotification.Name("com.daliangpro.ProNotch.opensettings"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestFullscreen),
            name: NSNotification.Name("com.daliangpro.ProNotch.testfullscreen"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugSnapshotSettings),
            name: NSNotification.Name("com.daliangpro.ProNotch.snapsettings"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugToggleSnippets),
            name: NSNotification.Name("com.daliangpro.ProNotch.snippets"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestCapture),
            name: NSNotification.Name("com.daliangpro.ProNotch.testcapture"), object: nil)
        #endif

        // 面板内齿轮按钮打开设置窗口（窗口由本类持有，进程内通知解耦）——
        // 正式功能，必须在调试块之外
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: NSNotification.Name("ProNotchOpenSettings"), object: nil)
    }

    // MARK: - 光晕提醒 pronotch:// 入口

    /// 接收 pronotch://done?source=claude|codex —— 点亮对应颜色的「任务完成」光晕。
    /// Claude Code / Codex 完成时由 hook 执行 `open "pronotch://done?source=…"` 触发。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleGlowURL(url) }
    }

    private func handleGlowURL(_ url: URL) {
        guard url.scheme == "pronotch", url.host == "done" else { return }
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "source" })?.value
        switch source {
        case "claude": glowController?.notifyCompletion(.claude)
        case "codex":  glowController?.notifyCompletion(.codex)
        default: break
        }
    }

    /// 调试用：写入一条测试妙记
    @objc private func debugTestCapture() {
        captureStore.capture("测试妙记：验证写入格式与今日列表解析")
    }

    /// 调试用：切换剪贴板页的「历史/话术」子视图
    @objc private func debugToggleSnippets() {
        clipboardStore.showingSnippets.toggle()
        print("[ProNotch] 剪贴板子视图: \(clipboardStore.showingSnippets ? "话术库" : "历史")")
    }

    /// 调试用：离屏渲染设置界面到 PNG（无需打开窗口与屏幕录制权限）
    @objc private func debugSnapshotSettings() {
        let root = SettingsView()
            .environmentObject(settingsStore!)
            .environmentObject(chatStore!)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 524)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/notchhub-settings-snapshot.png"))
            print("[ProNotch] 设置界面快照已保存")
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

    /// 应用更名（NotchHub → ProNotch，bundle id 一并变更）的一次性数据搬家：
    /// 配置域整体拷贝、数据目录改名、钥匙串条目迁移，必须先于各 Store 初始化
    private static func migrateFromNotchHubIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateFromNotchHub") else { return }

        // 1. 旧配置域整体拷入新域（新域已有的键不覆盖）
        if let legacy = defaults.persistentDomain(forName: "com.jiliang.NotchHub") {
            var copied = 0
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
            print("[ProNotch] 已从旧版配置迁移 \(copied) 项设置")
        }

        // 2. 数据目录（剪贴板历史 / 话术库）随应用名改名
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let oldDir = base.appendingPathComponent("NotchHub")
            let newDir = base.appendingPathComponent("ProNotch")
            if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
                try? fm.moveItem(at: oldDir, to: newDir)
                print("[ProNotch] 数据目录已迁移")
            }
        }

        // 3. 钥匙串条目搬到新 service
        KeychainStore.migrateLegacyService()

        defaults.set(true, forKey: "didMigrateFromNotchHub")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前清理子进程（caffeinate）、监听与窗口
        clipboardStore?.stop()
        chatStore?.stopStreaming()
        quickActions?.stop()
        windowController?.close()
    }

    @objc private func openSettings() {
        guard let glowController else { return }
        settingsWindow.show(settings: settingsStore, chatStore: chatStore, glow: glowController, updates: updateChecker)
    }

    /// 系统标准关于面板：图标、名称、版本来自 Info.plist，
    /// 署名与可点击的 GitHub 链接放在 credits 区
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "作者：Daliang\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        credits.append(NSAttributedString(
            string: "github.com/DaliangPro/ProNotch",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://github.com/DaliangPro/ProNotch")!,
            ]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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

    /// 菜单栏图标：自绘「屏幕轮廓 + 顶部实心刘海」，模板图自动适配深浅菜单栏
    private static func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            let screen = NSRect(x: 1, y: 1.25, width: 16, height: 11.5)
            let outline = NSBezierPath(roundedRect: screen, xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1.5
            NSColor.black.setStroke()
            outline.stroke()
            // 刘海：从屏幕顶边向内悬挂的圆角小块
            let nw: CGFloat = 7, nh: CGFloat = 3.6, r: CGFloat = 1.4
            let nx = screen.midX - nw / 2, ny = screen.maxY
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: nx, y: ny))
            notch.line(to: NSPoint(x: nx, y: ny - nh + r))
            notch.appendArc(withCenter: NSPoint(x: nx + r, y: ny - nh + r),
                            radius: r, startAngle: 180, endAngle: 270, clockwise: false)
            notch.line(to: NSPoint(x: nx + nw - r, y: ny - nh))
            notch.appendArc(withCenter: NSPoint(x: nx + nw - r, y: ny - nh + r),
                            radius: r, startAngle: 270, endAngle: 360, clockwise: false)
            notch.line(to: NSPoint(x: nx + nw, y: ny))
            notch.close()
            NSColor.black.setFill()
            notch.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeStatusIcon()
        let menu = NSMenu()
        // macOS 26 会按标题词汇给菜单项自动配图标（设置→齿轮、退出→叉），
        // image 为 nil 时才会注入；显式塞 1×1 透明空图占住槽位即可禁用
        let emptyImage = NSImage(size: NSSize(width: 1, height: 1))

        // 顶部「发现新版本」项：默认隐藏，检查到新版才显示
        let updateItem = NSMenuItem(title: "↓ 发现新版本",
                                    action: #selector(openLatestRelease), keyEquivalent: "")
        updateItem.target = self
        updateItem.image = emptyImage
        updateItem.isHidden = true
        menu.addItem(updateItem)
        let updateSep = NSMenuItem.separator()
        updateSep.isHidden = true
        menu.addItem(updateSep)
        updateMenuItem = updateItem
        updateSeparator = updateSep

        let toggleItem = NSMenuItem(title: "展开 / 收起",
                                    action: #selector(debugToggle), keyEquivalent: "t")
        toggleItem.target = self
        toggleItem.image = emptyImage
        menu.addItem(toggleItem)
        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = emptyImage
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "关于 ProNotch",
                                   action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = emptyImage
        menu.addItem(aboutItem)
        let checkUpdateItem = NSMenuItem(title: "检查更新…",
                                         action: #selector(checkForUpdatesManually), keyEquivalent: "")
        checkUpdateItem.target = self
        checkUpdateItem.image = emptyImage
        menu.addItem(checkUpdateItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 ProNotch",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.image = emptyImage
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    // MARK: - 检查更新

    @objc private func checkForUpdatesManually() {
        updateChecker.check { [weak self] release in
            self?.handleUpdate(release, manual: true)
        }
    }

    private func handleUpdate(_ release: UpdateChecker.Release?, manual: Bool) {
        refreshUpdateMenuItem()
        if let release {
            notifyUpdate(release)
        } else if manual {
            let alert = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            if let err = updateChecker.lastError {
                alert.messageText = "检查更新失败"
                alert.informativeText = err
            } else {
                alert.messageText = "已是最新版本"
                alert.informativeText = "当前 \(updateChecker.currentVersion) 已是最新。"
            }
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func refreshUpdateMenuItem() {
        if let release = updateChecker.available {
            updateMenuItem?.title = "↓ 发现新版本 \(release.version)"
            updateMenuItem?.isHidden = false
            updateSeparator?.isHidden = false
        } else {
            updateMenuItem?.isHidden = true
            updateSeparator?.isHidden = true
        }
    }

    @objc private func openLatestRelease() {
        if let url = updateChecker.available?.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func notifyUpdate(_ release: UpdateChecker.Release) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "ProNotch 有新版本"
            content.body = "\(release.version) 可更新，点击前往下载。"
            content.userInfo = ["url": release.url.absoluteString]
            let request = UNNotificationRequest(
                identifier: "pronotch.update.\(release.version)", content: content, trigger: nil)
            center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let urlString = response.notification.request.content.userInfo["url"] as? String
        Task { @MainActor in
            if let urlString, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}
