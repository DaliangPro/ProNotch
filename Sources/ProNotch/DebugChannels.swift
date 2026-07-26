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
            // -notchCardScene <场景名>：造一条「等你拍板」再渲染（场景表见 cardScene）。
            // 这些卡只由 hook 回调触发，链路要在终端里真跑一次才走得到——
            // 而它们正是要给大梁老师看观感的，必须有条不开终端就能拍到的路
            if let i = CommandLine.arguments.firstIndex(of: "-notchCardScene") {
                for notice in Self.cardScene(CommandLine.arguments[safe: i + 1] ?? "") {
                    self.env.agentWait.present(notice, frontmost: nil)
                }
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

    /// 点击可达性核查（`-notchCardHitProbe`，需与 `-notchPermissionCard` 同用）：
    /// 在**真实视图树**上按网格合成鼠标点击，报告第一个真正按下去的点。
    ///
    /// 为什么必须有这个：离屏渲染只能证明卡「长得对」，证明不了「点得到」。
    /// 两种大卡都垫在刘海黑形状底下，而 `clipShape` **只裁画面、不裁点击**——
    /// 黑形状的布局恒为整块面板尺寸（见 NotchContainerView 的注释），被裁掉看不见的那片黑
    /// 照样把落在卡上的每一次点击吃光。最小复现里按钮压根不触发，实机表现就是
    /// 「卡弹出来了，但任何按钮都点不动」。这个探针是唯一能不动手就照出这类病的口子。
    ///
    /// 自下而上、自左向右扫（按钮在卡的最后一行，最左那个是「允许一次」），
    /// 一旦 `agentWait.notice` 被答复清空就算按到，立即停手
    /// 假请求的 id（32 位 hex 才过得了 broker 的校验）。点击探针按到按钮后要靠它清掉自己写下的答复
    /// nonisolated：场景表是纯函数（不碰任何状态），默认参数取这两个值时不该被主线程隔离绊住
    private nonisolated static let probeRequestID = String(repeating: "a", count: 32)
    private nonisolated static let queuedRequestID = String(repeating: "b", count: 32)

    /// `-notchHUD` 的档位表：档位名 → 要摆上去的那一帧
    private nonisolated static func hudPreview(_ tag: String, _ value: Double) -> SystemHUDStore.Reading {
        switch tag {
        case "静音":   return .init(channel: .volume, value: 0, muted: true)
        case "亮度":   return .init(channel: .brightness, value: value, muted: false)
        default:      return .init(channel: .volume, value: value, muted: false)
        }
    }

    /// `-notchCardScene` 的场景表：一个场景 ＝ 上游真实会发来的一种载荷。
    ///
    /// 全部走真实的 `AgentPermissionBroker.parse`——自己 new 一个结构体就绕开了解析规则，
    /// 拍出来的卡也就替不了真实链路说话（详情挑哪个入参、建议认不认得，都在 parse 里）
    private static func cardScene(_ name: String) -> [AgentWaitNotice] {
        func claude(_ payload: String, id: String = probeRequestID) -> AgentWaitNotice? {
            guard let request = AgentPermissionBroker.parse(Data(payload.utf8), id: id) else { return nil }
            return AgentWaitNotice(source: .claude, session: "snapshot", host: nil,
                                   project: request.project, request: request)
        }
        let head = #"{"session_id":"snapshot","cwd":"/Users/x/Coding/ProNotch","#
            + #""hook_event_name":"PermissionRequest","#
        switch name {
        case "多条建议":
            // 实测：往「允许目录」之外写文件时上游一次给两条，粒度还完全不同
            return [claude(head + """
                "tool_name":"Write",\
                "tool_input":{"file_path":"/Users/x/Documents/OrbitOS Vault/日记/2026-07-24.md"},\
                "permission_suggestions":[\
                {"type":"addDirectories","directories":["/Users/x/Documents/OrbitOS Vault"],\
                "destination":"session"},\
                {"type":"setMode","mode":"acceptEdits","destination":"session"}]}
                """)].compactMap { $0 }
        case "无建议":
            // 上游没给建议（危险命令、或它自己也拿不准该写成哪条规则）：不摆假按钮
            return [claude(head + """
                "tool_name":"Bash",\
                "tool_input":{"command":"rm -rf ~/Library/Caches/com.example.app"},\
                "permission_suggestions":[]}
                """)].compactMap { $0 }
        case "长命令":
            // 命令可以是一整篇脚本。详情块写死两行，超出截断——不截就把整块屏幕顶满
            return [claude(head + """
                "tool_name":"Bash",\
                "tool_input":{"command":"find . -name '*.swift' -print0 | xargs -0 \
                grep -n 'AppLog' | awk -F: '{print $1}' | sort -u | \
                while read f; do echo \\"检查 $f\\"; swiftformat --lint \\"$f\\"; done"},\
                "permission_suggestions":[{"type":"addRules","behavior":"allow",\
                "destination":"localSettings",\
                "rules":[{"toolName":"Bash","ruleContent":"find:*"}]}]}
                """)].compactMap { $0 }
        case "MCP工具":
            // MCP 工具入参名五花八门，一个都不命中时压平 JSON 兜底
            return [claude(head + """
                "tool_name":"mcp__obsidian__append_note",\
                "tool_input":{"vault":"OrbitOS Vault","note":"每日回顾","heading":"今天"},\
                "permission_suggestions":[{"type":"addRules","behavior":"allow",\
                "destination":"userSettings",\
                "rules":[{"toolName":"mcp__obsidian__append_note"}]}]}
                """)].compactMap { $0 }
        case "排队中":
            // 两个终端各跑一个很常见。四按钮的卡摞一起按不准，所以排队、答完换下一条
            return [claude(head + """
                "tool_name":"Bash","tool_input":{"command":"git push origin main"},\
                "permission_suggestions":[{"type":"addRules","behavior":"allow",\
                "destination":"localSettings",\
                "rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}]}
                """),
                claude(#"{"session_id":"other","cwd":"/Users/x/Coding/别的项目","#
                    + #""tool_name":"Edit","tool_input":{"file_path":"/tmp/b.swift"}}"#,
                    id: queuedRequestID)].compactMap { $0 }
        case "只提醒Kimi":
            // 别家的中途信号发完就走（收不了答复）：窄卡一张，点它跳到对应终端
            return [AgentWaitNotice(source: .kimi, session: "snapshot", host: nil,
                                    project: "OrbitOS Vault")]
        case "只提醒无项目":
            // cwd 抓空（脚本 sed 没命中）：项目名那行退一句通用文案，不留空行
            return [AgentWaitNotice(source: .claude, session: "snapshot", host: nil, project: "")]
        case "只提醒":
            return [AgentWaitNotice(source: .claude, session: "snapshot", host: nil,
                                    project: "ProNotch")]
        default:
            // 默认「单条建议」：最常见的形态，一条建议并进按钮行
            return [claude(head + """
                "tool_name":"Bash",\
                "tool_input":{"command":"git push origin feature/agent-slots-and-reminder"},\
                "permission_suggestions":[{"type":"addRules","behavior":"allow",\
                "destination":"localSettings",\
                "rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}]}
                """)].compactMap { $0 }
        }
    }

    private func probeGrownCardHits(window: NSWindow, vm: NotchViewModel, size: CGSize) {
        guard CommandLine.arguments.contains("-notchCardHitProbe") else { return }
        // 事件路由要求窗口在场；挪到屏幕外再现身，避免在大梁老师眼前闪一下
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFrontRegardless()
        let cardWidth: CGFloat = 560
        // 卡高随建议条数变（多一条建议多一行），扫描范围跟着算，别写死
        let grown = self.env.agentWait.notice?.request
            .map(AgentWaitCardView.grownHeight(for:)) ?? 176
        let cardHeight = vm.notchRect.height + grown
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
                if self.env.agentWait.notice == nil { hit = point; break outer }
            }
        }
        if let hit {
            AppLog.debugTools.info("""
                卡上按钮点得到：窗口坐标 (\(Int(hit.x), privacy: .public), \
                \(Int(hit.y), privacy: .public))
                """)
        } else {
            AppLog.debugTools.error("卡上按钮点不到：整卡区域的合成点击全被吞掉")
        }
        // 按到按钮就真写了一份答复，而这条请求是假的、没有脚本在等它。
        // 不清掉就是往真实交换目录里留垃圾（要等下次启动的收尾扫到 30 分钟才清）
        for id in [Self.probeRequestID, Self.queuedRequestID] {
            try? FileManager.default.removeItem(
                atPath: GlowHookPaths.production.permissionDir + "/\(id).response.json")
        }
    }

    /// 对齐核查：把设置窗口按真实尺寸离屏渲染成 PNG（不打开窗口、不需屏幕录制权限）。
    /// 分区由 -section 指定（如 -section 功能组件），默认「通用」；
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
