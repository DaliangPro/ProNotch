import AppKit
import SwiftUI

/// 展开/收起状态机：负责悬停防抖、窗口尺寸切换与动画时序
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

    /// 刘海矩形（全局坐标）
    let notchRect: CGRect
    /// 展开后刘海下方面板的内容尺寸
    let panelSize = CGSize(width: 640, height: 220)

    weak var panel: NSPanel?

    private var pendingWork: DispatchWorkItem?
    /// 调试展开时固定面板，看门狗不自动收起
    private var debugPinned = false
    /// 展开期间兜底：移出事件偶尔会丢，定时校验鼠标位置
    private var watchdog: Timer?
    private let expandDelay: TimeInterval = 0.08
    private let collapseDelay: TimeInterval = 0.18
    private let animationDuration: TimeInterval = 0.35

    init(notchRect: CGRect) {
        self.notchRect = notchRect
    }

    // MARK: - 几何

    var closedWindowFrame: CGRect { notchRect }

    /// 展开后黑色形状的整体尺寸（刘海 + 面板）
    var expandedShapeSize: CGSize {
        CGSize(width: max(panelSize.width, notchRect.width),
               height: notchRect.height + panelSize.height)
    }

    /// 展开后的窗口尺寸：四周留白给阴影，顶边与屏幕顶对齐
    var expandedWindowFrame: CGRect {
        let margin: CGFloat = 24
        let width = expandedShapeSize.width + margin * 2
        let height = expandedShapeSize.height + margin
        return CGRect(x: notchRect.midX - width / 2,
                      y: notchRect.maxY - height,
                      width: width,
                      height: height)
    }

    // MARK: - 交互

    func hoverChanged(_ hovering: Bool) {
        // 窗口尺寸变化会产生合成悬停事件，只有鼠标真在窗口内才解除调试固定
        if mouseInsideWindow() { debugPinned = false }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 窗口尺寸切换会触发虚假的进入/移出事件，统一用真实鼠标位置二次校验
                if hovering {
                    if self.mouseInsideWindow() { self.expand() }
                } else if !self.mouseInsideWindow() {
                    self.collapse()
                }
            }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (hovering ? expandDelay : collapseDelay),
            execute: work)
    }

    func debugToggle() {
        pendingWork?.cancel()
        if isExpanded {
            debugPinned = false
            collapse()
        } else {
            debugPinned = true
            expand()
        }
    }

    // MARK: - 私有

    private func expand() {
        guard !isExpanded else { return }
        print("[NotchHub] 展开")
        // 先把窗口放大到展开尺寸，让内容以新窗口坐标完成一次无动画布局
        panel?.setFrame(expandedWindowFrame, display: true)
        // 下一个 runloop 再启动内容动画：若与窗口放大落在同一帧，
        // 形状会从窗口左上角斜向展开，而不是以刘海为中心向外生长
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isExpanded else { return }
            withAnimation(.spring(response: self.animationDuration, dampingFraction: 0.8)) {
                self.isExpanded = true
            }
            self.startWatchdog()
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        print("[NotchHub] 收起")
        watchdog?.invalidate()
        watchdog = nil
        withAnimation(.spring(response: animationDuration, dampingFraction: 0.9)) {
            isExpanded = false
        }
        // 等内容动画结束后再缩小窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.05) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isExpanded else { return }
                self.panel?.setFrame(self.closedWindowFrame, display: true)
            }
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isExpanded, !self.debugPinned else { return }
                if !self.mouseInsideWindow() {
                    print("[NotchHub] 看门狗：鼠标已离开，兜底收起")
                    self.collapse()
                }
            }
        }
    }

    private func mouseInsideWindow() -> Bool {
        guard let panel else { return false }
        return panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }
}
