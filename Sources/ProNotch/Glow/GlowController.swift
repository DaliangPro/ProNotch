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
    private var activeHost: String?   // 当前光晕对应的宿主 App bundle id（切回它即熄灭）
    private var panels: [GlowPanel] = []   // 每块屏幕（主屏 + 扩展屏）一个，同步呼吸
    private var loopTimer: Timer?
    private var loopStart: Date?
    private var fadeTarget: Double = 0
    private let fadeDuration: Double = 0.5

    init(settings: SettingsStore) {
        self.settings = settings
        period = settings.glowBreathPeriod
        intensity = settings.glowIntensity
        thickness = settings.glowThickness
        setupPanels()

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
            Task { @MainActor in self?.setupPanels() }   // 屏幕增减 / 分辨率变化 → 重建各屏面板
        }
    }

    /// 每块屏幕（主屏 + 扩展屏）各建一个光晕面板，共享同一个 GlowController → 同步呼吸
    private func setupPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let p = GlowPanel(frame: screen.frame)
            p.contentView = NSHostingView(rootView: GlowOverlayView().environmentObject(self))
            p.setFrame(screen.frame, display: true)
            p.orderFrontRegardless()
            return p
        }
    }

    func color(for source: GlowSource) -> Color {
        switch source {
        case .claude: return Color(hex: settings.glowClaudeColorHex)
        case .codex:  return Color(hex: settings.glowCodexColorHex)
        }
    }

    // MARK: - 点亮 / 熄灭

    /// 真实完成信号（pronotch://done?source=…）→ 完成提醒光晕
    func notifyCompletion(_ source: GlowSource, host: String? = nil) {
        // 总开关 + 该来源单独勾选都需开启；取消勾选的来源即使仍收到残留信号（如旧版孤儿钩子）也不点亮
        guard settings.glowEnabled, GlowHookInstaller.isInstalled(source) else { return }
        // 宿主 App：hook 沿进程链找到的「Agent 实际所在的 GUI App」bundle id；
        // 拿不到（旧 hook / 特殊环境）就回退到该 Agent 的桌面版 bundle id。
        let hostID = (host?.isEmpty == false) ? host! : source.appBundleID
        // 只在 Agent 处于后台时提醒：若宿主 App 已在最前台（你正盯着它跑），就不点亮——
        // 既没必要，光晕也无从熄灭（已在前台，等不到「切回它」的激活事件）。
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hostID { return }
        previewingSource = nil
        testingSource = nil
        activeHost = hostID
        // 完成信号发在「这轮任务真正结束」时，所以收到即点亮。
        light(source, mode: .alert)
    }

    /// 设置页「测试」按钮：模拟一次真实完成（切前台会灭），再点同色熄灭
    func toggleTest(_ source: GlowSource) {
        guard settings.glowEnabled else { return }
        if testingSource == source { dismiss(); return }
        previewingSource = nil
        testingSource = source
        activeHost = nil
        light(source, mode: .alert)
    }

    /// 设置页「预览」按钮：常亮调参（切前台不灭），再点同色熄灭
    func togglePreview(_ source: GlowSource) {
        guard settings.glowEnabled else { return }
        if previewingSource == source { dismiss(); return }
        testingSource = nil
        previewingSource = source
        activeHost = nil
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
        fadeTarget = 0   // 由 tick() 淡出到 0 后统一清理
    }

    /// 「完成提醒」光晕：对应桌面 App 切到最前台 → 熄灭（预览类不受影响）
    private func handleAppActivation(_ note: Notification) {
        guard activeMode == .alert, let source = activeSource,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // 切回「Agent 所在的宿主 App」即熄灭；activeHost 为空时回退到桌面版 bundle id。
        guard app.bundleIdentifier == (activeHost ?? source.appBundleID) else { return }
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
            activeHost = nil
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
