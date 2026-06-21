import AppKit
import SwiftUI

/// 光晕来源：Claude Code（橙）/ Codex（蓝）。各自对应一个桌面 App，
/// 当该 App 被切到最前台时，熄灭它的「完成提醒」光晕。
enum GlowSource: String {
    case claude
    case codex

    /// 对应桌面 App 的 bundle id（「切到前台就熄灭」识别用）
    var appBundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex:  return "com.openai.codex"
        }
    }
}

/// 光晕运行时控制器：持有覆盖整屏的 `GlowPanel`，由 `GlowOverlayView` 观察绘制。
///
/// - 点亮：`notifyCompletion`（真实 hook）/ `toggleTest`（模拟完成）/ `togglePreview`（调参）；
/// - 熄灭：「完成提醒」类光晕在对应桌面 App 切到最前台时自动熄灭；「预览」类只手动关。
@MainActor
final class GlowController: ObservableObject {
    /// 当前点亮的颜色；nil = 不显示
    @Published var activeColor: Color?
    /// 呼吸相位 / 淡入淡出包络，定时器驱动
    @Published var breath: Double = 0
    @Published var envelope: Double = 0
    /// 外观参数，跟随设置实时刷新
    @Published var period: Double
    @Published var intensity: Double
    @Published var thickness: Double
    /// 设置页按钮状态
    @Published var previewingSource: GlowSource?
    @Published var testingSource: GlowSource?

    private enum Mode { case preview, alert }   // preview=调参(切前台不灭); alert=完成提醒(切前台灭)

    private let settings: SettingsStore
    private var activeSource: GlowSource?
    private var activeMode: Mode?
    private var panel: GlowPanel?
    private var loopTimer: Timer?
    private var loopStart: Date?
    private var fadeTarget: Double = 0
    private let fadeDuration: Double = 0.5
    /// 完成信号防抖：连续信号（如 computer-use 每步都发）不断重置计时，
    /// 只有停顿超过此秒数（=这轮活真干完了）才点亮一次
    private var completionDebounce: Timer?
    private var debounceSource: GlowSource?
    private let completionDebounceDelay: TimeInterval = 8

    init(settings: SettingsStore) {
        self.settings = settings
        period = settings.glowBreathPeriod
        intensity = settings.glowIntensity
        thickness = settings.glowThickness
        setupPanel()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchGlowSettingsChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncAppearance() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleAppActivation(note) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel?.setFrame(NotchGeometry.targetScreen().frame, display: true) }
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

    func color(for source: GlowSource) -> Color {
        switch source {
        case .claude: return Color(hex: settings.glowClaudeColorHex)
        case .codex:  return Color(hex: settings.glowCodexColorHex)
        }
    }

    // MARK: - 点亮 / 熄灭

    /// 真实完成信号（pronotch://done?source=…）→ 完成提醒光晕
    func notifyCompletion(_ source: GlowSource) {
        guard settings.glowEnabled else { return }
        previewingSource = nil
        testingSource = nil
        // 防抖：computer-use 等场景下，Codex 每完成一个中间步骤都会发完成信号。
        // 连续信号不断重置计时，只有「停顿超过 completionDebounceDelay 秒」（=这轮活
        // 真干完了 / 停下来等你了）才点亮一次，避免干活过程中刷屏。
        debounceSource = source
        completionDebounce?.invalidate()
        let timer = Timer(timeInterval: completionDebounceDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.completionDebounce = nil
                self.debounceSource = nil
                self.light(source, mode: .alert)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        completionDebounce = timer
    }

    /// 设置页「测试」按钮：模拟一次真实完成（切前台会灭），再点同色熄灭
    func toggleTest(_ source: GlowSource) {
        guard settings.glowEnabled else { return }
        if testingSource == source { dismiss(); return }
        previewingSource = nil
        testingSource = source
        light(source, mode: .alert)
    }

    /// 设置页「预览」按钮：常亮调参（切前台不灭），再点同色熄灭
    func togglePreview(_ source: GlowSource) {
        guard settings.glowEnabled else { return }
        if previewingSource == source { dismiss(); return }
        testingSource = nil
        previewingSource = source
        light(source, mode: .preview)
    }

    private func light(_ source: GlowSource, mode: Mode) {
        activeSource = source
        activeMode = mode
        activeColor = color(for: source)
        fadeTarget = 1
        startLoopIfNeeded()
    }

    func dismiss() {
        completionDebounce?.invalidate()
        completionDebounce = nil
        debounceSource = nil
        fadeTarget = 0   // 由 tick() 淡出到 0 后统一清理
    }

    /// 「完成提醒」光晕：对应桌面 App 切到最前台 → 熄灭（预览类不受影响）
    private func handleAppActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let bundle = app.bundleIdentifier
        // 防抖等待期间切到对应 App = 你已经在看了，取消这次待点亮
        if completionDebounce != nil, bundle == debounceSource?.appBundleID {
            completionDebounce?.invalidate()
            completionDebounce = nil
            debounceSource = nil
        }
        // 已点亮的完成光晕：切到对应 App 前台 → 熄灭
        guard activeMode == .alert, let source = activeSource,
              bundle == source.appBundleID else { return }
        dismiss()
    }

    // MARK: - 动画循环

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
        if envelope < fadeTarget { envelope = min(fadeTarget, envelope + step) }
        else if envelope > fadeTarget { envelope = max(fadeTarget, envelope - step) }

        if fadeTarget == 0 && envelope <= 0.001 {
            envelope = 0
            activeColor = nil
            activeSource = nil
            activeMode = nil
            previewingSource = nil
            testingSource = nil
            loopTimer?.invalidate(); loopTimer = nil; loopStart = nil
        }
    }

    /// 设置变更后同步外观；关闭总开关则熄灭，预览中则即时换色
    private func syncAppearance() {
        period = settings.glowBreathPeriod
        intensity = settings.glowIntensity
        thickness = settings.glowThickness
        if !settings.glowEnabled {
            dismiss()
        } else if let source = activeSource {
            activeColor = color(for: source)
        }
    }
}
