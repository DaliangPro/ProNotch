import AppKit
import ServiceManagement
import SwiftUI

/// 应用设置：开机自启（SMAppService 登录项）
@MainActor
final class SettingsStore: ObservableObject {
    @Published var launchAtLogin: Bool {
        didSet {
            // 与系统真实状态一致时不重复写入（也防回滚时递归）
            guard launchAtLogin != (Self.serviceStatus == .enabled) else { return }
            applyLaunchAtLogin()
        }
    }
    @Published private(set) var loginItemHint: String?

    /// 打开设置窗口时要求定位到的分区（SettingsView.Section 的 rawValue，如 "AI 闪问"）；
    /// 由刘海内入口（如模型切换器「API 设置…」）置值，SettingsView 显示后消费并清空
    @Published var pendingSection: String?

    /// 当前屏幕有全屏应用时隐藏整个刘海（默认开启：外接屏假刘海会遮挡全屏内容）
    @Published var hideNotchInFullscreen: Bool {
        didSet {
            UserDefaults.standard.set(hideNotchInFullscreen,
                                      forKey: "hideNotchInFullscreen")
            // 通知刘海窗口立即按新设置重判一次
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchFullscreenSettingChanged"), object: nil)
        }
    }

    private static var serviceStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    // MARK: - 收起态刘海两侧功能区
    /// 左/右功能区内容（none 关闭该侧）；变更即持久化并通知刘海窗口调整收起态宽度
    @Published var leftSlot: NotchSlot {
        didSet {
            UserDefaults.standard.set(leftSlot.rawValue, forKey: "notchLeftSlot")
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchSlotSettingsChanged"), object: nil)
        }
    }
    @Published var rightSlot: NotchSlot {
        didSet {
            UserDefaults.standard.set(rightSlot.rawValue, forKey: "notchRightSlot")
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchSlotSettingsChanged"), object: nil)
        }
    }
    /// 任一侧开启即认为功能区激活（收起态黑条加宽保持左右对称，
    /// 只开一侧时另一侧留黑——形状必须以物理刘海为中心，不能不对称）
    var sideSlotsActive: Bool { leftSlot != .none || rightSlot != .none }

    // MARK: - 恶劣天气预警
    /// 预警总开关（默认开）。关闭即停 AppDelegate 的 900 秒兜底定时器——
    /// 预警扫描是那个定时器唯一的存在理由（大卡/槽位天气各有自己的按需刷新）
    @Published var weatherAlertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(weatherAlertsEnabled, forKey: WeatherAlertType.masterKey)
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchWeatherAlertSettingsChanged"), object: nil)
        }
    }
    /// 预警类型多选（默认五类全选）；清空等效关闭，但总开关状态各自保留
    @Published var weatherAlertTypes: Set<WeatherAlertType> {
        didSet {
            UserDefaults.standard.set(weatherAlertTypes.map(\.rawValue).sorted(),
                                      forKey: WeatherAlertType.typesKey)
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchWeatherAlertSettingsChanged"), object: nil)
        }
    }

    // MARK: - 组件页卡片显示（内部开关，独立于收起态两侧槽位「外面」）
    /// 展开面板「组件」页是否显示内存卡（默认开）。这是「内部开关」——只管展开面板里
    /// 那张卡显不显示，与收起态刘海两侧槽位（leftSlot/rightSlot）完全独立（大梁老师定）。
    /// 关 = 组件页不渲染内存卡、停其定时刷新（真停机）
    @Published var memoryWidgetEnabled: Bool {
        didSet {
            UserDefaults.standard.set(memoryWidgetEnabled, forKey: "memoryWidgetEnabled")
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchWidgetVisibilityChanged"), object: nil)
        }
    }
    /// 展开面板「组件」页是否显示天气卡（默认开）。同为「内部开关」，与预警（弹出式）、
    /// 收起态槽位各自独立
    @Published var weatherWidgetEnabled: Bool {
        didSet {
            UserDefaults.standard.set(weatherWidgetEnabled, forKey: "weatherWidgetEnabled")
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchWidgetVisibilityChanged"), object: nil)
        }
    }
    /// 组件页是否还有可见卡片（供 NotchViewModel 判「组件」页显隐，静态读避免耦合实例）。
    /// 无存值兜底 true——新键未注册时保守显示，不让首帧误判成隐藏
    nonisolated static func anyWidgetVisible() -> Bool {
        let d = UserDefaults.standard
        let mem = d.object(forKey: "memoryWidgetEnabled") as? Bool ?? true
        let wea = d.object(forKey: "weatherWidgetEnabled") as? Bool ?? true
        return mem || wea
    }

    /// 剪贴板历史记录开关（默认开）。关 = 停 0.5 秒轮询（真停机），已有历史保留可看；
    /// 清历史是独立按钮的职责——误关开关不丢数据（大梁老师定）
    @Published var clipboardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled")
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchClipboardEnabledChanged"), object: nil)
        }
    }

    /// 剪贴板历史保留条数
    @Published var clipboardLimit: Int {
        didSet {
            UserDefaults.standard.set(clipboardLimit, forKey: "clipboardLimit")
            // 通知剪贴板数据源立即按新上限裁剪
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchClipboardLimitChanged"), object: nil)
        }
    }

    static let clipboardLimitOptions = [50, 100, 200, 500]

    /// 超级截图全局快捷键（nil = 未设置）；变更后通知 AppDelegate 重新注册
    @Published var screenshotShortcut: ScreenshotShortcut? {
        didSet {
            if let s = screenshotShortcut, let data = try? JSONEncoder().encode(s) {
                UserDefaults.standard.set(data, forKey: "screenshotShortcut")
            } else {
                UserDefaults.standard.removeObject(forKey: "screenshotShortcut")
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchScreenshotShortcutChanged"), object: nil)
        }
    }

    /// 剪贴板切换器全局快捷键（nil = 未设置）；变更后通知 AppDelegate 重新注册
    @Published var clipboardShortcut: ScreenshotShortcut? {
        didSet {
            if let s = clipboardShortcut, let data = try? JSONEncoder().encode(s) {
                UserDefaults.standard.set(data, forKey: "clipboardShortcut")
            } else {
                UserDefaults.standard.removeObject(forKey: "clipboardShortcut")
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchClipboardShortcutChanged"), object: nil)
        }
    }

    /// AI 闪问全局快捷键（nil = 未设置）：按下从刘海弹出对话页；变更后通知 AppDelegate 重新注册
    @Published var chatShortcut: ScreenshotShortcut? {
        didSet {
            if let s = chatShortcut, let data = try? JSONEncoder().encode(s) {
                UserDefaults.standard.set(data, forKey: "chatShortcut")
            } else {
                UserDefaults.standard.removeObject(forKey: "chatShortcut")
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchChatShortcutChanged"), object: nil)
        }
    }

    // MARK: - 翻译（超级截图原位翻译）
    @Published var translateTargetLang: String { didSet { UserDefaults.standard.set(translateTargetLang, forKey: "translateTargetLang") } }
    @Published var translateUseChatAPI: Bool { didSet { UserDefaults.standard.set(translateUseChatAPI, forKey: "translateUseChatAPI") } }
    @Published var translateBaseURL: String { didSet { UserDefaults.standard.set(translateBaseURL, forKey: "translateBaseURL") } }
    @Published var translateModel: String { didSet { UserDefaults.standard.set(translateModel, forKey: "translateModel") } }
    /// 并行加速：长文按块并发翻译（默认开）；接口对并发限流严格时可关掉走单请求
    @Published var translateParallel: Bool { didSet { UserDefaults.standard.set(translateParallel, forKey: "translateParallel") } }
    /// 翻译引擎：system=系统翻译（macOS 15+，本机离线毫秒级）；ai=自填 AI 接口。系统引擎失败自动降级 AI
    @Published var translateEngine: String { didSet { UserDefaults.standard.set(translateEngine, forKey: "translateEngine") } }
    /// 翻译提示词（可编辑）；其中 {lang} 翻译时替换为目标语言
    @Published var translatePrompt: String { didSet { UserDefaults.standard.set(translatePrompt, forKey: "translatePrompt") } }

    nonisolated static let defaultTranslatePrompt = "You are a professional translation engine. Translate EVERY string in the input JSON array into {lang}, including single words, labels and UI text. If a string is already in {lang} keep it; otherwise you MUST translate it — never leave non-{lang} text untranslated. Keep as-is: product or brand names (e.g. deepseek, GitHub), code identifiers and function names (e.g. runTranslate, NaturalLanguage), all-letter acronyms (e.g. AI, API, OCR), code values with digits (e.g. status=200, v1.6.0), URLs, file paths and numbers. Return ONLY a JSON array of translated strings, same length and order, no explanations, no code fences."

    /// 翻译 API key 走钥匙串、惰性读写（不在启动时读，避免多一个钥匙串弹框）
    func translateAPIKey() -> String { KeychainStore.read("translateAPIKey") ?? "" }
    func setTranslateAPIKey(_ v: String) { _ = KeychainStore.save(v, account: "translateAPIKey") }

    /// 翻译实际用的接口配置：复用闪问 或 翻译自填
    var resolvedTranslateConfig: (baseURL: String, apiKey: String, model: String) {
        if translateUseChatAPI {
            return (UserDefaults.standard.string(forKey: "chatBaseURL") ?? "",
                    KeychainStore.read("chatAPIKey") ?? "",
                    UserDefaults.standard.string(forKey: "chatModel") ?? "")
        }
        return (translateBaseURL, KeychainStore.read("translateAPIKey") ?? "", translateModel)
    }

    static let translateLangs = ["中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский"]

    // MARK: - Agent 数据源勾选
    /// 监控哪些本机 Agent（每家一个总开关：额度 + 监控台 + 会话榜一体联动）。
    /// 变更即持久化并广播：UsageStore / AgentSessionsStore 立刻按新勾选重扫，
    /// 菜单栏额度栏标题同步增减
    @Published var enabledAgents: Set<AgentKind> {
        didSet {
            UserDefaults.standard.set(enabledAgents.map(\.rawValue).sorted(),
                                      forKey: AgentKind.selectionKey)
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchAgentSelectionChanged"), object: nil)
            // 与完成提醒联动（大梁老师定）：家关闭即卸它的钩子——设置里该家的提醒行随之
            // 隐藏，不能留一个没有界面可关的孤儿钩子继续点亮光晕；重新接入且光晕总开关
            // 开着则恢复。变更后广播一次，正亮着的光晕立即按新状态熄灭
            let removed = oldValue.subtracting(enabledAgents).filter(\.supportsGlow)
            let added = enabledAgents.subtracting(oldValue).filter(\.supportsGlow)
            guard !removed.isEmpty || !added.isEmpty else { return }
            for kind in removed { GlowHookInstaller.setInstalled(kind, false) }
            if glowEnabled {
                for kind in added { GlowHookInstaller.setInstalled(kind, true) }
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchGlowSettingsChanged"), object: nil)
        }
    }

    // MARK: - 菜单栏额度栏
    /// 菜单栏额度栏总开关（与主菜单「Agent 额度」勾选同一份状态，两处双向同步）。
    /// 关 = status item 隐藏 + 60 秒定时刷新停（真停机）
    @Published var showUsageInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showUsageInMenuBar, forKey: "showUsageInMenuBar")
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchUsageMenuBarChanged"), object: nil)
        }
    }
    /// 菜单栏标题露出哪些家（默认全家）：刘海里看全量、菜单栏只挑常用的——
    /// 与 enabledAgents 取交集渲染，只影响标题，详情面板与刘海各页不受影响
    @Published var menuBarAgents: Set<AgentKind> {
        didSet {
            UserDefaults.standard.set(menuBarAgents.map(\.rawValue).sorted(),
                                      forKey: "menuBarAgents")
            NotificationCenter.default.post(
                name: NSNotification.Name("ProNotchMenuBarAgentsChanged"), object: nil)
        }
    }

    // MARK: - 光晕提醒
    @Published var glowEnabled: Bool {
        didSet {
            persistGlow(glowEnabled, "glowEnabled")
            // 总开关：打开默认接入全部支持完成钩子的家、关闭全部移除（具体勾选谁再由勾选框微调）。
            // 放 didSet 而非 binding set，避开「set 里改被绑值」的 re-entrancy。
            // 同值赋值不动钩子：否则「取消勾选一家但还剩别家」时会把刚移除的钩子装回去
            guard oldValue != glowEnabled else { return }
            // 只装 enabledAgents 里的家：被关掉的家不因总开关重开而被误装回钩子
            for kind in AgentKind.allCases where kind.supportsGlow {
                GlowHookInstaller.setInstalled(kind, glowEnabled && enabledAgents.contains(kind))
            }
        }
    }
    @Published var glowClaudeColorHex: String { didSet { persistGlow(glowClaudeColorHex, "glowClaudeColorHex") } }
    @Published var glowCodexColorHex: String { didSet { persistGlow(glowCodexColorHex, "glowCodexColorHex") } }
    @Published var glowKimiColorHex: String { didSet { persistGlow(glowKimiColorHex, "glowKimiColorHex") } }
    @Published var glowGrokColorHex: String { didSet { persistGlow(glowGrokColorHex, "glowGrokColorHex") } }

    /// 光晕色按家取（GlowController 点亮时用）
    func glowColorHex(for kind: AgentKind) -> String {
        switch kind {
        case .claude: return glowClaudeColorHex
        case .codex: return glowCodexColorHex
        case .kimi: return glowKimiColorHex
        case .grok: return glowGrokColorHex
        default: return "#FFFFFF"
        }
    }
    /// 设置页取色器写回（与上面的读一一对应）
    func setGlowColorHex(_ hex: String, for kind: AgentKind) {
        switch kind {
        case .claude: glowClaudeColorHex = hex
        case .codex: glowCodexColorHex = hex
        case .kimi: glowKimiColorHex = hex
        case .grok: glowGrokColorHex = hex
        default: break
        }
    }
    @Published var glowBreathPeriod: Double { didSet { persistGlow(glowBreathPeriod, "glowBreathPeriod") } }
    @Published var glowIntensity: Double { didSet { persistGlow(glowIntensity, "glowIntensity") } }
    @Published var glowThickness: Double { didSet { persistGlow(glowThickness, "glowThickness") } }

    /// 光晕设置统一写入 UserDefaults，并通知 GlowController 即时刷新外观
    private func persistGlow(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(
            name: NSNotification.Name("ProNotchGlowSettingsChanged"), object: nil)
    }

    init() {
        launchAtLogin = Self.serviceStatus == .enabled
        UserDefaults.standard.register(defaults: [
            "hideNotchInFullscreen": true,
            "memoryWidgetEnabled": true,
            "weatherWidgetEnabled": true,
            "clipboardEnabled": true,
            "clipboardLimit": 200,
            "glowEnabled": true,
            "glowClaudeColorHex": "#FF8A00",
            "glowCodexColorHex": "#0A84FF",
            "glowKimiColorHex": "#2ED3B7",
            "glowGrokColorHex": "#FFFFFF",
            "glowBreathPeriod": 3.2,
            "glowIntensity": 0.9,
            "glowThickness": 90.0,
            "translateTargetLang": "中文",
            "translateUseChatAPI": true,
        ])
        hideNotchInFullscreen = UserDefaults.standard.bool(forKey: "hideNotchInFullscreen")
        weatherAlertsEnabled = UserDefaults.standard.object(forKey: WeatherAlertType.masterKey) as? Bool ?? true
        // 类型多选：有存值用存值（空数组 = 用户主动全清，尊重）；无存值默认全选
        weatherAlertTypes = UserDefaults.standard.stringArray(forKey: WeatherAlertType.typesKey)
            .map { Set($0.compactMap(WeatherAlertType.init(rawValue:))) }
            ?? Set(WeatherAlertType.allCases)
        memoryWidgetEnabled = UserDefaults.standard.bool(forKey: "memoryWidgetEnabled")
        weatherWidgetEnabled = UserDefaults.standard.bool(forKey: "weatherWidgetEnabled")
        clipboardEnabled = UserDefaults.standard.bool(forKey: "clipboardEnabled")
        clipboardLimit = UserDefaults.standard.integer(forKey: "clipboardLimit")
        // 菜单栏额度：沿用旧键（老用户开关状态原样保留，默认关）；家勾选无存值默认全家
        showUsageInMenuBar = UserDefaults.standard.bool(forKey: "showUsageInMenuBar")
        menuBarAgents = UserDefaults.standard.stringArray(forKey: "menuBarAgents")
            .map { Set($0.compactMap(AgentKind.init(rawValue:))) } ?? Set(AgentKind.allCases)
        leftSlot = NotchSlot(rawValue: UserDefaults.standard.string(forKey: "notchLeftSlot") ?? "") ?? .memory
        rightSlot = NotchSlot(rawValue: UserDefaults.standard.string(forKey: "notchRightSlot") ?? "") ?? .weather
        glowEnabled = UserDefaults.standard.bool(forKey: "glowEnabled")
        glowClaudeColorHex = UserDefaults.standard.string(forKey: "glowClaudeColorHex") ?? "#FF8A00"
        glowCodexColorHex = UserDefaults.standard.string(forKey: "glowCodexColorHex") ?? "#0A84FF"
        glowKimiColorHex = UserDefaults.standard.string(forKey: "glowKimiColorHex") ?? "#2ED3B7"
        glowGrokColorHex = UserDefaults.standard.string(forKey: "glowGrokColorHex") ?? "#FFFFFF"
        glowBreathPeriod = UserDefaults.standard.double(forKey: "glowBreathPeriod")
        glowIntensity = UserDefaults.standard.double(forKey: "glowIntensity")
        glowThickness = UserDefaults.standard.double(forKey: "glowThickness")
        translateTargetLang = UserDefaults.standard.string(forKey: "translateTargetLang") ?? "中文"
        translateUseChatAPI = UserDefaults.standard.bool(forKey: "translateUseChatAPI")
        translateBaseURL = UserDefaults.standard.string(forKey: "translateBaseURL") ?? ""
        translateModel = UserDefaults.standard.string(forKey: "translateModel") ?? ""
        translateParallel = UserDefaults.standard.object(forKey: "translateParallel") as? Bool ?? true
        translateEngine = UserDefaults.standard.string(forKey: "translateEngine")
            ?? (SystemTranslator.isSupported ? "system" : "ai")
        translatePrompt = UserDefaults.standard.string(forKey: "translatePrompt") ?? Self.defaultTranslatePrompt
        // Agent 勾选：有存值用存值；首启/升级则本机检测一次，检测到的默认全勾
        // （升级无感，大梁老师定）——目录 stat 检查毫秒级，不会拖慢启动
        let detected = Set(AgentProbe.detect().filter(\.installed).map(\.kind))
        if let raw = UserDefaults.standard.stringArray(forKey: AgentKind.selectionKey) {
            // 升级新增的家（如 kimi）不在历史 known 集里：检测到即补勾一次，老家的勾选原样保留。
            // known 无存值 = M1 老版本（当时只有 claude/codex/grok 三家）
            let known = UserDefaults.standard.stringArray(forKey: AgentKind.knownKey)
                .map { Set($0.compactMap(AgentKind.init(rawValue:))) } ?? [.claude, .codex, .grok]
            let merged = AgentKind.mergeNewlyDetected(
                current: Set(raw.compactMap(AgentKind.init(rawValue:))),
                known: known, detectedInstalled: detected)
            enabledAgents = merged.enabled
            UserDefaults.standard.set(merged.enabled.map(\.rawValue).sorted(),
                                      forKey: AgentKind.selectionKey)
            UserDefaults.standard.set(merged.known.map(\.rawValue).sorted(),
                                      forKey: AgentKind.knownKey)
        } else {
            enabledAgents = detected
            UserDefaults.standard.set(detected.map(\.rawValue).sorted(),
                                      forKey: AgentKind.selectionKey)
            UserDefaults.standard.set(AgentKind.allCases.map(\.rawValue).sorted(),
                                      forKey: AgentKind.knownKey)
        }
        if let data = UserDefaults.standard.data(forKey: "screenshotShortcut") {
            screenshotShortcut = try? JSONDecoder().decode(ScreenshotShortcut.self, from: data)
        } else {
            screenshotShortcut = nil
        }
        if let data = UserDefaults.standard.data(forKey: "chatShortcut") {
            chatShortcut = try? JSONDecoder().decode(ScreenshotShortcut.self, from: data)
        } else {
            chatShortcut = nil
        }
        // 剪贴板快捷键：有存值用存值；从未设过则给默认 ⌥⌘V 并持久化；用户清空过则尊重为 nil
        if let data = UserDefaults.standard.data(forKey: "clipboardShortcut") {
            clipboardShortcut = try? JSONDecoder().decode(ScreenshotShortcut.self, from: data)
        } else if UserDefaults.standard.bool(forKey: "clipboardShortcutInitialized") {
            clipboardShortcut = nil
        } else {
            let def = ScreenshotShortcut(keyCode: 9 /* V */,
                                         modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
                                         keyLabel: "V")
            clipboardShortcut = def
            if let d = try? JSONEncoder().encode(def) { UserDefaults.standard.set(d, forKey: "clipboardShortcut") }
            UserDefaults.standard.set(true, forKey: "clipboardShortcutInitialized")
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let status = Self.serviceStatus
            loginItemHint = status == .requiresApproval
                ? "需要在 系统设置 → 通用 → 登录项 中允许 ProNotch"
                : nil
            print("[ProNotch] 开机自启\(launchAtLogin ? "开启" : "关闭")，登录项状态: \(status.rawValue)")
        } catch {
            loginItemHint = "设置失败: \(error.localizedDescription)"
            print("[ProNotch] 开机自启设置失败: \(error.localizedDescription)")
            launchAtLogin = Self.serviceStatus == .enabled
        }
    }
}
