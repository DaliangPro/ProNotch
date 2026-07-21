import AppKit
import SwiftUI

/// AppDelegate 的调试面孔：命令行触发的功能验证入口，以及生成 README 配图 /
/// 对齐核查图的离屏渲染。
///
/// 这些和应用怎么跑起来无关，只和「怎么验证它跑对了」有关，所以从 AppDelegate.swift
/// 里分出来——那边只留应用本身的生命周期。
///
/// 注意两类代码的编译条件不同：
/// - **跨进程调试通道**（`setupDebugChannels`）只在 DEBUG 构建注册。正式版不能暴露
///   任何可被本机其他进程远程触发的接口。
/// - **离屏渲染**（`debugSnapshotPanel` / `snapshotSettings`）正式版也编译。它们必须用
///   /Applications 里的正式签名实例跑：钥匙串 ACL 已授权，ChatStore 的后台 Key 回填
///   才不会弹授权框（debug 裸二进制会弹）。
extension AppDelegate {

    // MARK: - 跨进程调试通道

    func setupDebugChannels() {
        #if DEBUG
        let center = DistributedNotificationCenter.default()
        // 展开/收起：不靠鼠标悬停即可验证
        center.addObserver(self, selector: #selector(debugToggle),
                           name: NSNotification.Name("com.daliangpro.ProNotch.toggle"), object: nil)
        // 把当前窗口内容渲染成 PNG，无需屏幕录制权限即可验证 UI
        center.addObserver(self, selector: #selector(debugSnapshot),
                           name: NSNotification.Name("com.daliangpro.ProNotch.snapshot"), object: nil)
        // 走真实代码路径启动计算器，验证启动台逻辑
        center.addObserver(self, selector: #selector(debugTestLaunch),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testlaunch"), object: nil)
        // 循环切换标签页 / 把历史第一条复制回剪贴板
        center.addObserver(self, selector: #selector(debugNextTab),
                           name: NSNotification.Name("com.daliangpro.ProNotch.nexttab"), object: nil)
        center.addObserver(self, selector: #selector(debugTestPaste),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testpaste"), object: nil)
        // 走真实代码路径发送一条 AI 对话消息 / 拉取模型列表
        center.addObserver(self, selector: #selector(debugTestChat),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testchat"), object: nil)
        center.addObserver(self, selector: #selector(debugTestModels),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testmodels"), object: nil)
        // 执行一次联网搜索验证搜索链路
        center.addObserver(self, selector: #selector(debugTestSearch),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testsearch"), object: nil)
        // 探测 SkyLight 外观接口可用性
        center.addObserver(self, selector: #selector(debugTestTheme),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testtheme"), object: nil)
        // 切换防休眠 / 打开设置窗口
        center.addObserver(self, selector: #selector(debugTestCaffeinate),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testcaffeinate"), object: nil)
        center.addObserver(self, selector: #selector(openSettings),
                           name: NSNotification.Name("com.daliangpro.ProNotch.opensettings"), object: nil)
        center.addObserver(self, selector: #selector(debugTestFullscreen),
                           name: NSNotification.Name("com.daliangpro.ProNotch.testfullscreen"), object: nil)
        center.addObserver(self, selector: #selector(debugSnapshotSwitcher),
                           name: NSNotification.Name("com.daliangpro.ProNotch.snapswitcher"), object: nil)
        center.addObserver(self, selector: #selector(debugSnapshotToolbar),
                           name: NSNotification.Name("com.daliangpro.ProNotch.snaptoolbar"), object: nil)
        // 驱动 Codex notify 转发器接入 / 卸载，验证软件层接入
        center.addObserver(self, selector: #selector(debugCodexHookOn),
                           name: NSNotification.Name("com.daliangpro.ProNotch.codexhookon"), object: nil)
        center.addObserver(self, selector: #selector(debugCodexHookOff),
                           name: NSNotification.Name("com.daliangpro.ProNotch.codexhookoff"), object: nil)
        #endif
    }

    // MARK: - 转发给刘海窗口的验证入口

    @objc func debugToggle() { windowControllers.first?.viewModel.debugToggle() }
    @objc func debugSnapshot() { windowControllers.first?.saveSnapshot() }
    @objc func debugTestFullscreen() { windowControllers.first?.debugTestFullscreen() }
    @objc func debugTestCaffeinate() { windowControllers.first?.debugTestCaffeinate() }
    @objc func debugTestTheme() { windowControllers.first?.debugTestTheme() }
    @objc func debugTestSearch() { windowControllers.first?.debugTestSearch() }
    @objc func debugTestModels() { windowControllers.first?.debugTestModels() }
    @objc func debugTestChat() { windowControllers.first?.debugTestChat() }
    @objc func debugNextTab() { windowControllers.first?.debugNextTab() }
    @objc func debugTestPaste() { windowControllers.first?.debugTestPaste() }
    @objc func debugTestLaunch() { windowControllers.first?.debugTestLaunch() }

    /// 调试用：走真实路径接入 / 卸载 Codex 的 notify 转发器
    @objc func debugCodexHookOn() {
        AppLog.debugTools.debug("调试：Codex notify 接入 = \(GlowHookInstaller.setInstalled(.codex, true))")
    }

    @objc func debugCodexHookOff() {
        AppLog.debugTools.debug("调试：Codex notify 卸载 = \(GlowHookInstaller.setInstalled(.codex, false))")
    }

    // MARK: - README 配图

    /// 调试用：离屏渲染剪贴板切换器到 PNG（生成 README 配图，无需屏幕录制权限）
    @objc func debugSnapshotSwitcher() {
        renderSwitcherSnapshot(clipboard: env.clipboard, snippets: env.snippets)
    }

    /// 取显式入参而非读 `env`：-snapshotDocs 那条路径跑在建 env 之前
    /// （配图渲染必须早于 ChatStore，否则同步读钥匙串会弹框阻塞主线程）
    func renderSwitcherSnapshot(clipboard: ClipboardStore, snippets: SnippetStore) {
        let root = ZStack {
            Color(white: 0.08)
            ClipboardSwitcherView(store: clipboard, snippets: snippets, controller: .shared)
                .environmentObject(clipboard)
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
            AppLog.debugTools.debug("剪贴板切换器快照已保存")
        }
    }

    /// 调试用：离屏渲染超级截图工具栏到 PNG（生成 README 配图）
    @objc func debugSnapshotToolbar() {
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
            AppLog.debugTools.debug("超级截图工具栏快照已保存")
        }
    }

    // MARK: - 对齐核查图

    /// 对齐核查：离屏渲染展开面板四页到 /tmp/pronotch-panel-<页>.png，
    /// 叠红色基准线（左 x=43=20+pageHInset、右 x=917 对称），在图上直接检查
    /// 「各页左缘是否压线、右侧留白是否对称」。渲染完自动退出进程
    @objc func debugSnapshotPanel() {
        // 假刘海几何取 14 寸 MBP 典型值；挂进离屏 window 让 onAppear/pageEntrance 生效
        let vm = NotchViewModel(notchRect: CGRect(x: 380, y: 0, width: 200, height: 38))
        vm.debugToggle()   // 置 isExpanded=true：各页 pageEntrance 才会翻 played、内容可见
        let size = vm.expandedShapeSize
        let guide = 20 + ExpandedContentView.pageHInset
        let pages: [(NotchViewModel.Tab, String)] = [(.launcher, "launcher"), (.chat, "chat"),
                                                     (.usage, "usage"), (.agent, "agent"),
                                                     (.widgets, "widgets")]
        var index = 0
        // 收起态渲染：黑形状在灰底上才看得见，独立 vm（不展开）跑真实容器视图
        func renderCollapsed() {
            let cvm = NotchViewModel(notchRect: CGRect(x: 380, y: 0, width: 200, height: 38))
            // 渲染实例没有 NotchWindowController 的设置联动，这里手动同步一次
            // （可用 -notchLeftSlot none -notchRightSlot none 参数验证「两侧全关」形态）
            cvm.sideSlotsActive = self.env.settings.sideSlotsActive
            let root = ZStack(alignment: .top) {
                Color(white: 0.3)
                NotchContainerView()
            }
            .environmentObject(cvm)
            .injecting(self.env)
            .frame(width: size.width, height: size.height)
            let hosting = NSHostingView(rootView: root)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/pronotch-panel-collapsed.png"))
                        AppLog.debugTools.debug("面板快照: collapsed")
                    }
                }
                win.close()
                NSApp.terminate(nil)
            }
        }
        func renderNext() {
            guard index < pages.count else { renderCollapsed(); return }
            let (tab, name) = pages[index]; index += 1
            vm.activeTab = tab   // 每页新建视图树：displayedTab 初始 nil 直接显示该页，无过渡
            let root = ZStack(alignment: .top) {
                Color.black
                ExpandedContentView()
            }
            .environmentObject(vm)
            .injecting(self.env)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(Color.red.opacity(0.85)).frame(width: 1).padding(.leading, guide)
            }
            .overlay(alignment: .topTrailing) {
                Rectangle().fill(Color.red.opacity(0.85)).frame(width: 1).padding(.trailing, guide)
            }
            .frame(width: size.width, height: size.height)
            let hosting = NSHostingView(rootView: root)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false   // ARC 下 close 默认连带 release，池排空时会过度释放崩溃
            win.contentView = hosting   // 进 window 树 onAppear 才触发；不 orderFront，离屏
            hosting.layoutSubtreeIfNeeded()
            // pageEntrance 0.10s 后翻 played；cacheDisplay 渲模型终值，不必等动画播完
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/pronotch-panel-\(name).png"))
                        AppLog.debugTools.debug("面板快照: \(name, privacy: .public)")
                    }
                }
                win.close()
                renderNext()
            }
        }
        renderNext()
    }

    /// 对齐核查：把设置窗口按真实尺寸离屏渲染成 PNG（不打开窗口、不需屏幕录制权限）。
    /// 分区由 -section 指定（如 -section 刘海面板），默认「通用」；
    /// 尺寸取 SwiftUI 自算值，跟着 SettingsView 的 frame 走，不写死
    func snapshotSettings(settings: SettingsStore, chat: ChatStore, glow: GlowController,
                          weather: WeatherStore, snippets: SnippetStore) {
        let args = CommandLine.arguments
        let section = args.firstIndex(of: "-section")
            .flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            .flatMap(SettingsView.Section.init(rawValue:)) ?? .general
        let root = SettingsView(initialSection: section)
            .environmentObject(settings)
            .environmentObject(chat)
            .environmentObject(glow)
            .environmentObject(updateChecker)
            .environmentObject(weather)
            .environmentObject(snippets)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        // 挂进离屏窗口：onAppear 与入场动画要有 window 才跑，否则渲出来是初始态
        let win = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let out = "/tmp/pronotch-settings-\(section.rawValue).png"
                    try? data.write(to: URL(fileURLWithPath: out))
                    AppLog.debugTools.debug("设置窗口快照已保存: \(LogRedaction.lastComponent(out), privacy: .public)")
                }
            }
            NSApp.terminate(nil)
        }
    }
}
