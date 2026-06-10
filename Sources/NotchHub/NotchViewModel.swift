import AppKit
import SwiftUI

/// 展开/收起状态机。
/// 架构要点：窗口 frame 固定为展开尺寸、永不变化——位置漂移与"窗口缩放
/// 和内容动画合帧导致斜向展开"在结构上不可能发生。收起时窗口对鼠标完全
/// 隐形（ignoresMouseEvents），悬停检测由全局鼠标监听 + 轮询兜底驱动。
@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case launcher = "启动台"
        case clipboard = "剪贴板"
        case chat = "AI 对话"

        var icon: String {
            switch self {
            case .launcher: return "square.grid.3x3.fill"
            case .clipboard: return "doc.on.clipboard"
            case .chat: return "sparkles"
            }
        }
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
    /// 空间切换通知 token（进入/退出全屏即切换空间，事件驱动零轮询）
    private var spaceObserver: Any?
    private var settingObserver: Any?

    weak var panel: NSPanel?

    private var monitors: [Any] = []
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
        // 恢复保存的标签顺序；数据不完整（如未来增减标签）则回退默认
        let saved = (UserDefaults.standard.stringArray(forKey: "tabOrder") ?? [])
            .compactMap(Tab.init(rawValue:))
        let order = Set(saved) == Set(Tab.allCases) ? saved : Tab.allCases
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
            forName: NSNotification.Name("NotchHubFullscreenSettingChanged"),
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
            print("[NotchHub] 检测到全屏应用，刘海已隐藏")
        } else {
            panel?.orderFrontRegardless()
            print("[NotchHub] 全屏结束，刘海已恢复")
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

    func debugToggle() {
        guard !hiddenForFullscreen else {
            print("[NotchHub] 刘海当前因全屏隐藏，忽略展开请求")
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

    private func expand() {
        guard !isExpanded else { return }
        print("[NotchHub] 展开")
        // 展开期间窗口需要接收点击与悬停
        panel?.ignoresMouseEvents = false
        withAnimation(.spring(response: animationDuration, dampingFraction: 0.8)) {
            isExpanded = true
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        print("[NotchHub] 收起")
        debugPinned = false
        keyboardHold = false
        pendingCollapse?.cancel()
        pendingCollapse = nil
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
