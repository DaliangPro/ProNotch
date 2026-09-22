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
            ratioActive: false,
            boxActive: false, hlActive: false, textActive: false, penActive: false, arrowActive: false, mosaicActive: false,
            noteActive: false, flowActive: false, wmActive: false,
            translateTitle: "翻译", translateActive: false,
            onRatio: {},
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

    // MARK: - 菜单栏额度栏宽度候选

    /// 额度栏瘦身候选（`-snapshotMenuBar`）：按菜单栏真实字号把几种写法渲成一张对照图，
    /// 逐行标出真实占宽，以及换上它之后整条菜单栏还溢不溢出。
    ///
    /// 宽度这次是硬指标而非观感偏好：内置刘海屏的菜单栏被刘海从中切开，右侧只剩 772pt
    /// 能放状态项，而额度栏 162pt 是全场最宽的一项——一旦溢出，被系统整项丢掉的就是它
    func snapshotMenuBar(settings: SettingsStore) {
        // 2026-07-26 在大梁老师这台机实测：内置屏 1728pt，刘海横跨 771–956（185pt），
        // 右侧可用 772pt；当时全部状态项共 1081pt，其中额度栏 170pt。
        // 后两个数随菜单栏上的 App 增减而变，复测后用 -menuBarOthers / -menuBarUsage 覆盖
        let available: CGFloat = 772
        let d = UserDefaults.standard
        let others = CGFloat((d.object(forKey: "menuBarOthers") as? Double) ?? 911)
        let liveUsage = CGFloat((d.object(forKey: "menuBarUsage") as? Double) ?? 170)
        var kinds = UsageStatusItemController.menuBarKinds(settings)
        if kinds.isEmpty { kinds = Array(AgentKind.allCases.filter(\.supportsQuota).prefix(3)) }
        let pcts: [Double] = [5, 55, 0]   // 用他此刻菜单栏上的真实读数，基准行才与肉眼所见一致

        /// 通用拼法：图标 + 数字。`lead` 是图标与数字之间、`sep` 是各家之间
        func compose(icon: CGFloat, lead: String, suffix: String, sep: String,
                     only: AgentKind? = nil) -> NSAttributedString {
            let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            let out = NSMutableAttributedString()
            for (i, kind) in kinds.enumerated() where only == nil || only == kind {
                let pct = pcts[i % pcts.count]
                if out.length > 0 { out.append(NSAttributedString(string: sep, attributes: base)) }
                let att = NSTextAttachment()
                att.image = UsageStatusItemController.brandImage(
                    kind.polys, tint: UsageStatusItemController.brandTints[kind] ?? .systemGray, size: icon)
                att.bounds = CGRect(x: 0, y: -icon * 0.26, width: icon, height: icon)
                out.append(NSAttributedString(attachment: att))
                var seg = base
                seg[.foregroundColor] = UsageStatusItemController.pctColor(pct)
                out.append(NSAttributedString(string: "\(lead)\(Int(pct.rounded()))\(suffix)", attributes: seg))
            }
            return out
        }
        /// 数字直接画进品牌色块，一家只占一个方块——最省，代价是认色不认 logo
        func badges(size: CGFloat, sep: String) -> NSAttributedString {
            let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            let out = NSMutableAttributedString()
            for (i, kind) in kinds.enumerated() {
                if out.length > 0 { out.append(NSAttributedString(string: sep, attributes: base)) }
                let att = NSTextAttachment()
                att.image = Self.badgeImage(pcts[i % pcts.count],
                                            tint: UsageStatusItemController.brandTints[kind] ?? .systemGray, size: size)
                att.bounds = CGRect(x: 0, y: -size * 0.26, width: size, height: size)
                out.append(NSAttributedString(attachment: att))
            }
            return out
        }

        let busiest = kinds.enumerated().max { pcts[$0.offset % pcts.count] < pcts[$1.offset % pcts.count] }?.element
        let variants: [(String, String, NSAttributedString)] = [
            ("① 现状", "图标17 · NN% · 双空格", compose(icon: 17, lead: " ", suffix: "%", sep: "  ")),
            ("② 去百分号", "% 号删掉，其余不动", compose(icon: 17, lead: " ", suffix: "", sep: "  ")),
            ("③ 紧凑", "图标15 · 数字贴紧 · 单空格", compose(icon: 15, lead: "", suffix: "", sep: " ")),
            ("④ 极简三家", "图标13 · 数字贴紧 · 无分隔", compose(icon: 13, lead: "", suffix: "", sep: "")),
            ("⑤ 数字嵌色块", "数字画进色块 · 无 logo", badges(size: 19, sep: " ")),
            ("⑥ 只显示最忙", "只留占用最高那家", compose(icon: 17, lead: " ", suffix: "%", sep: "  ", only: busiest)),
        ]
        // 系统在标题两侧另加固定内边距：拿「现状」的实测占宽反推，其余候选同口径换算
        let pad = liveUsage - variants[0].2.size().width

        let rowH: CGFloat = 46, headH: CGFloat = 64, titleX: CGFloat = 200
        // 右列起点让过最宽那条色条，免得数字压在条上
        let widths = variants.map { $0.2.size().width + pad }
        let rightX = titleX + (widths.max() ?? 0) + 28
        let W: CGFloat = rightX + 300
        let H = headH + rowH * CGFloat(variants.count) + 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: W, height: H)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.11, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, color: NSColor = .white) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
        }
        text("菜单栏额度栏宽度候选（刘海屏内置显示器）", 16, H - 28, size: 14)
        let budget = available - others
        text(budget > 0
             ? "刘海右侧可用 \(Int(available))pt ｜ 其余状态项占 \(Int(others))pt ｜ 留给额度栏的预算 ≤ \(Int(budget))pt"
             : "刘海右侧可用 \(Int(available))pt ｜ 其余状态项已占 \(Int(others))pt ｜ 预算为负：额度栏归零仍溢出 \(Int(-budget))pt",
             16, H - 50, color: budget > 0 ? NSColor(white: 0.6, alpha: 1) : .systemRed)

        for (i, v) in variants.enumerated() {
            let y = H - headH - rowH * CGFloat(i + 1) + 12
            let w = v.2.size().width + pad
            let fits = w <= budget
            text(v.0, 16, y + 12, size: 12)
            text(v.1, 16, y - 2, size: 9, color: NSColor(white: 0.45, alpha: 1))
            // 灰底条＝这一项在菜单栏上实际占掉的地盘
            NSColor(white: 0.26, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: titleX, y: y - 3, width: w, height: 26),
                         xRadius: 5, yRadius: 5).fill()
            v.2.draw(at: NSPoint(x: titleX + pad / 2, y: y + 2))
            text("\(Int(w.rounded()))pt", rightX, y + 12, size: 12,
                 color: fits ? .systemGreen : .systemRed)
            text(fits ? "放得下（余 \(Int((budget - w).rounded()))pt）"
                      : "仍溢出 \(Int((w - budget).rounded()))pt",
                 rightX, y - 2, size: 9, color: NSColor(white: 0.5, alpha: 1))
        }
        // 预算线：灰底条越过这条竖线就是放不下
        NSColor.systemRed.withAlphaComponent(0.55).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: titleX + max(budget, 0), y: 8))
        line.line(to: NSPoint(x: titleX + max(budget, 0), y: H - headH + 4))
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/pronotch-menubar-widths.png"))
            AppLog.debugTools.debug("额度栏宽度候选已渲染")
        }
    }

    /// 候选⑤用：把百分比数字直接画进品牌色块（不画 logo），一家一个方块
    private static func badgeImage(_ pct: Double, tint: NSColor, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                     xRadius: size * 0.3, yRadius: size * 0.3).fill()
        let s = "\(Int(pct.rounded()))" as NSString
        let at: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size * 0.58, weight: .semibold),
            .foregroundColor: NSColor.white]
        let sz = s.size(withAttributes: at)
        s.draw(at: NSPoint(x: (size - sz.width) / 2, y: (size - sz.height) / 2), withAttributes: at)
        img.unlockFocus()
        return img
    }

    // MARK: - 对齐核查图

    /// 对齐核查：离屏渲染展开面板四页到 /tmp/pronotch-panel-<页>.png，
    /// 叠红色基准线（左 x=43=20+pageHInset、右 x=917 对称），在图上直接检查
    /// 「各页左缘是否压线、右侧留白是否对称」。渲染完自动退出进程
    @objc func debugSnapshotPanel() {
        // -demoQuota：摆一份额度数据（额度页与收起态都要用，所以排在两条渲染之前）。
        // 额度是联网取的，快照那 0.6 秒等不到，不给这条口子就永远只能拍到转圈
        if CommandLine.arguments.contains("-demoQuota") { env.usage.preview(Self.demoQuota()) }

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
            cvm.sideSlotWidth = NotchSlot.fixedSideWidth
            // -notchSlotBusy：把 Agent 槽位置成「工作中」再渲染。
            // 工作状态只由 hook 回调置入，不造一个的话快照永远只拍得到空闲态
            if CommandLine.arguments.contains("-notchSlotBusy") {
                for kind in AgentKind.allCases {
                    self.env.agentActivity.markBusy(kind, session: "snapshot")
                }
            }
            // -notchAlertCard [大雨|冻雨|大雪|雷暴|大风]：造一条天气预警再渲染。
            // 两张大卡共用 NotchGrownCard，改动其中一张的壳会同时波及另一张，
            // 得有个不开 GUI 就能对照的口子
            if let i = CommandLine.arguments.firstIndex(of: "-notchAlertCard") {
                let label = CommandLine.arguments[safe: i + 1] ?? ""
                let picked = WeatherStore.previewAlerts.first { $0.label == label }
                self.env.weather.preview((picked ?? WeatherStore.previewAlerts[0]).alert)
            }
            // -notchCardScene <任务完成|任务完成无项目>：造一张任务完成卡再渲染（场景表见 cardScene）。
            // 这张卡只由 hook 回调触发，链路要在终端里真跑一次才走得到——
            // 而它正是要给大梁老师看观感的，必须有条不开终端就能拍到的路
            if let i = CommandLine.arguments.firstIndex(of: "-notchCardScene") {
                self.env.agentCompletion.present(Self.cardScene(CommandLine.arguments[safe: i + 1] ?? ""))
            }
            // -notchHUD <音量|静音|亮度> [0…1]：摆一帧音量/亮度提示再渲染。
            // 这张卡只由真实按键触发，而按键要先拿到辅助功能权限、还会真的改音量，
            // 拍观感不该付这个代价——留个不碰硬件就能拍到的口子
            var hudTag = ""
            if let i = CommandLine.arguments.firstIndex(of: "-notchHUD") {
                hudTag = CommandLine.arguments[safe: i + 1] ?? "音量"
                let value = CommandLine.arguments[safe: i + 2].flatMap(Double.init) ?? 0.62
                self.env.systemHUD.preview(Self.hudPreview(hudTag, value))
            }
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
                        // 带 -notchHUD 时按档位分文件存，连着跑几档才不会互相覆盖
                        let name = hudTag.isEmpty ? "collapsed" : "hud-\(hudTag)"
                        try? data.write(to: URL(fileURLWithPath: "/tmp/pronotch-panel-\(name).png"))
                        AppLog.debugTools.debug("面板快照: \(name, privacy: .public)")
                    }
                }
                self.probeGrownCardHits(window: win, vm: cvm, size: size)
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

    /// 菜单栏额度面板（`-snapshotUsagePanel [-usageTab <序号>]`，默认第 1 页即 Claude）：
    /// 用演示数据渲染，核对额度窗口的排布。
    /// 这个面板平时只能点出来看，而点出来就没法截图核对
    func snapshotUsagePanel(store: UsageStore, settings: SettingsStore) {
        store.preview(Self.demoQuota())
        let args = CommandLine.arguments
        let tab = args.firstIndex(of: "-usageTab")
            .flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 1
        let root = UsageMenuView(store: store, settings: settings, initialTab: tab)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let win = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/pronotch-usage-panel.png"))
                    AppLog.debugTools.debug("额度面板快照已保存")
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// `-demoQuota` 的演示数据：形状照 2026-09-17 真实响应，含 Claude 的 Fable 这类限定模型额度
    private nonisolated static func demoQuota() -> UsageSnapshot {
        func w(_ pct: Double, _ minutes: Int, _ hours: Double, scope: String? = nil) -> QuotaWindow {
            QuotaWindow(usedPercent: pct, usedTokens: nil,
                        resetsAt: Date().addingTimeInterval(hours * 3600),
                        windowMinutes: minutes, isEstimate: false, scopeName: scope)
        }
        func tasks(_ names: [(String, Double)]) -> [TaskUsage] {
            names.enumerated().map { i, t in
                TaskUsage(id: "demo-\(i)", name: t.0, tokens: 0, percentOfTotal: t.1)
            }
        }
        var claude = ServiceQuota(plan: "Max 20x", primary: w(4, 300, 4),
                                  secondary: w(29, 10080, 40), dataAt: Date())
        claude.scopedWindows = [w(37, 10080, 40, scope: "Fable")]
        claude.topTasks = tasks([("ProNotch 额度页", 9), ("刘海弹窗", 7), ("钩子迁移", 5),
                                 ("截图文字工具", 4), ("翻译多套配置", 3)])
        var codex = ServiceQuota(plan: "Pro", primary: w(65, 10080, 50), dataAt: Date())
        codex.topTasks = tasks([("Codex 对话", 30), ("代码检查", 12), ("文档整理", 8)])
        var grok = ServiceQuota(plan: "SuperGrok", primary: w(18, 10080, 100), dataAt: Date())
        grok.topTasks = tasks([("Grok 会话", 10)])
        var kimi = ServiceQuota(plan: "Allegretto", primary: w(0, 300, 3),
                                secondary: w(39, 10080, 20), dataAt: Date())
        kimi.topTasks = tasks([("Kimi 会话", 20), ("资料整理", 9)])
        return UsageSnapshot(codex: codex, claude: claude, grok: grok, kimi: kimi)
    }

    /// `-notchHUD` 的档位表：档位名 → 要摆上去的那一帧
    private nonisolated static func hudPreview(_ tag: String, _ value: Double) -> SystemHUDStore.Reading {
        switch tag {
        case "静音":   return .init(channel: .volume, value: 0, muted: true)
        case "亮度":   return .init(channel: .brightness, value: value, muted: false)
        default:      return .init(channel: .volume, value: value, muted: false)
        }
    }

    /// `-notchCardScene` 的场景表。会话名用预览会话：点击探针按到卡时只收卡、不真的跳去别的 App
    private static func cardScene(_ name: String) -> AgentCompletionNotice {
        switch name {
        case "任务完成无项目":
            // 老脚本没带项目名、会话表里也查不到：项目那行退一句通用文案
            return AgentCompletionNotice(source: .codex, session: AgentCompletionNotice.previewSession,
                                         host: nil, project: "", tintHex: PrefDefault.glowCodexColor)
        default:
            // 宿主给真实 bundle id，卡底那行才拍得出「点击回到 Ghostty」
            return AgentCompletionNotice(source: .claude, session: AgentCompletionNotice.previewSession,
                                         host: "com.mitchellh.ghostty", project: "ProNotch",
                                         tintHex: PrefDefault.glowClaudeColor)
        }
    }

    /// 点击可达性核查（`-notchCardHitProbe`，需与 `-notchCardScene` 同用）：
    /// 在**真实视图树**上按网格合成鼠标点击，报告第一个真正点到卡的点。
    ///
    /// 为什么必须有这个：离屏渲染只能证明卡「长得对」，证明不了「点得到」。
    /// 大卡垫在刘海黑形状底下，而 `clipShape` **只裁画面、不裁点击**——
    /// 黑形状的布局恒为整块面板尺寸（见 NotchContainerView 的注释），被裁掉看不见的那片黑
    /// 照样把落在卡上的每一次点击吃光，实机表现就是「卡弹出来了，但点不动」。
    /// 这个探针是唯一能不动手就照出这类病的口子。
    ///
    /// 自下而上、自左向右扫，一旦卡被点掉就算按到，立即停手
    private func probeGrownCardHits(window: NSWindow, vm: NotchViewModel, size: CGSize) {
        guard CommandLine.arguments.contains("-notchCardHitProbe") else { return }
        // 事件路由要求窗口在场；挪到屏幕外再现身，避免在大梁老师眼前闪一下
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFrontRegardless()
        let cardWidth = AgentCompletionCardView.cardWidth
        let cardHeight = vm.notchRect.height + NotchGrownCardSize.agent.height
        var hit: NSPoint?
        outer: for y in stride(from: size.height - cardHeight, through: size.height, by: 8) {
            for x in stride(from: (size.width - cardWidth) / 2,
                            through: (size.width + cardWidth) / 2, by: 20) {
                let point = NSPoint(x: x, y: y)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    window.sendEvent(event)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if self.env.agentCompletion.notice == nil { hit = point; break outer }
            }
        }
        if let hit {
            AppLog.debugTools.info("""
                卡点得到：窗口坐标 (\(Int(hit.x), privacy: .public), \
                \(Int(hit.y), privacy: .public))
                """)
        } else {
            AppLog.debugTools.error("卡点不到：整卡区域的合成点击全被吞掉")
        }
    }

    /// 对齐核查：把设置窗口按真实尺寸离屏渲染成 PNG（不打开窗口、不需屏幕录制权限）。
    /// 分区由 -section 指定（如 -section 功能组件），默认「通用」；-height 加高窗口拍长页面下半截；
    /// 尺寸取 SwiftUI 自算值，跟着 SettingsView 的 frame 走，不写死
    func snapshotSettings(settings: SettingsStore, chat: ChatStore, glow: GlowController,
                          weather: WeatherStore, snippets: SnippetStore) {
        let args = CommandLine.arguments
        // -sheetModels N：改渲染服务商弹层并塞 N 个假模型，核对模型列表限高
        //（2026-09-22 百炼 261 个模型曾把弹层撑到无限长；弹层不在设置窗树里，逐页快照拍不到）
        if let n = args.firstIndex(of: "-sheetModels")
            .flatMap({ args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }) {
            let sheet = EndpointSheet(
                name: .constant("百炼"), baseURL: .constant("https://dashscope.aliyuncs.com/compatible-mode/v1"),
                apiKey: .constant("sk-demo"),
                models: (0..<n).map { "demo-model-\($0 + 1)" }, customModels: ["demo-model-1"],
                fetching: false, statusText: "连接正常 · \(n) 个模型", statusColor: SettingsTheme.success,
                canDelete: true, onFetch: {}, onAddModel: { _ in }, onRemoveModel: { _ in },
                onTest: {}, onDelete: {}, onCancel: {}, onDone: {})
            renderSnapshot(sheet, to: "/tmp/pronotch-sheet-\(n).png")
            return
        }
        let section = args.firstIndex(of: "-section")
            .flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            .flatMap(SettingsSection.init(rawValue:)) ?? .general
        let height = args.firstIndex(of: "-height")
            .flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 540
        let root = SettingsView(initialSection: section, windowHeight: height)
            .environmentObject(settings)
            .environmentObject(chat)
            .environmentObject(glow)
            .environmentObject(updateChecker)
            .environmentObject(weather)
            .environmentObject(snippets)
        renderSnapshot(root, to: "/tmp/pronotch-settings-\(section.rawValue).png")
    }

    /// 把任意 SwiftUI 视图按自算尺寸离屏渲染成 PNG 后退出进程
    private func renderSnapshot(_ view: some View, to out: String) {
        let hosting = NSHostingView(rootView: view)
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
                    try? data.write(to: URL(fileURLWithPath: out))
                    AppLog.debugTools.debug("离屏快照已保存: \(LogRedaction.lastComponent(out), privacy: .public)")
                }
            }
            NSApp.terminate(nil)
        }
    }
}
