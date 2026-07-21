import AppKit
import SwiftUI
import UserNotifications
import ScreenCaptureKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var windowControllers: [NotchWindowController] = []
    /// 屏幕参数变化的防抖重建任务（合并系统成批发送的通知，避开中间态坐标）
    private var pendingScreenRebuild: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var usageStatusItem: UsageStatusItemController?        // 独立可开关的「额度」菜单栏项
    /// 恶劣天气预警兜底刷新：两侧功能区都没配天气时也保证数据定期落地供扫描
    private var weatherTimer: Timer?
    private var glowController: GlowController?
    /// 检查更新的呈现层：结果窗、菜单标记、通知（见 UpdatePresenter）
    let updatePresenter = UpdatePresenter()
    /// 设置页与调试快照直接读拉取器本体
    var updateChecker: UpdateChecker { updatePresenter.checker }
    /// 超级截图全局快捷键（Carbon RegisterEventHotKey）
    let screenshotHotKey = GlobalHotKey(id: 1)
    /// 剪贴板切换器全局快捷键
    let clipboardHotKey = GlobalHotKey(id: 2)
    /// AI 闪问全局快捷键（弹出刘海对话页）
    let chatHotKey = GlobalHotKey(id: 3)

    /// 数据层在应用级持有：换屏重建刘海窗口时状态不丢失。
    /// 离屏渲染设置窗那条路径（-snapshotSettings）只建它用得着的几个，不填这里，故为 nil
    var env: AppEnvironment!
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateFromNotchHubIfNeeded()
        let launcher = LauncherStore()
        let clipboard = ClipboardStore()
        let snippets = SnippetStore()          // 提前初始化：DEBUG 配图分支与快捷键切换器都依赖它
        #if DEBUG
        // 一次性生成 README 配图：早于 ChatStore（避免同步读钥匙串弹框阻塞主线程），渲染后退出
        if CommandLine.arguments.contains("-snapshotDocs") {
            clipboard.loadDemoItems()                      // 演示数据，不暴露真实剪贴板
            ClipboardSwitcherController.shared.configure(store: clipboard, snippets: snippets)
            renderSwitcherSnapshot(clipboard: clipboard, snippets: snippets)
            debugSnapshotToolbar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        #endif
        // 对齐核查：离屏渲染设置窗口 PNG 后退出（-snapshotSettings）。
        // 不放 #if DEBUG——须用 /Applications 正式签名实例跑：钥匙串 ACL 已授权，
        // ChatStore 的后台 Key 回填不会弹授权框（debug 裸二进制会弹）。
        // 排在建 env 之前，是因为这一屏只用得着这四个：一并建出 UsageStore
        // 会让渲染实例白扫一遍 transcript 全库
        if CommandLine.arguments.contains("-snapshotSettings") {
            let settings = SettingsStore()
            let chat = ChatStore()
            let weather = WeatherStore()
            weather.loadDemoWeather()   // 渲染实例不定位不联网，也不弹授权框
            let glow = GlowController(settings: settings)
            glowController = glow
            snapshotSettings(settings: settings, chat: chat, glow: glow,
                             weather: weather, snippets: snippets)
            return
        }
        // 余下两条路径都要完整数据层。ChatStore 仍排在 SnippetStore 之后建，理由同上
        env = AppEnvironment(
            launcher: launcher, clipboard: clipboard, snippets: snippets,
            chat: ChatStore(), usage: UsageStore(), agentSessions: AgentSessionsStore(),
            quickActions: QuickActionsStore(), settings: SettingsStore(),
            memory: MemoryStore(), weather: WeatherStore())
        // 对齐核查：离屏渲染展开面板四页 PNG 后退出（-snapshotPanel）。同样须用正式签名实例跑
        if CommandLine.arguments.contains("-snapshotPanel") {
            env.weather.loadDemoWeather()   // 渲染实例不定位不联网，也不弹授权框
            env.launcher.refreshIfNeeded()
            debugSnapshotPanel()
            return   // 渲染实例不装菜单/状态栏/热键/监控，渲完 terminate
        }
        env.launcher.refreshIfNeeded()
        // 剪贴板历史：索引总是加载（记录关闭时历史仍可看），0.5 秒轮询按开关起停（真停机）
        if env.settings.clipboardEnabled {
            env.clipboard.startMonitoring()
        } else {
            env.clipboard.loadHistoryOnly()
        }
        NotificationCenter.default.addObserver(
            forName: .proNotchClipboardEnabledChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.env.settings.clipboardEnabled {
                    self.env.clipboard.startMonitoring()
                } else {
                    self.env.clipboard.stop()
                }
            }
        }
        ClipboardSwitcherController.shared.configure(store: env.clipboard, snippets: env.snippets)

        setupMainMenu()
        setupStatusItem()
        setupNotchWindow()

        // 启动时静默检查更新：发现新版才提醒（不打扰）
        UNUserNotificationCenter.current().delegate = self
        updatePresenter.checkSilently()

        // 光晕提醒：控制器常驻（很轻），覆盖整屏的光晕窗点亮才建、熄灭即拆
        glowController = GlowController(settings: env.settings)

        // 恶劣天气预警兜底定时器：预警是它唯一的存在理由——预警关闭即不跑（真停机），
        // 设置页改动预警开关/类型时实时起停
        applyWeatherTimerState()
        NotificationCenter.default.addObserver(
            forName: .proNotchWeatherAlertSettingsChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyWeatherTimerState() }
        }

        // 升级迁移：把已接入的旧 hook 刷新到带「宿主 App 探测」的新格式（终端/IDE 通用）。
        // 仅刷新已接入的，不改变接入与否，避免误开用户已取消的 Agent。
        for kind in AgentKind.allCases where kind.supportsGlow {
            GlowHookInstaller.migrateIfInstalled(kind)
        }
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

        // 三个全局快捷键的注册与改键重注册（实现见 HotKeySetup.swift）
        setupHotKeys()

        // 屏幕配置变化（接显示器、合盖等）时重建刘海窗口
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 「显示屏幕」设置变更：立即按新范围重建（不必等下一次屏幕配置变化）
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenModeChanged),
            name: .proNotchScreenModeChanged, object: nil)

        // 跨进程调试入口，仅 DEBUG 构建注册（实现见 DebugChannels.swift）
        setupDebugChannels()

        // 面板内齿轮按钮打开设置窗口（窗口由本类持有，进程内通知解耦）——
        // 正式功能，必须在调试块之外
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .proNotchOpenSettings, object: nil)

        // 截图问 AI：截图工具栏发来图片 → 挂为闪问附件，展开刘海到闪问页等提问
        NotificationCenter.default.addObserver(
            forName: .proNotchAskAIWithImage,
            object: nil, queue: .main) { [weak self] note in
            let img = note.object as? NSImage
            Task { @MainActor in
                guard let self, let img else { return }
                self.env.chat.attachScreenshot(img)
                if let wc = self.windowControllers.first {
                    wc.viewModel.activeTab = .chat
                    wc.viewModel.expandProgrammatically()
                }
                // 展开动画落定、面板成为 key 后再补一次聚焦，保证光标真正落进输入框
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.env.chat.focusInputTick += 1
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

    /// 调试旁路：仅 DEBUG 构建、且显式设置了环境变量时才放行无令牌回调。
    /// 正式构建里这个常量恒为 false，编译期就没有旁路可走
    private static var allowsUnsignedGlowCallback: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PRONOTCH_ALLOW_UNSIGNED_GLOW"] == "1"
        #else
        return false
        #endif
    }

    private func handleGlowURL(_ url: URL) {
        guard url.scheme == "pronotch", url.host == "done" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        // 认证优先：这条 URL 谁都能调（本机任意进程、任意网页里的一个链接），
        // 伪造的回调不仅能乱点光晕，还能往会话表里塞宿主映射、把用户点卡片时引向别的 App。
        // 校验必须发生在动 host/session 映射与点亮光晕之前
        let token = items?.first(where: { $0.name == "token" })?.value
        if case .reject(let reason) = GlowCallbackAuth.decide(
            token: token, expected: GlowHookToken.current(.production),
            allowUnsigned: Self.allowsUnsignedGlowCallback) {
            AppLog.app.error("已丢弃未通过认证的 pronotch://done 回调：\(reason, privacy: .public)")
            return
        }
        let source = items?.first(where: { $0.name == "source" })?.value
        // host：hook 探测到的「Agent 实际所在 App」bundle id（终端/IDE/桌面版通用）
        let host = items?.first(where: { $0.name == "host" })?.value
        // session：Claude 的 session_id / Codex 的 thread-id，用于把「轮结束」瞬时点到对应 Agent 卡片
        let session = items?.first(where: { $0.name == "session" })?.value ?? ""
        // host 偶发抓空（Claudian 的 claude 有时没挂在 Obsidian 进程链下）→ 复用该会话之前抓对过的宿主，
        // 不回退桌面版；否则光晕的 activeHosts 记成桌面版，切回 Obsidian 匹配不上、熄不掉
        // source 参数即 AgentKind 的 rawValue（claude/codex/kimi/grok），支持光晕的家统一走这一条路
        guard let kind = source.flatMap(AgentKind.init(rawValue:)), kind.supportsGlow else { return }
        let effectiveHost = (host?.isEmpty == false) ? host
            : env?.agentSessions.knownHost(for: session, source: kind)
        glowController?.notifyCompletion(kind, host: effectiveHost)
        env?.agentSessions.markTurnEnded(session: session, source: kind, host: host)
    }

    /// 应用更名（NotchHub → ProNotch，bundle id 一并变更）的一次性数据搬家：
    /// 配置域整体拷贝、数据目录改名、钥匙串条目迁移，必须先于各 Store 初始化。
    ///
    /// 三步分别记结果，**全部达到「成功或无需迁移」才置完成标记**。
    /// 原先无条件置 true：钥匙串首启弹授权框被用户点了拒绝，这一次就永久放弃，
    /// 旧 service 下的 Key 再也搬不过来——而用户看到的只是「API Key 不见了」
    private static func migrateFromNotchHubIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateFromNotchHub") else { return }

        // 1. 旧配置域整体拷入新域（新域已有的键不覆盖）。纯内存操作，无失败路径
        if let legacy = defaults.persistentDomain(forName: KeychainStore.legacyService) {
            var copied = 0
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
            AppLog.app.info("已从旧版配置迁移 \(copied) 项设置")
        }

        // 2. 数据目录（剪贴板历史 / 话术库）随应用名改名。失败保留旧目录，不置完成标记
        var directoryOK = true
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let oldDir = base.appendingPathComponent("NotchHub")
            let newDir = base.appendingPathComponent("ProNotch")
            // 新目录已存在时不覆盖：那是当前版本正在用的数据
            if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
                do {
                    try fm.moveItem(at: oldDir, to: newDir)
                    AppLog.app.info("数据目录已迁移")
                } catch {
                    directoryOK = false
                    AppLog.app.error("数据目录迁移失败（旧目录已保留，下次启动重试）: \(LogRedaction.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                }
            }
        }

        // 3. 钥匙串条目搬到新 service（事务式：读回校验通过才删旧值）
        let keychainReport = KeychainStore.migrateLegacyService()

        guard directoryOK, keychainReport.isComplete else {
            AppLog.app.info("迁移未全部完成，保留重试标记，下次启动继续")
            return
        }
        defaults.set(true, forKey: "didMigrateFromNotchHub")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前清理子进程（caffeinate）、监听与窗口
        env?.clipboard.stop()
        env?.chat.stopStreaming()
        env?.quickActions.stop()
        env?.memory.stop()
        windowControllers.forEach { $0.close() }
    }

    @objc func openSettings() {
        guard let glowController else { return }
        settingsWindow.show(settings: env.settings, chatStore: env.chat, glow: glowController,
                            updates: updateChecker, weather: env.weather, snippets: env.snippets)
    }

    /// AI 闪问快捷键：未展开→展开到闪问并聚焦输入框；已展开在别的页→切到闪问；已在闪问→收起
    @objc func toggleChatPanel() {
        guard let wc = windowControllers.first else { return }
        let vm = wc.viewModel
        if vm.isExpanded, vm.activeTab == .chat {
            vm.collapseNow()
            return
        }
        vm.activeTab = .chat
        vm.expandProgrammatically()
        // 展开动画落定、面板成为 key 后聚焦输入框，直接打字
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.env.chat.focusInputTick += 1
        }
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

    @objc private func screenModeChanged() {
        setupNotchWindow()
    }

    @objc private func screenParametersChanged() {
        // 显示器排列 / 分辨率变化时，系统会成批发送通知，且触发瞬间
        // NSScreen.screens 可能是中间态（坐标尚未稳定）——立即重建会把面板
        // 定位到错误坐标。故防抖：合并多次通知，延迟到布局稳定后再用最终坐标重建。
        pendingScreenRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mode = self.env.settings.notchScreenMode
            let rects = NotchGeometry.screens(for: mode).map { NotchGeometry.notchRect(on: $0) }
            if rects == self.windowControllers.map(\.viewModel.notchRect) { return }
            self.setupNotchWindow()
        }
        pendingScreenRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 按「显示屏幕」设置为选中的屏各建一个刘海面板：有物理刘海的贴刘海，没有的
    /// （外接屏 / 扩展屏）在顶部正中模拟热区。数据层共享，展开状态各自独立。
    private func setupNotchWindow() {
        windowControllers.forEach { $0.close() }
        windowControllers = NotchGeometry.screens(for: env.settings.notchScreenMode).map { screen in
            NotchWindowController(screen: screen, env: env)
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
        usageToggle.state = env.settings.showUsageInMenuBar ? .on : .off
        menu.addItem(usageToggle)
        menu.addItem(.separator())

        // 顶部「发现新版本」项：默认隐藏，检查到新版才显示
        let updateItem = NSMenuItem(title: "↓ 发现新版本",
                                    action: #selector(UpdatePresenter.openLatestRelease), keyEquivalent: "")
        updateItem.target = updatePresenter
        updateItem.image = emptyImage
        updateItem.isHidden = true
        menu.addItem(updateItem)
        let updateSep = NSMenuItem.separator()
        updateSep.isHidden = true
        menu.addItem(updateSep)
        updatePresenter.attachMenu(item: updateItem, separator: updateSep)

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
                                         action: #selector(UpdatePresenter.checkManually), keyEquivalent: "")
        checkUpdateItem.target = updatePresenter
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

        // 额度菜单栏是独立一条 NSStatusItem，自成一套显隐/刷新/弹面板逻辑（见 UsageStatusItemController）
        let usageBar = UsageStatusItemController(env: env)
        usageBar.onVisibilityChanged = { [weak usageToggle] on in
            usageToggle?.state = on ? .on : .off
        }
        usageBar.start()
        usageStatusItem = usageBar
    }

    // MARK: - 独立「额度」菜单栏项（可开关）

    @objc private func toggleUsageMenuBar() {
        // 只翻状态：持久化与应用统一走 SettingsStore didSet → 通知回来（设置页开关同一条链）
        env.settings.showUsageInMenuBar.toggle()
    }

    /// 恶劣天气预警兜底：预警开着才跑——即使两侧功能区都没配天气（没了 10 秒心跳），
    /// 也每 15 分钟刷一次数据供扫描。已授权定位才刷，绝不在后台弹授权框；
    /// store 内置节流，与 slot 心跳撞车也只会实际请求一次
    private func applyWeatherTimerState() {
        let alertsOn = !WeatherAlertType.enabledSet().isEmpty
        if alertsOn, weatherTimer == nil {
            weatherTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.env.weather.refreshIfAuthorized() }
            }
            env.weather.refreshIfAuthorized()
        } else if !alertsOn, let t = weatherTimer {
            t.invalidate()
            weatherTimer = nil
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
            // 通知里的网址虽是自己塞的，打开前仍过一遍策略——「打开网址」这个出口只留一道闸
            if let urlString {
                NSWorkspace.shared.open(ReleaseURLPolicy.trusted(URL(string: urlString)))
            }
        }
        completionHandler()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 打开菜单栏下拉时强制拉一次最新额度（不等 5 分钟兜底）
    func menuWillOpen(_ menu: NSMenu) {
        env.usage.refresh(force: true)
    }
}
