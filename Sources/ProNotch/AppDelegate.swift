import AppKit
import SwiftUI
import UserNotifications
import ScreenCaptureKit
import Combine

/// 可成为 key 的无边框面板：承载「检查更新」结果窗（按钮可点、回车可关）
private final class UpdateAlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var windowControllers: [NotchWindowController] = []
    /// 屏幕参数变化的防抖重建任务（合并系统成批发送的通知，避开中间态坐标）
    private var pendingScreenRebuild: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var usageStatusItem: NSStatusItem?                    // 独立可开关的「额度」菜单栏项
    private weak var usageToggleItem: NSMenuItem?                 // 主菜单里的开关项（同步勾选态）
    private var usageMenuHosting: NSHostingView<UsageMenuView>?   // 额度项下拉里的详情卡
    private lazy var showUsageInMenuBar = UserDefaults.standard.bool(forKey: "showUsageInMenuBar")
    private var usageTimer: Timer?
    private var usageCancellable: AnyCancellable?
    private var glowController: GlowController?
    private let updateChecker = UpdateChecker()
    private var updateMenuItem: NSMenuItem?
    private var updateSeparator: NSMenuItem?
    private var updateResultPanel: NSPanel?         // 检查更新结果窗（非模态，点「好」关闭）
    /// 超级截图全局快捷键（Carbon RegisterEventHotKey）
    private let screenshotHotKey = GlobalHotKey(id: 1)
    /// 剪贴板切换器全局快捷键
    private let clipboardHotKey = GlobalHotKey(id: 2)

    // 数据层在应用级持有：换屏重建刘海窗口时状态不丢失
    private var launcherStore: LauncherStore!
    private var clipboardStore: ClipboardStore!
    private var snippetStore: SnippetStore!
    private var chatStore: ChatStore!
    private var captureStore: CaptureStore!
    private var usageStore: UsageStore!
    private var agentSessionsStore: AgentSessionsStore!
    private var quickActions: QuickActionsStore!
    private var settingsStore: SettingsStore!
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateFromNotchHubIfNeeded()
        launcherStore = LauncherStore()
        clipboardStore = ClipboardStore()
        #if DEBUG
        // 一次性生成 README 配图：早于 ChatStore（避免同步读钥匙串弹框阻塞主线程），渲染后退出
        if CommandLine.arguments.contains("-snapshotDocs") {
            clipboardStore.loadDemoItems()                      // 演示数据，不暴露真实剪贴板
            ClipboardSwitcherController.shared.configure(store: clipboardStore)
            debugSnapshotSwitcher()
            debugSnapshotToolbar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        #endif
        snippetStore = SnippetStore()
        chatStore = ChatStore()
        captureStore = CaptureStore()
        usageStore = UsageStore()
        agentSessionsStore = AgentSessionsStore()
        quickActions = QuickActionsStore()
        settingsStore = SettingsStore()
        launcherStore.refreshIfNeeded()
        clipboardStore.startMonitoring()
        ClipboardSwitcherController.shared.configure(store: clipboardStore)

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

        // 升级迁移：把已接入的旧 hook 刷新到带「宿主 App 探测」的新格式（终端/IDE 通用）。
        // 仅刷新已接入的，不改变接入与否，避免误开用户已取消的 Agent。
        GlowHookInstaller.migrateIfInstalled(.claude)
        GlowHookInstaller.migrateIfInstalled(.codex)
        // 清除早期 hooks.json 接入残留的「无 host」pronotch 孤儿（与接入与否无关，幂等）
        GlowHookInstaller.cleanCodexHooksOrphan()

        // 注：曾在此预热系统翻译（翻个 "Hi" 焐热 session），但未装目标语言包时预热会触发系统
        // 「下载语言包」弹框、出现在屏幕左下角，用户没主动翻译却被打扰。已移除——首次截图翻译
        // 时再建 session（那时用户主动发起，弹下载框才合理），仅牺牲首次翻译数秒冷启动。

        // 截屏服务预热：首次调 SCShareableContent 要冷启动 ScreenCaptureKit 守护进程连接
        // （几百毫秒），启动后空闲时焐热，用户第一次按截图快捷键就不卡
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = try? await SCShareableContent.current
        }

        // 超级截图全局快捷键：按下即唤起区域截图；在设置里改快捷键后重新注册
        SuperScreenshotController.shared.settings = settingsStore   // 翻译时惰性读配置
        SuperScreenshotController.shared.warmUp()   // 后台预热截图子系统，消除"截图第一下慢"
        screenshotHotKey.onTrigger = {
            Task { @MainActor in SuperScreenshotController.shared.capture() }
        }
        screenshotHotKey.update(settingsStore.screenshotShortcut)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchScreenshotShortcutChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.screenshotHotKey.update(self.settingsStore.screenshotShortcut)
            }
        }

        // 剪贴板切换器全局快捷键：按下唤出横向卡片面板；设置里改键后重新注册
        clipboardHotKey.onTrigger = {
            Task { @MainActor in ClipboardSwitcherController.shared.toggle() }
        }
        clipboardHotKey.update(settingsStore.clipboardShortcut)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchClipboardShortcutChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clipboardHotKey.update(self.settingsStore.clipboardShortcut)
            }
        }

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
            self, selector: #selector(debugSnapshotSwitcher),
            name: NSNotification.Name("com.daliangpro.ProNotch.snapswitcher"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugSnapshotToolbar),
            name: NSNotification.Name("com.daliangpro.ProNotch.snaptoolbar"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugToggleSnippets),
            name: NSNotification.Name("com.daliangpro.ProNotch.snippets"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugTestCapture),
            name: NSNotification.Name("com.daliangpro.ProNotch.testcapture"), object: nil)
        // 调试入口：驱动 Codex notify 转发器接入 / 卸载，验证软件层接入
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugCodexHookOn),
            name: NSNotification.Name("com.daliangpro.ProNotch.codexhookon"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugCodexHookOff),
            name: NSNotification.Name("com.daliangpro.ProNotch.codexhookoff"), object: nil)
        #endif

        // 面板内齿轮按钮打开设置窗口（窗口由本类持有，进程内通知解耦）——
        // 正式功能，必须在调试块之外
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: NSNotification.Name("ProNotchOpenSettings"), object: nil)

        // 截图问 AI：截图工具栏发来图片 → 挂为闪问附件，展开刘海到闪问页等提问
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchAskAIWithImage"),
            object: nil, queue: .main) { [weak self] note in
            let img = note.object as? NSImage
            Task { @MainActor in
                guard let self, let img else { return }
                self.chatStore.attachScreenshot(img)
                if let wc = self.windowControllers.first {
                    wc.viewModel.activeTab = .chat
                    wc.viewModel.expandProgrammatically()
                }
                // 展开动画落定、面板成为 key 后再补一次聚焦，保证光标真正落进输入框
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.chatStore.focusInputTick += 1
                }
            }
        }
    }

    // MARK: - 光晕提醒 pronotch:// 入口

    /// 接收 pronotch://done?source=claude|codex —— 点亮对应颜色的「任务完成」光晕。
    /// Claude Code / Codex 完成时由 hook 执行 `open "pronotch://done?source=…"` 触发。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleGlowURL(url) }
    }

    private func handleGlowURL(_ url: URL) {
        guard url.scheme == "pronotch", url.host == "done" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let source = items?.first(where: { $0.name == "source" })?.value
        // host：hook 探测到的「Agent 实际所在 App」bundle id（终端/IDE/桌面版通用）
        let host = items?.first(where: { $0.name == "host" })?.value
        // session：Claude 的 session_id / Codex 的 thread-id，用于把「轮结束」瞬时点到对应 Agent 卡片
        let session = items?.first(where: { $0.name == "session" })?.value ?? ""
        switch source {
        case "claude":
            glowController?.notifyCompletion(.claude, host: host)
            agentSessionsStore?.markTurnEnded(session: session, source: .claude, host: host)
        case "codex":
            glowController?.notifyCompletion(.codex, host: host)
            agentSessionsStore?.markTurnEnded(session: session, source: .codex, host: host)
        default: break
        }
    }

    /// 调试用：写入一条测试妙记
    @objc private func debugTestCapture() {
        captureStore.capture("测试妙记：验证写入格式与今日列表解析")
    }

    /// 调试用：走真实路径接入 / 卸载 Codex 的 notify 转发器，结果写 /tmp 供核对
    @objc private func debugCodexHookOn() {
        print("[ProNotch] 调试：Codex notify 接入 = \(GlowHookInstaller.setInstalled(.codex, true))")
    }
    @objc private func debugCodexHookOff() {
        print("[ProNotch] 调试：Codex notify 卸载 = \(GlowHookInstaller.setInstalled(.codex, false))")
    }

    /// 调试用：切换剪贴板页的「历史/话术」子视图
    @objc private func debugToggleSnippets() {
        clipboardStore.showingSnippets.toggle()
        print("[ProNotch] 剪贴板子视图: \(clipboardStore.showingSnippets ? "话术库" : "历史")")
    }

    /// 调试用：离屏渲染剪贴板切换器到 PNG（生成 README 配图，无需屏幕录制权限）
    @objc private func debugSnapshotSwitcher() {
        let root = ZStack {
            Color(white: 0.08)
            ClipboardSwitcherView(store: clipboardStore, controller: .shared)
                .environmentObject(clipboardStore!)
        }
        .frame(width: 960, height: 400)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 400)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/pronotch-switcher.png"))
            print("[ProNotch] 剪贴板切换器快照已保存")
        }
    }

    /// 调试用：离屏渲染超级截图工具栏到 PNG（生成 README 配图）
    @objc private func debugSnapshotToolbar() {
        let bar = ScreenshotToolbar(
            boxActive: false, hlActive: false, textActive: false, penActive: false, arrowActive: false, mosaicActive: false,
            noteActive: false, flowActive: false, wmActive: false,
            translateTitle: "翻译", translateActive: false,
            onBox: {}, onHighlightTool: {}, onTextTool: {}, onPen: {}, onArrow: {}, onMosaic: {}, onNote: {}, onFlow: {}, onWatermark: {}, onUndo: {},
            onOCR: {}, onLongShot: {}, onPin: {}, onAskAI: {}, onTranslate: {}, onSave: {}, onCopy: {}, onCancel: {},
            onDragToolbar: { _, _ in })
        let probe = NSHostingView(rootView: bar)
        let s = probe.fittingSize
        let root = ZStack { Color(white: 0.08); bar }
            .frame(width: s.width + 48, height: s.height + 40)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: s.width + 48, height: s.height + 40)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/pronotch-toolbar.png"))
            print("[ProNotch] 超级截图工具栏快照已保存")
        }
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
        windowControllers.first?.debugTestFullscreen()
    }

    @objc private func debugTestCaffeinate() {
        windowControllers.first?.debugTestCaffeinate()
    }

    @objc private func debugTestTheme() {
        windowControllers.first?.debugTestTheme()
    }

    @objc private func debugTestSearch() {
        windowControllers.first?.debugTestSearch()
    }

    @objc private func debugTestModels() {
        windowControllers.first?.debugTestModels()
    }

    @objc private func debugTestChat() {
        windowControllers.first?.debugTestChat()
    }

    @objc private func debugNextTab() {
        windowControllers.first?.debugNextTab()
    }

    @objc private func debugTestPaste() {
        windowControllers.first?.debugTestPaste()
    }

    @objc private func debugTestLaunch() {
        windowControllers.first?.debugTestLaunch()
    }

    @objc private func debugSnapshot() {
        windowControllers.first?.saveSnapshot()
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
        windowControllers.forEach { $0.close() }
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
        // 显示器排列 / 分辨率变化时，系统会成批发送通知，且触发瞬间
        // NSScreen.screens 可能是中间态（坐标尚未稳定）——立即重建会把面板
        // 定位到错误坐标。故防抖：合并多次通知，延迟到布局稳定后再用最终坐标重建。
        pendingScreenRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let rects = NSScreen.screens.map { NotchGeometry.notchRect(on: $0) }
            if rects == self.windowControllers.map(\.viewModel.notchRect) { return }
            self.setupNotchWindow()
        }
        pendingScreenRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func debugToggle() {
        windowControllers.first?.viewModel.debugToggle()
    }

    /// 为每块在线屏幕各建一个刘海面板：有物理刘海的贴刘海，没有的
    /// （外接屏 / 扩展屏）在顶部正中模拟热区。数据层共享，展开状态各自独立。
    private func setupNotchWindow() {
        windowControllers.forEach { $0.close() }
        windowControllers = NSScreen.screens.map { screen in
            NotchWindowController(
                screen: screen,
                launcherStore: launcherStore,
                clipboardStore: clipboardStore,
                snippetStore: snippetStore,
                chatStore: chatStore,
                quickActions: quickActions,
                captureStore: captureStore,
                settingsStore: settingsStore,
                usageStore: usageStore,
                agentSessionsStore: agentSessionsStore)
        }
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
        // 「在菜单栏显示额度」开关：开→菜单栏独立出现额度栏，关→移除（状态持久化）
        let usageToggle = NSMenuItem(title: "Agent 额度", action: #selector(toggleUsageMenuBar), keyEquivalent: "")
        usageToggle.target = self
        usageToggle.image = emptyImage
        usageToggle.state = showUsageInMenuBar ? .on : .off
        menu.addItem(usageToggle)
        usageToggleItem = usageToggle
        menu.addItem(.separator())

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

        // 数据变化即刷新额度栏标题（定时拉取交给 applyUsageVisibility，只在额度栏显示时跑）
        usageCancellable = usageStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateUsageTitle() }
        applyUsageVisibility()   // 按持久化开关状态显隐额度栏并启停定时刷新
    }

    // MARK: - 独立「额度」菜单栏项（可开关）

    @objc private func toggleUsageMenuBar() {
        showUsageInMenuBar.toggle()
        UserDefaults.standard.set(showUsageInMenuBar, forKey: "showUsageInMenuBar")
        usageToggleItem?.state = showUsageInMenuBar ? .on : .off
        applyUsageVisibility()
    }

    /// 用 NSStatusItem.isVisible 显隐额度栏（不销毁重建，避开「关掉再打开消失」的重建坑）：
    /// 首次开启才真正创建 item，此后只切 isVisible + 启停 60 秒定时刷新
    private func applyUsageVisibility() {
        if showUsageInMenuBar {
            if usageStatusItem == nil { createUsageStatusItem() }
            usageStatusItem?.isVisible = true
            updateUsageTitle()
            usageStore.refresh(force: true)
            startUsageTimer()
        } else {
            usageStatusItem?.isVisible = false
            stopUsageTimer()
        }
    }

    /// 只创建一次：变宽额度栏，常驻 C<5h%> X<5h%>，点开是详情卡（两服务 5h/7d 进度条）
    private func createUsageStatusItem() {
        guard usageStatusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "AI 编码额度（Claude / Codex）"
        let menu = NSMenu()
        menu.delegate = self   // 打开时强制刷新
        let hosting = NSHostingView(rootView: UsageMenuView(store: usageStore))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 150)
        let header = NSMenuItem(); header.view = hosting
        menu.addItem(header)
        usageMenuHosting = hosting
        let refresh = NSMenuItem(title: "刷新额度", action: #selector(refreshUsageFromMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        item.menu = menu
        usageStatusItem = item
    }

    /// 定时刷新只在额度栏显示时运行——隐藏即停，不再无谓访问 Claude / ChatGPT 接口
    private func startUsageTimer() {
        guard usageTimer == nil else { return }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.usageStore.refresh() }
        }
    }
    private func stopUsageTimer() { usageTimer?.invalidate(); usageTimer = nil }

    /// 额度栏标题：C<5h%> · X<5h%>，高占用变色；无数据的服务省略。仅额度栏存在时更新
    private func updateUsageTitle() {
        guard let button = usageStatusItem?.button else { return }
        let parts: [(String, ServiceQuota?)] = [("C", usageStore.claude), ("X", usageStore.codex)]
        let title = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        for (tag, q) in parts {
            guard let pct = q?.primary?.usedPercent else { continue }
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: base)) }
            var seg = base
            seg[.foregroundColor] = pctColor(pct)
            title.append(NSAttributedString(string: "\(tag)\(Int(pct.rounded()))%", attributes: seg))
        }
        button.attributedTitle = title.length > 0 ? title
            : NSAttributedString(string: "额度…", attributes: base)   // 还没数据时占位，别空着
    }

    private func pctColor(_ pct: Double) -> NSColor {
        if pct >= 85 { return NSColor.systemRed }
        if pct >= 60 { return NSColor.systemOrange }
        return NSColor.labelColor   // 正常用系统前景色，自动适配深浅色菜单栏
    }

    @objc private func refreshUsageFromMenu() { usageStore.refresh(force: true) }

    // MARK: - 检查更新

    @objc private func checkForUpdatesManually() {
        updateChecker.check { [weak self] release in
            self?.handleUpdate(release, manual: true)
        }
    }

    private func handleUpdate(_ release: UpdateChecker.Release?, manual: Bool) {
        refreshUpdateMenuItem()
        if let release {
            if manual {
                // 用户主动检查：醒目弹窗提示 +「前往下载」按钮（不再只在菜单里改一行字）
                showUpdateResultWindow(
                    title: "发现新版本 \(release.version)",
                    detail: "当前 \(updateChecker.currentVersion)，可更新到 \(release.version)。",
                    actionTitle: "前往下载",
                    action: { [weak self] in self?.openLatestRelease() })
            } else {
                notifyUpdate(release)   // 启动时静默检查：只发通知 + 菜单标记，不弹窗打扰
            }
        } else if manual {
            // 非模态结果窗：NSAlert.runModal 会接管事件循环，弹着时截图快捷键等全部失灵；
            // 这里用同款式的普通浮动窗口，弹着时一切照常（还能被截图分享）
            if let err = updateChecker.lastError {
                showUpdateResultWindow(title: "检查更新失败", detail: err)
            } else {
                showUpdateResultWindow(title: "已是最新版本",
                                       detail: "当前 \(updateChecker.currentVersion) 已是最新。")
            }
        }
    }

    /// 系统弹窗同款式的非模态结果窗：屏幕中央偏上，点「好」或回车关闭
    private func showUpdateResultWindow(title: String, detail: String,
                                        actionTitle: String? = nil, action: (() -> Void)? = nil) {
        updateResultPanel?.orderOut(nil)
        let host = NSHostingView(rootView: UpdateAlertView(
            title: title, detail: detail, actionTitle: actionTitle,
            onAction: action.map { act in { [weak self] in
                self?.updateResultPanel?.orderOut(nil); self?.updateResultPanel = nil; act()
            } },
            onOK: { [weak self] in
                self?.updateResultPanel?.orderOut(nil)
                self?.updateResultPanel = nil
            }))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let panel = UpdateAlertPanel(contentRect: host.frame, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.contentView = host
        let sf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: sf.midX - size.width / 2,
                                     y: sf.midY - size.height / 2 + sf.height * 0.12))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        updateResultPanel = panel
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
        let version = release.version
        let urlString = release.url.absoluteString
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            // 回调在任意线程：中心实例在闭包内现取（单例），不跨 @Sendable 边界捕获非 Sendable 对象
            let content = UNMutableNotificationContent()
            content.title = "ProNotch 有新版本"
            content.body = "\(version) 可更新，点击前往下载。"
            content.userInfo = ["url": urlString]
            let request = UNNotificationRequest(
                identifier: "pronotch.update.\(version)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
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

extension AppDelegate: NSMenuDelegate {
    /// 打开菜单栏下拉时强制拉一次最新额度（比 90 秒定时更即时）
    func menuWillOpen(_ menu: NSMenu) {
        usageStore.refresh(force: true)
    }
}
