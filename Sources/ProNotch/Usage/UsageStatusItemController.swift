import AppKit
import Combine
import SwiftUI

/// 菜单栏上那条独立的「额度」栏：常驻显示各家 5h 用量百分比，点开是详情卡。
///
/// 它和主菜单栏图标是两个 NSStatusItem——这条可以由用户单独关掉，关掉后
/// 定时刷新一并停机（不再无谓访问 Claude / ChatGPT 接口）。
///
/// 开关状态本身归 `SettingsStore.showUsageInMenuBar` 管：主菜单的勾选项和设置页的
/// 开关改的是同一份，任一处动都会发通知到这里统一应用。本控制器不写这个值，
/// 只读它、并通过 `onVisibilityChanged` 把结果回报给主菜单去同步勾选态。
@MainActor
final class UsageStatusItemController {
    /// 显隐状态变化时回调，供主菜单同步勾选项
    var onVisibilityChanged: ((Bool) -> Void)?

    private let env: AppEnvironment
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var panelMonitor: Any?          // 点面板外收起（其他 App）
    private var panelLocalMonitor: Any?     // 点面板外收起（本 App 其他窗口）
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    init(env: AppEnvironment) {
        self.env = env
    }

    /// 订阅数据变化、按持久化开关显隐额度栏，并挂上两条设置变更通知
    func start() {
        // 数据变化即刷新额度栏标题（定时拉取交给 applyVisibility，只在额度栏显示时跑）
        cancellable = env.usage.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle() }
        applyVisibility()   // 按持久化开关状态显隐额度栏并启停定时刷新
        // 总开关状态归 SettingsStore：主菜单勾选与设置页开关改的是同一份，任一处动这里统一应用
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchUsageMenuBarChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onVisibilityChanged?(self.env.settings.showUsageInMenuBar)
                self.applyVisibility()
            }
        }
        // per-Agent 菜单栏勾选只影响标题渲染，不动数据层
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchMenuBarAgentsChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    /// 用 NSStatusItem.isVisible 显隐额度栏（不销毁重建，避开「关掉再打开消失」的重建坑）：
    /// 首次开启才真正创建 item，此后只切 isVisible + 启停 5 分钟兜底刷新
    private func applyVisibility() {
        if env.settings.showUsageInMenuBar {
            if statusItem == nil { createStatusItem() }
            statusItem?.isVisible = true
            updateTitle()
            env.usage.refresh(force: true)
            startTimer()
        } else {
            statusItem?.isVisible = false
            stopTimer()
        }
    }

    /// 只创建一次：变宽额度栏，常驻 C<5h%> X<5h%>，点开是详情卡（两服务 5h/7d 进度条）
    private func createStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "AI 编码额度"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        let content = NSHostingView(rootView: UsageMenuView(
            store: env.usage,
            settings: env.settings,
            onRefresh: { [weak self] in self?.env.usage.refresh(force: true) },
            onSettings: { [weak self] in
                self?.dismissPanel()
                NotificationCenter.default.post(name: NSNotification.Name("ProNotchOpenSettings"), object: nil)
            }))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear   // 圆角外透明——无系统毛玻璃、无指向箭头
        p.hasShadow = true
        p.level = .popUpMenu
        p.contentView = content
        panel = p
        statusItem = item
    }

    /// 点额度栏：贴着菜单栏弹出/收起矩形面板（iOS 风，无箭头无毛玻璃），打开时刷新一次
    @objc private func togglePopover() {
        guard let panel else { return }
        if panel.isVisible { dismissPanel(); return }
        guard let button = statusItem?.button, let bwin = button.window else { return }
        env.usage.refresh(force: true)
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 320, height: 380))
        let br = bwin.convertToScreen(button.convert(button.bounds, to: nil))   // 按钮屏幕坐标
        panel.setFrameTopLeftPoint(NSPoint(x: br.maxX - panel.frame.width, y: br.minY - 4))   // 右对齐、贴按钮下方
        panel.orderFrontRegardless()
        panelMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissPanel()
        }
        panelLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if e.window !== self?.panel { self?.dismissPanel() }
            return e
        }
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        if let m = panelMonitor { NSEvent.removeMonitor(m); panelMonitor = nil }
        if let m = panelLocalMonitor { NSEvent.removeMonitor(m); panelLocalMonitor = nil }
    }

    /// 定时刷新只在额度栏显示时运行——隐藏即停，不再无谓访问 Claude / ChatGPT 接口。
    /// 5 分钟只是兜底：真正的刷新时机是用户主动看的那一刻（额度页 onAppear、点开菜单栏
    /// 额度面板、各处刷新按钮）。原先 60 秒一轮属实过密——额度是分钟级都不会变的数字，
    /// 却让 Kimi/Grok 每分钟各挨一次 token 交换，既白耗配额又平添被限流的机会
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.env.usage.refresh() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// 额度栏标题：勾选各家品牌 logo + 5h%；高占用百分比变色；无数据的服务省略。仅额度栏存在时更新
    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        // 双重过滤：接入勾选（设置 → Agent 每家总开关）∩ 菜单栏勾选（每家「菜单栏」小开关）——
        // 刘海里看全量、菜单栏只挑常用的。取消接入时数据被置 nil，
        // objectWillChange 会把这里再驱动一遍，标题即时增减
        let tints: [AgentKind: NSColor] = [
            .claude: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1),   // Claude 橙
            .codex: .systemCyan,
            .grok: .systemGray,
            .kimi: NSColor(srgbRed: 0.929, green: 0.929, blue: 0.929, alpha: 1),     // 月之暗面白
        ]
        let items = AgentKind.allCases.filter {
            $0.supportsQuota && env.settings.enabledAgents.contains($0)
                && env.settings.menuBarAgents.contains($0)
        }
        let title = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        for kind in items {
            guard let pct = env.usage.quota(for: kind)?.primary?.usedPercent else { continue }
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: base)) }
            let att = NSTextAttachment()
            att.image = Self.brandImage(kind.polys, tint: tints[kind] ?? .systemGray, size: 17)
            att.bounds = CGRect(x: 0, y: -4.5, width: 17, height: 17)   // 图标与数字基线对齐
            title.append(NSAttributedString(attachment: att))
            var seg = base
            seg[.foregroundColor] = Self.pctColor(pct)
            title.append(NSAttributedString(string: " \(Int(pct.rounded()))%", attributes: seg))
        }
        // 占位区分两种空：勾了家但数据没到 =「额度…」（在加载）；菜单栏一家没勾 =「额度」（静态入口，点开看详情）
        button.attributedTitle = title.length > 0 ? title
            : NSAttributedString(string: items.isEmpty ? "额度" : "额度…", attributes: base)
    }

    /// 品牌 logo 渲染成菜单栏用小 NSImage：归一化折线 → 染色 evenodd 填充；Y 轴翻转适配 AppKit 坐标系
    private static func brandImage(_ polys: [[CGPoint]], tint: NSColor, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        // 品牌色圆角底：实心色块保证在任意菜单栏背景上都醒目
        let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.3, yRadius: size * 0.3)
        tint.setFill(); bg.fill()
        // 按各 logo 实际包围盒等比缩放到统一区域，保证三家视觉大小一致（长边填满、居中）
        let pts = polys.flatMap { $0 }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { img.unlockFocus(); return img }
        let bw = max(maxX - minX, 0.0001), bh = max(maxY - minY, 0.0001)
        let inset = size * 0.16, avail = size - inset * 2   // 收窄留白，让 logo 在圆底里占更大面积
        let scale = avail / max(bw, bh)
        let offX = inset + (avail - bw * scale) / 2, offY = inset + (avail - bh * scale) / 2
        NSColor.white.setFill()
        let path = NSBezierPath()
        for poly in polys {
            guard let first = poly.first else { continue }
            func m(_ p: CGPoint) -> NSPoint { NSPoint(x: offX + (p.x - minX) * scale, y: offY + (maxY - p.y) * scale) }
            path.move(to: m(first))
            for pt in poly.dropFirst() { path.line(to: m(pt)) }
            path.close()
        }
        path.windingRule = .evenOdd
        path.fill()
        img.unlockFocus()
        return img
    }

    private static func pctColor(_ pct: Double) -> NSColor {
        if pct >= 85 { return NSColor.systemRed }
        if pct >= 60 { return NSColor.systemOrange }
        return NSColor.labelColor   // 正常用系统前景色，自动适配深浅色菜单栏
    }
}
