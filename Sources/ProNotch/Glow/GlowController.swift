import AppKit
import Combine
import SwiftUI

/// 完成提醒的方式，二选一（大梁老师 2026-09-16 定）
enum AgentAlertStyle: String, CaseIterable, Sendable {
    /// 屏幕四周呼吸光晕
    case glow
    /// 刘海顶部弹窗：与天气预警同一种从刘海长出来的卡
    case card

    var title: String {
        switch self {
        case .glow: return "四周光晕"
        case .card: return "顶部弹窗"
        }
    }
}

/// 完成提醒控制器：持有覆盖整屏的 `GlowPanel`，由 `GlowOverlayView` 观察绘制。
/// 来源统一用 `AgentKind`（supportsGlow 的家）：颜色、桌面 App 识别都从那份定义取。
///
/// - 点亮：`notifyCompletion`（真实 hook）/ `toggleTest`（模拟完成）/ `togglePreview`（调参）；
/// - 熄灭：「完成提醒」类光晕在对应桌面 App 切到最前台时自动熄灭；「预览」类只手动关。
/// - 提醒方式选「顶部弹窗」时不点光晕，改往 `completionCards` 挂一张任务完成卡，收卡规则同上。
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
    @Published var previewingSource: AgentKind?
    @Published var testingSource: AgentKind?

    private enum Mode { case preview, alert }   // preview=调参(切前台不灭); alert=完成提醒(切前台灭)

    private let settings: SettingsStore
    /// 顶部弹窗挂卡的地方。渲染设置窗的离屏实例没有它，此时弹窗方式什么都不做
    var completionCards: AgentCompletionStore? {
        didSet { observePreviewCard() }
    }
    private var previewCardWatch: AnyCancellable?
    private var activeSource: AgentKind?
    private var activeMode: Mode?
    /// 光晕点亮期间累计的宿主 App bundle id 集合。多会话并发时各自的完成信号都会进来——
    /// 单一宿主变量会被后到信号覆盖,导致「切回先完成的那个 App 灭不掉」;集合语义:切回其中任意一个即熄灭
    private var activeHosts: Set<String> = []
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
        // 面板不在启动时创建：点亮才建、熄灭即拆（真停机——没在发光时零常驻窗口）

        NotificationCenter.default.addObserver(
            forName: .proNotchGlowSettingsChanged,
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
            // 屏幕增减 / 分辨率变化：正在发光才需要重建各屏面板；没发光时下次点亮自然按新屏建
            Task { @MainActor in
                guard let self, !self.panels.isEmpty else { return }
                self.setupPanels()
            }
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

    /// 熄灭后拆掉全部面板：NSPanel + NSHostingView 一起释放，不留常驻窗口
    private func teardownPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    func color(for source: AgentKind) -> Color {
        Color(hex: settings.glowColorHex(for: source))
    }

    // MARK: - 点亮 / 熄灭

    /// 真实完成信号（pronotch://done?source=…）→ 完成提醒（光晕或顶部弹窗）
    func notifyCompletion(_ source: AgentKind, host: String? = nil,
                          session: String = "", project: String = "") {
        // 三道闸每一道都埋一条日志。
        //
        // 原来三种拦截全是静默 return，「跑完了怎么没亮」在界面之外没有任何可观测点，
        // 只能靠读代码猜（大梁老师 2026-07-31 报 Kimi 在 Ghostty 跑完没光晕，
        // 排查到这里才发现根本分不清是没投递到、还是投递了被挡）
        guard settings.glowEnabled else {
            AppLog.glow.debug("完成提醒：光晕总开关关着，\(source.rawValue, privacy: .public) 不点亮")
            return
        }
        guard GlowHookInstaller.isInstalled(source) else {
            AppLog.glow.debug("完成提醒：\(source.rawValue, privacy: .public) 未接入（钩子没装），不点亮")
            return
        }
        // 宿主 App：hook 沿进程链找到的「Agent 实际所在的 GUI App」bundle id；
        // 拿不到（旧 hook / 特殊环境）就回退到该 Agent 的桌面版 bundle id（无桌面版的家为 nil）。
        let hostID = (host?.isEmpty == false) ? host : source.appBundleID
        // 只在 Agent 处于后台时提醒：若宿主 App 已在最前台（你正盯着它跑），就不点亮——
        // 既没必要，光晕也无从熄灭（已在前台，等不到「切回它」的激活事件）。
        if let hostID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hostID {
            AppLog.glow.debug("完成提醒：宿主 \(hostID, privacy: .public) 就在最前台，不点亮")
            return
        }
        if settings.agentAlertStyle == .card {
            completionCards?.present(
                AgentCompletionNotice(source: source, session: session, host: hostID, project: project,
                                      tintHex: settings.glowColorHex(for: source)))
            return
        }
        AppLog.glow.debug("完成提醒：点亮 \(source.rawValue, privacy: .public) 宿主 \(hostID ?? "-", privacy: .public)")
        previewingSource = nil
        testingSource = nil
        if let hostID { activeHosts.insert(hostID) }   // 并发会话各自累计,不互相覆盖
        // 完成信号发在「这轮任务真正结束」时，所以收到即点亮。
        light(source, mode: .alert)
    }

    /// 设置页「测试」按钮：模拟一次真实完成（切前台会灭），再点同色熄灭
    func toggleTest(_ source: AgentKind) {
        guard settings.glowEnabled else { return }
        if testingSource == source { dismiss(); return }
        previewingSource = nil
        testingSource = source
        activeHosts = Set([source.appBundleID].compactMap { $0 })
        light(source, mode: .alert)
    }

    /// 设置页「预览」按钮：常亮调参（切前台不灭），再点同色熄灭。
    /// 顶部弹窗方式下预览的是那张卡
    func togglePreview(_ source: AgentKind) {
        guard settings.glowEnabled else { return }
        if settings.agentAlertStyle == .card { toggleCardPreview(source); return }
        if previewingSource == source { dismiss(); return }
        testingSource = nil
        previewingSource = source
        activeHosts = []
        light(source, mode: .preview)
    }

    /// 预览卡：项目名那行写「预览效果」，点它只收卡不跳转（见 AgentCompletionCardView）
    private func toggleCardPreview(_ source: AgentKind) {
        guard let cards = completionCards else { return }
        let wasPreviewing = previewingSource == source
        withdrawPreviewCard()
        guard !wasPreviewing else { return }
        cards.present(
            AgentCompletionNotice(source: source, session: AgentCompletionNotice.previewSession, host: nil,
                                  project: "预览效果", tintHex: settings.glowColorHex(for: source)))
        previewingSource = source
    }

    private func withdrawPreviewCard() {
        completionCards?.withdraw { $0.session == AgentCompletionNotice.previewSession }
        previewingSource = nil
    }

    /// 预览卡被点掉（或被新的完成卡顶掉）后，设置页按钮要从「停止」变回「预览」
    private func observePreviewCard() {
        guard let cards = completionCards else { previewCardWatch = nil; return }
        previewCardWatch = cards.$notice
            .sink { [weak self] current in
                guard let self, self.settings.agentAlertStyle == .card,
                      self.previewingSource != nil else { return }
                if current?.session != AgentCompletionNotice.previewSession { self.previewingSource = nil }
            }
    }

    private func light(_ source: AgentKind, mode: Mode) {
        if panels.isEmpty { setupPanels() }   // 惰性建：首次点亮（或上次熄灭拆除后）才创建覆盖窗
        activeSource = source
        activeMode = mode
        activeColor = color(for: source)
        fadeTarget = 1
        startLoopIfNeeded()
    }

    func dismiss() {
        fadeTarget = 0   // 由 tick() 淡出到 0 后统一清理
    }

    /// 「完成提醒」光晕：切到任一相关宿主 App 的最前台 → 熄灭（预览类不受影响）
    private func handleAppActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        // 顶部弹窗同一口径收卡。自己被激活（打开设置窗）不算「回到那个 App」
        if bid != Bundle.main.bundleIdentifier { completionCards?.dismiss(activated: bid) }
        guard activeMode == .alert, let source = activeSource else { return }
        // 集合空(旧 hook 没报宿主)回退到该来源桌面版 bundle id；
        // 连桌面版都没有（如 Kimi 且宿主探测失败）→ 无从知道该等谁，切到任意 App 即熄灭，不留永灭不掉的光晕
        let targets = activeHosts.isEmpty ? Set([source.appBundleID].compactMap { $0 }) : activeHosts
        guard targets.isEmpty || targets.contains(bid) else { return }
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
            activeHosts.removeAll()
            previewingSource = nil
            testingSource = nil
            loopTimer?.invalidate(); loopTimer = nil; loopStart = nil
            teardownPanels()   // 淡出走完立即拆窗：不发光时零常驻
        }
    }

    /// 设置变更后同步外观；关闭总开关或取消当前来源的接入勾选则熄灭，预览中则即时换色
    private func syncAppearance() {
        period = settings.glowBreathPeriod
        intensity = settings.glowIntensity
        thickness = settings.glowThickness
        if !settings.glowEnabled {
            dismiss()
            completionCards?.dismiss()
            previewingSource = nil
            return
        }
        // 换了提醒方式：另一种方式正亮着的预览收掉，免得光晕和预览卡同时挂着
        if settings.agentAlertStyle == .card, activeSource != nil {
            dismiss()
        } else if settings.agentAlertStyle == .glow, previewingSource != nil, activeSource == nil {
            withdrawPreviewCard()
        } else if let source = activeSource {
            // 正亮着的来源被取消勾选:立即熄灭——此前勾选框只拦「下次点亮」,当前光晕关不掉
            if activeMode == .alert, !GlowHookInstaller.isInstalled(source) {
                dismiss()
            } else {
                activeColor = color(for: source)
            }
        }
    }
}
