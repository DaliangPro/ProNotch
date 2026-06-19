import AppKit
import SwiftUI

/// 光晕来源：Claude Code（橙）/ Codex（蓝）。各自对应一个桌面 App，
/// 当该 App 被切到最前台时，熄灭它的光晕。
enum GlowSource: String {
    case claude
    case codex

    /// 对应桌面 App 的 bundle id（用于「切到前台就熄灭」识别）
    var appBundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex:  return "com.openai.codex"
        }
    }

    /// 默认颜色（第二增量会改为从设置读取，可自定义）
    var defaultColor: Color {
        switch self {
        case .claude: return Color(red: 1.00, green: 0.54, blue: 0.00)  // 橙 #FF8A00
        case .codex:  return Color(red: 0.04, green: 0.52, blue: 1.00)  // 蓝 #0A84FF
        }
    }
}

/// 光晕运行时控制器：持有覆盖整屏的 `GlowPanel`，由 `GlowOverlayView` 观察绘制。
///
/// - 点亮：`notifyCompletion(_:)`——真实 hook（`pronotch://done?source=…`）与测试都走这里；
/// - 熄灭：监听前台 App 切换，当 Claude / Codex 桌面窗口被切到最前 → 熄灭对应颜色。
@MainActor
final class GlowController: ObservableObject {
    /// 当前点亮的颜色；nil = 不显示（面板透明、依旧穿透）
    @Published var activeColor: Color?
    /// 呼吸相位 0...1 与 淡入淡出包络 0...1，由定时器驱动
    @Published var breath: Double = 0
    @Published var envelope: Double = 0

    /// 外观参数（本增量用默认值；下一增量接入设置页可调）
    var period: Double = 3.2
    var intensity: Double = 0.9
    var thickness: Double = 90

    private var activeSource: GlowSource?
    private var panel: GlowPanel?
    private var loopTimer: Timer?
    private var loopStart: Date?
    private var fadeTarget: Double = 0
    private let fadeDuration: Double = 0.5
    private var frontmostObserver: Any?
    private var screenObserver: Any?

    init() {
        setupPanel()

        // 前台 App 切换：切到 Claude / Codex 桌面窗口 → 熄灭对应颜色
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleAppActivation(note) }
        }
        // 分辨率 / 接显示器变化后重新贴合主屏
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePanelFrame() }
        }
    }

    private func setupPanel() {
        let frame = NotchGeometry.targetScreen().frame
        let p = GlowPanel(frame: frame)
        p.contentView = NSHostingView(rootView: GlowOverlayView().environmentObject(self))
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        panel = p
    }

    private func updatePanelFrame() {
        panel?.setFrame(NotchGeometry.targetScreen().frame, display: true)
    }

    // MARK: - 点亮 / 熄灭

    /// 任务完成：点亮对应来源的光晕（带淡入呼吸）。
    /// 本增量同时只显示最近一个来源，多来源叠加后续再做。
    func notifyCompletion(_ source: GlowSource) {
        activeSource = source
        activeColor = source.defaultColor
        fadeTarget = 1
        startLoopIfNeeded()
    }

    /// 熄灭（淡出后清理）
    func dismiss() {
        fadeTarget = 0
    }

    /// 前台 App 变化：切到的正是当前点亮来源对应的桌面 App → 熄灭
    private func handleAppActivation(_ note: Notification) {
        guard let source = activeSource,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == source.appBundleID else { return }
        dismiss()
    }

    // MARK: - 动画循环（呼吸 + 淡入淡出）

    private func startLoopIfNeeded() {
        guard loopTimer == nil else { return }
        loopStart = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        loopTimer = timer
    }

    private func tick() {
        guard let start = loopStart else { return }
        let t = Date().timeIntervalSince(start)
        breath = (sin(2 * .pi * t / max(period, 0.6)) + 1) / 2

        let step = (1.0 / 30.0) / fadeDuration
        if envelope < fadeTarget {
            envelope = min(fadeTarget, envelope + step)
        } else if envelope > fadeTarget {
            envelope = max(fadeTarget, envelope - step)
        }

        if fadeTarget == 0 && envelope <= 0.001 {
            envelope = 0
            activeColor = nil
            activeSource = nil
            loopTimer?.invalidate()
            loopTimer = nil
            loopStart = nil
        }
    }
}
