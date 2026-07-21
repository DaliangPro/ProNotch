import AppKit
import SwiftUI

/// 展开/收起状态机。
/// 架构要点：窗口 frame 固定为展开尺寸、永不变化——位置漂移与"窗口缩放
/// 和内容动画合帧导致斜向展开"在结构上不可能发生。收起时窗口对鼠标完全
/// 隐形（ignoresMouseEvents），悬停检测由全局鼠标监听 + 轮询兜底驱动。
@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case launcher, chat, usage, agent, widgets

        var title: String {
            switch self {
            case .launcher: return "启动台"
            case .chat: return "闪问"
            case .usage: return "额度"
            case .agent: return "Agent"
            case .widgets: return "组件"
            }
        }

        /// SF Symbol 名；launcher/chat 实际显示 TabButton 里的自绘图形
        /// （App Store 风三棒 A / AI+小星，大梁老师指定），此处仅兜底
        var icon: String {
            switch self {
            case .launcher: return "square.grid.2x2"
            case .chat: return "bolt"
            case .usage: return "gauge.with.needle"
            case .agent: return "apple.terminal"
            case .widgets: return "square.grid.2x2"   // 四宫格（大梁老师从候选 A 选定）
            }
        }

        /// 历次中文 rawValue 的兼容映射，老用户已保存的拖动顺序不丢
        /// （剪切板页已下线，只保留快捷键触发；老用户存的 clipboard 顺序项会被自动过滤）
        static let legacyNames: [String: Tab] = [
            "启动台": .launcher, "AI 对话": .chat,
        ]
    }

    @Published private(set) var isExpanded = false
    @Published var activeTab: Tab = .launcher

    /// 用户显式锁定：锁上后鼠标离开也不自动收起（面板边缘的锁按钮控制）。
    /// 收起时（collapse）自动复位——锁只对「当前这次展开」有效
    @Published var isPinned = false {
        didSet {
            // 锁上瞬间取消可能已排程的收起，避免刚锁又被收走
            if isPinned { pendingCollapse?.cancel(); pendingCollapse = nil }
        }
    }

    /// 标签顺序（可拖动调整并持久化）；排第一的是每次启动的默认页
    @Published var tabOrder: [Tab] {
        didSet {
            UserDefaults.standard.set(tabOrder.map(\.rawValue), forKey: "tabOrder")
        }
    }

    /// 各家 Agent 勾选快照（与数据层同口径 enabledSet）；由 ProNotchAgentSelectionChanged 驱动刷新，
    /// 唯一用途是推导 visibleTabs——不额外持久化
    @Published private var enabledAgentsSnapshot: Set<AgentKind> = AgentKind.enabledSet()
    /// 组件页是否有可见卡片的快照（内存/天气内部开关任一开）；由 ProNotchWidgetVisibilityChanged 驱动刷新，
    /// 两卡全关 → 组件页跟随隐藏（与额度/Agent 页同一显隐哲学）
    @Published private var widgetsVisibleSnapshot: Bool = SettingsStore.anyWidgetVisible()

    /// 当前应显示的页签（面板跟随内容自动显隐）：顺序沿用 tabOrder，隐藏项就地跳过（不改持久化顺序）
    var visibleTabs: [Tab] {
        Self.visibleTabs(order: tabOrder, enabled: enabledAgentsSnapshot,
                         widgetsVisible: widgetsVisibleSnapshot)
    }

    /// 页签可见性纯函数（可单测）：launcher/chat 常显；组件页要求内存/天气内部开关任一开；
    /// 额度页要求勾选集里有能查额度的家，Agent 页要求有能看本地会话的家。
    /// 当前四家额度与会话都支持 → 勾任意一家两页都在，全不勾才隐；能力判断保留，
    /// 是为将来接入只有部分能力的家（不写死成「勾了就显」）
    nonisolated static func visibleTabs(order: [Tab], enabled: Set<AgentKind>,
                                        widgetsVisible: Bool) -> [Tab] {
        order.filter { tab in
            switch tab {
            case .launcher, .chat: return true
            case .widgets: return widgetsVisible
            case .usage: return enabled.contains { $0.supportsQuota }
            case .agent: return enabled.contains { $0.supportsSessions }
            }
        }
    }

    /// 当前页仍可见就保持，否则落到第一个可见页（launcher 常显，兜底非空）
    nonisolated static func resolvedActive(_ current: Tab, order: [Tab], enabled: Set<AgentKind>,
                                           widgetsVisible: Bool) -> Tab {
        let vis = visibleTabs(order: order, enabled: enabled, widgetsVisible: widgetsVisible)
        return vis.contains(current) ? current : (vis.first ?? .launcher)
    }

    /// 把可见页的新排列写回完整顺序：隐藏页锚定原槽位不动，可见页按新序依次流入可见槽位。
    /// visible 必须是 full 中可见项的一个排列（页签拖拽重排后调用），隐藏页不受拖动影响
    nonisolated static func mergeVisibleOrder(full: [Tab], visible: [Tab]) -> [Tab] {
        let visibleSet = Set(visible)
        var it = visible.makeIterator()
        return full.map { visibleSet.contains($0) ? (it.next() ?? $0) : $0 }
    }

    /// 刘海矩形（全局坐标）
    let notchRect: CGRect
    /// 展开后刘海下方面板的内容尺寸（原 720×340，大梁老师要求整体加大约 1/3）
    let panelSize = CGSize(width: 960, height: 455)
    /// 收起态两侧功能区宽度（单侧）：左内存右天气（大梁老师定的自由功能区）。
    /// 内容实测 42-49pt（含 100%/-12° 极值），56 留最小气口——首版 80 被嫌过宽
    let sideSlotWidth: CGFloat = 56
    /// 两侧功能区是否启用（任一侧配了内容即 true，由设置驱动）；
    /// 关闭后收起态退回物理刘海原宽，侧区热区同步失效
    @Published var sideSlotsActive = true
    /// 收起态黑形状总宽 = 物理刘海 + 两侧功能区（大梁老师要求收起态更宽）
    var collapsedShapeWidth: CGFloat {
        notchRect.width + (sideSlotsActive ? sideSlotWidth * 2 : 0)
    }

    /// 搜索框聚焦期间为 true，暂停鼠标离开触发的自动收起
    var keyboardHold = false

    /// 天气预警横幅显示中（收起态）：横幅要接收点击，临时解除窗口的鼠标穿透。
    /// 只有不透明像素会截获点击（透明区按像素透传），假刘海黑条被点到无副作用
    var alertBannerVisible = false {
        didSet {
            guard !isExpanded else { return }
            panel?.ignoresMouseEvents = !alertBannerVisible
        }
    }

    /// 全屏隐藏钩子：返回 true 时整个刘海窗口隐藏（外接屏假刘海会遮挡全屏内容）
    var shouldHideForFullscreen: (() -> Bool)?
    /// 当前是否因全屏而隐藏
    private(set) var hiddenForFullscreen = false
    /// 全屏隐藏期间被程序化展开（截图问 AI）临时召唤现身；收起时重新评估是否恢复隐藏
    private var forcedShowOverFullscreen = false
    /// 空间切换通知 token（进入/退出全屏即切换空间，事件驱动零轮询）
    private var spaceObserver: Any?
    private var settingObserver: Any?
    private var agentSelectionObserver: Any?
    private var widgetVisibilityObserver: Any?

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
        // 落到第一个可见页：默认页（首位）若因未勾选对应 Agent 而隐藏，不空展示
        activeTab = Self.resolvedActive(order.first ?? .launcher, order: order,
                                        enabled: AgentKind.enabledSet(),
                                        widgetsVisible: SettingsStore.anyWidgetVisible())
    }

    // MARK: - 几何

    /// 展开后黑色形状的整体尺寸（刘海 + 面板）
    var expandedShapeSize: CGSize {
        CGSize(width: max(panelSize.width, notchRect.width),
               height: notchRect.height + panelSize.height)
    }

    /// 窗口固定 frame：按展开尺寸四周留白，顶边贴屏幕顶。
    /// 余量 = 弹跳过冲空间 + 阴影：展开弹跳冲到 +8%（960×0.08 单边 38.4pt）
    /// 再加 14pt 阴影约需 53pt，留 64 保底——余量不足会把过冲峰值裁在窗口边上
    var windowFrame: CGRect {
        let margin: CGFloat = 64
        let width = expandedShapeSize.width + margin * 2
        let height = expandedShapeSize.height + margin
        return CGRect(x: notchRect.midX - width / 2,
                      y: notchRect.maxY - height,
                      width: width,
                      height: height)
    }

    /// 收起状态的悬停触发区：刘海矩形向屏幕顶边外延伸，
    /// 避免鼠标贴死顶边时坐标恰好落在边界外。
    /// 左右扩到两侧功能区——收起态黑形状加宽后，悬停侧区同样展开
    private var enterRect: CGRect {
        var rect = notchRect
        rect.size.height += 20
        if sideSlotsActive {
            rect.origin.x -= sideSlotWidth
            rect.size.width += sideSlotWidth * 2
        }
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
            Task { @MainActor [weak self] in
                self?.evaluateMouse()
                self?.tickFullscreenCheck()
            }
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
            forName: .proNotchFullscreenSettingChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateFullscreenHiding() }
        }
        // Agent 勾选变化：刷新可见页快照，当前页若被隐藏则落到第一个可见页
        agentSelectionObserver = NotificationCenter.default.addObserver(
            forName: .proNotchAgentSelectionChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enabledAgentsSnapshot = AgentKind.enabledSet()
                self.activeTab = Self.resolvedActive(self.activeTab, order: self.tabOrder,
                                                     enabled: self.enabledAgentsSnapshot,
                                                     widgetsVisible: self.widgetsVisibleSnapshot)
            }
        }
        // 组件页内部开关变化：刷新组件页可见快照，两卡全关时当前页若停在组件页则落到第一个可见页
        widgetVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .proNotchWidgetVisibilityChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.widgetsVisibleSnapshot = SettingsStore.anyWidgetVisible()
                self.activeTab = Self.resolvedActive(self.activeTab, order: self.tabOrder,
                                                     enabled: self.enabledAgentsSnapshot,
                                                     widgetsVisible: self.widgetsVisibleSnapshot)
            }
        }
        updateFullscreenHiding()
    }

    /// 全屏兜底检测计数：复用 0.2s 鼠标心跳，每 5 拍（约 1 秒）兜底重评一次全屏。
    /// 事件驱动（切空间）会漏掉 Keynote 放映这种「不换空间的覆盖式全屏」，靠这个兜底。
    /// 必须独立于 evaluateMouse 调用——后者在隐藏态会提前 return，无法检测「退出全屏」。
    /// CGWindowList 只读边界、微秒级、无需权限；updateFullscreenHiding 内有状态去重，
    /// 无变化时几乎零开销。
    private var fullscreenTick = 0
    private func tickFullscreenCheck() {
        fullscreenTick += 1
        guard fullscreenTick >= 5 else { return }
        fullscreenTick = 0
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
        if let observer = agentSelectionObserver {
            NotificationCenter.default.removeObserver(observer)
            agentSelectionObserver = nil
        }
        if let observer = widgetVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
            widgetVisibilityObserver = nil
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
            } else if !debugPinned, !isPinned, !keyboardHold, pendingCollapse == nil {
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
        // 只在可见页之间横滑循环，不会切到被隐藏的页
        let vis = visibleTabs
        guard !vis.isEmpty, let idx = vis.firstIndex(of: activeTab) else { return }
        let n = vis.count
        let target = vis[((idx + step) % n + n) % n]
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
        // 形状只管快速长大到位；弹跳（衰减震荡）由 NotchContainerView 的
        // scale 关键帧负责，两者叠加成一次连续的「冲进来弹三下」
        withAnimation(.easeOut(duration: 0.22)) {
            isExpanded = true
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        print("[ProNotch] 收起")
        debugPinned = false
        isPinned = false   // 收起即解锁：下次展开回到默认「自动收起」
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
        // （预警横幅还挂着时除外——它需要接收点击，缩回后由 alertBannerVisible 恢复穿透）
        panel?.ignoresMouseEvents = !alertBannerVisible
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
