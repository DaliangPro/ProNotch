import AppKit
import SwiftUI

/// 展开/收起状态机。
/// 架构要点：窗口 frame 固定为展开尺寸、永不变化——位置漂移与"窗口缩放
/// 和内容动画合帧导致斜向展开"在结构上不可能发生。收起时窗口对鼠标完全
/// 隐形（ignoresMouseEvents），悬停检测由全局鼠标监听 + 轮询兜底驱动。
@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case launcher, clipboard, chat, usage, agent

        var title: String {
            switch self {
            case .launcher: return "启动台"
            case .clipboard: return "剪切板"
            case .chat: return "闪问"
            case .usage: return "额度"
            case .agent: return "Agent"
            }
        }

        var icon: String {
            switch self {
            case .launcher: return "square.grid.2x2"
            case .clipboard: return "clipboard"
            case .chat: return "bubble"
            case .usage: return "speedometer"
            case .agent: return "cpu"
            }
        }

        /// 历次中文 rawValue 的兼容映射，老用户已保存的拖动顺序不丢
        static let legacyNames: [String: Tab] = [
            "启动台": .launcher, "剪贴板": .clipboard,
            "AI 对话": .chat,
        ]
    }

    @Published private(set) var isExpanded = false
    @Published var activeTab: Tab = .launcher

    /// 标签顺序（可拖动调整并持久化）；排第一的是每次启动的默认页
    @Published var tabOrder: [Tab] {
        didSet {
            UserDefaults.standard.set(tabOrder.map(\.rawValue), forKey: "tabOrder")
        }
    }

    /// 刘海矩形（全局坐标）
    let notchRect: CGRect
    /// 展开后刘海下方面板的内容尺寸
    let panelSize = CGSize(width: 720, height: 340)

    /// 搜索框聚焦期间为 true，暂停鼠标离开触发的自动收起
    var keyboardHold = false

    /// 全屏隐藏钩子：返回 true 时整个刘海窗口隐藏（外接屏假刘海会遮挡全屏内容）
    var shouldHideForFullscreen: (() -> Bool)?
    /// 当前是否因全屏而隐藏
    private(set) var hiddenForFullscreen = false
    /// 全屏隐藏期间被程序化展开（截图问 AI）临时召唤现身；收起时重新评估是否恢复隐藏
    private var forcedShowOverFullscreen = false
    /// 空间切换通知 token（进入/退出全屏即切换空间，事件驱动零轮询）
    private var spaceObserver: Any?
    private var settingObserver: Any?

    weak var panel: NSPanel?

    private var monitors: [Any] = []
    /// 触控板横滑累积量（攒够阈值切一格）；鼠标滚轮切换的冷却时间戳
    private var scrollAccumX: CGFloat = 0
    /// 本次触控板横滑手势内是否已切过一格——防止单次滑动连翻多页
    private var tabSwitchedThisGesture = false
    private var lastTabSwitch = Date.distantPast
    private var poller: Timer?
    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    /// 调试展开时固定面板，自动收起逻辑暂停
    private var debugPinned = false
    private let expandDelay: TimeInterval = 0.06
    private let collapseDelay: TimeInterval = 0.18
    private let animationDuration: TimeInterval = 0.35

    init(notchRect: CGRect) {
        self.notchRect = notchRect
        // 恢复保存的标签顺序:去重去失效,版本新增的标签追加到末尾——老用户拖好的顺序不因升级重置
        let saved = (UserDefaults.standard.stringArray(forKey: "tabOrder") ?? [])
            .compactMap { Tab(rawValue: $0) ?? Tab.legacyNames[$0] }
        var seen = Set<Tab>()
        var order = saved.filter { seen.insert($0).inserted }
        order.append(contentsOf: Tab.allCases.filter { !seen.contains($0) })
        tabOrder = order
        activeTab = order.first ?? .launcher
    }

    // MARK: - 几何

    /// 展开后黑色形状的整体尺寸（刘海 + 面板）
    var expandedShapeSize: CGSize {
        CGSize(width: max(panelSize.width, notchRect.width),
               height: notchRect.height + panelSize.height)
    }

    /// 窗口固定 frame：按展开尺寸四周留白给阴影，顶边贴屏幕顶
    var windowFrame: CGRect {
        let margin: CGFloat = 24
        let width = expandedShapeSize.width + margin * 2
        let height = expandedShapeSize.height + margin
        return CGRect(x: notchRect.midX - width / 2,
                      y: notchRect.maxY - height,
                      width: width,
                      height: height)
    }

    /// 收起状态的悬停触发区：刘海矩形向屏幕顶边外延伸，
    /// 避免鼠标贴死顶边时坐标恰好落在边界外
    private var enterRect: CGRect {
        var rect = notchRect
        rect.size.height += 20
        return rect
    }

    /// 展开状态的停留区（鼠标离开它才收起），四周放宽 8pt
    private var stayRect: CGRect {
        CGRect(x: notchRect.midX - expandedShapeSize.width / 2,
               y: notchRect.maxY - expandedShapeSize.height,
               width: expandedShapeSize.width,
               height: expandedShapeSize.height + 20)
            .insetBy(dx: -8, dy: 0)
    }

    // MARK: - 鼠标检测

    /// 启动全局/本地鼠标监听 + 轮询兜底（监听偶发丢事件时由轮询纠正）
    func startMouseTracking() {
        stopMouseTracking()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateMouse() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor [weak self] in self?.evaluateMouse() }
            return event
        }) {
            monitors.append(local)
        }
        // 面板滚动手势：触控板双指横滑 / Shift+鼠标滚轮 → 左右切模块（需同步决定吞/放，故直接在主线程处理）
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleScrollWheel(event) } ? nil : event
        }) {
            monitors.append(scroll)
        }
        poller = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateMouse() }
        }

        // 全屏隐藏走事件驱动：进入/退出全屏必然切换空间，
        // 只在空间切换时检测一次（再延迟补查一次等过渡动画结束），平时零开销
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenHiding()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Task { @MainActor [weak self] in
                        self?.updateFullscreenHiding()
                    }
                }
            }
        }
        // 设置开关变化时立即生效（否则关掉开关后要等下次切空间才恢复）
        settingObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchFullscreenSettingChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateFullscreenHiding() }
        }
        updateFullscreenHiding()
    }

    private func updateFullscreenHiding() {
        let shouldHide = shouldHideForFullscreen?() == true
        guard shouldHide != hiddenForFullscreen else { return }
        hiddenForFullscreen = shouldHide
        if shouldHide {
            if isExpanded { collapse() }
            panel?.orderOut(nil)
            print("[ProNotch] 检测到全屏应用，刘海已隐藏")
        } else {
            panel?.orderFrontRegardless()
            print("[ProNotch] 全屏结束，刘海已恢复")
        }
    }

    /// 窗口重建/退出前调用，移除监听与定时器
    func stop() {
        stopMouseTracking()
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
        if let observer = settingObserver {
            NotificationCenter.default.removeObserver(observer)
            settingObserver = nil
        }
        pendingExpand?.cancel()
        pendingExpand = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    private func stopMouseTracking() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        poller?.invalidate()
        poller = nil
    }

    private func evaluateMouse() {
        guard !hiddenForFullscreen else { return }
        let location = NSEvent.mouseLocation
        if isExpanded {
            if stayRect.contains(location) {
                pendingCollapse?.cancel()
                pendingCollapse = nil
                // 鼠标真实进入面板，解除调试固定，交还自动收起控制权
                debugPinned = false
            } else if !debugPinned, !keyboardHold, pendingCollapse == nil {
                scheduleCollapse()
            }
        } else {
            if enterRect.contains(location) {
                if pendingExpand == nil { scheduleExpand() }
            } else {
                pendingExpand?.cancel()
                pendingExpand = nil
            }
        }
    }

    private func scheduleExpand() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingExpand = nil
                // 触发时刻再校验一次，过滤快速划过
                if self.enterRect.contains(NSEvent.mouseLocation) {
                    self.expand()
                }
            }
        }
        pendingExpand = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: work)
    }

    private func scheduleCollapse() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingCollapse = nil
                if !self.stayRect.contains(NSEvent.mouseLocation) {
                    self.collapse()
                }
            }
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
    }

    // MARK: - 状态切换

    /// 程序化展开（截图问 AI 等入口）：固定住不自动收起，直到鼠标真正进入面板后
    /// 交还悬停规则；同时让面板成为 key 窗口，输入框聚焦即可直接打字。
    /// 用户显式召唤压过「全屏自动隐藏」：曾因 guard hiddenForFullscreen 静默放弃，导致在全屏
    /// App 里点「截图问 AI」刘海必不弹。面板本就具备 fullScreenAuxiliary，可临时现身盖在全屏
    /// 空间上；收起时（collapse）重新评估，仍在全屏则恢复隐藏
    func expandProgrammatically() {
        if hiddenForFullscreen {
            hiddenForFullscreen = false
            forcedShowOverFullscreen = true
            panel?.orderFrontRegardless()
        }
        if !isExpanded {
            debugPinned = true
            expand()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func debugToggle() {
        guard !hiddenForFullscreen else {
            print("[ProNotch] 刘海当前因全屏隐藏，忽略展开请求")
            return
        }
        if isExpanded {
            collapse()
        } else {
            debugPinned = true
            expand()
        }
    }

    /// 供面板内操作（如启动应用后）主动收起
    func collapseNow() {
        collapse()
    }

    // MARK: - 模块左右切换（触控板横滑 / Shift+滚轮）

    /// 在 tabOrder 中左右切换当前页，循环。step=+1 下一个（右），-1 上一个（左）
    func switchTab(by step: Int) {
        guard !tabOrder.isEmpty, let idx = tabOrder.firstIndex(of: activeTab) else { return }
        let n = tabOrder.count
        let target = tabOrder[((idx + step) % n + n) % n]
        guard target != activeTab else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            activeTab = target
        }
    }

    /// 面板滚动分流：横向手势（触控板双指横滑 / Shift+鼠标滚轮）左右切模块并吞掉事件；
    /// 纵向滚动原样放行给内容页。返回 true = 已消费（吞掉），false = 放行给内容。
    /// 方向若与直觉相反，仅需翻转下方两处 step 的 +1/-1。
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard isExpanded, let panel, event.window === panel else { return false }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let shift = event.modifierFlags.contains(.shift)

        if event.hasPreciseScrollingDeltas && !shift {
            // —— 触控板：按手势阶段管控，一次横滑最多切一格 ——
            // 抬手后的惯性事件全部吞掉不切，否则一次滑动会靠惯性连翻好几页
            if event.momentumPhase != [] { return true }
            // 手势开始/结束都复位：保证「一次滑动 = 一格」，且下次还能再切
            if event.phase.contains(.began) || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                scrollAccumX = 0
                tabSwitchedThisGesture = false
            }
            let horizontal = abs(dx) > abs(dy) * 1.4 && abs(dx) > 2
            guard horizontal || scrollAccumX != 0 else { return false }   // 纵向手势：放行给内容滚动
            if (scrollAccumX > 0) != (dx > 0), dx != 0 { scrollAccumX = 0 }   // 反向清零，避免来回抖动累加
            scrollAccumX += dx
            if !tabSwitchedThisGesture, abs(scrollAccumX) >= 80 {   // 阈值：约需一段明确横滑才切；切完锁死本次手势
                switchTab(by: scrollAccumX < 0 ? 1 : -1)
                tabSwitchedThisGesture = true
            }
            return true   // 横向手势吞掉，不漏给内容
        }

        // —— 鼠标滚轮：仅 Shift+滚轮 切模块，一格一切、带冷却防猛滚跳多格 ——
        guard shift else { scrollAccumX = 0; return false }
        let primary = abs(dx) >= abs(dy) ? dx : dy
        if Date().timeIntervalSince(lastTabSwitch) > 0.2 {
            switchTab(by: primary < 0 ? 1 : -1)
            lastTabSwitch = Date()
        }
        return true
    }

    private func expand() {
        guard !isExpanded else { return }
        print("[ProNotch] 展开")
        // 展开期间窗口需要接收点击与悬停
        panel?.ignoresMouseEvents = false
        withAnimation(.spring(response: animationDuration, dampingFraction: 0.8)) {
            isExpanded = true
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        print("[ProNotch] 收起")
        debugPinned = false
        keyboardHold = false
        pendingCollapse?.cancel()
        pendingCollapse = nil
        // 全屏期间被截图问 AI 临时召唤的：收起即重新评估，仍在全屏空间则恢复隐藏
        if forcedShowOverFullscreen {
            forcedShowOverFullscreen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) { [weak self] in
                Task { @MainActor [weak self] in self?.updateFullscreenHiding() }
            }
        }
        // 收起后窗口对鼠标完全隐形，假刘海区域的点击会穿透到下层
        panel?.ignoresMouseEvents = true
        withAnimation(.spring(response: animationDuration, dampingFraction: 0.9)) {
            isExpanded = false
        }
        // 若面板曾因搜索框成为 key window，收起后快速 orderOut/orderFront
        // 一次，把键盘焦点还给原前台应用（动画结束后执行，避免打断动画）
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.05) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isExpanded,
                      let panel = self.panel, panel.isKeyWindow else { return }
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }
}
