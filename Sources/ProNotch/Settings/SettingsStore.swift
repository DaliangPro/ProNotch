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
        }
    }

    // MARK: - 光晕提醒
    @Published var glowEnabled: Bool {
        didSet {
            persistGlow(glowEnabled, "glowEnabled")
            // 总开关：打开默认接入两个 Agent、关闭移除两个（具体勾选谁再由勾选框微调）。
            // 放 didSet 而非 binding set，避开「set 里改被绑值」的 re-entrancy。
            GlowHookInstaller.setInstalled(.claude, glowEnabled)
            GlowHookInstaller.setInstalled(.codex, glowEnabled)
        }
    }
    @Published var glowClaudeColorHex: String { didSet { persistGlow(glowClaudeColorHex, "glowClaudeColorHex") } }
    @Published var glowCodexColorHex: String { didSet { persistGlow(glowCodexColorHex, "glowCodexColorHex") } }
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
            "clipboardLimit": 200,
            "glowEnabled": true,
            "glowClaudeColorHex": "#FF8A00",
            "glowCodexColorHex": "#0A84FF",
            "glowBreathPeriod": 3.2,
            "glowIntensity": 0.9,
            "glowThickness": 90.0,
            "translateTargetLang": "中文",
            "translateUseChatAPI": true,
        ])
        hideNotchInFullscreen = UserDefaults.standard.bool(forKey: "hideNotchInFullscreen")
        clipboardLimit = UserDefaults.standard.integer(forKey: "clipboardLimit")
        leftSlot = NotchSlot(rawValue: UserDefaults.standard.string(forKey: "notchLeftSlot") ?? "") ?? .memory
        rightSlot = NotchSlot(rawValue: UserDefaults.standard.string(forKey: "notchRightSlot") ?? "") ?? .weather
        glowEnabled = UserDefaults.standard.bool(forKey: "glowEnabled")
        glowClaudeColorHex = UserDefaults.standard.string(forKey: "glowClaudeColorHex") ?? "#FF8A00"
        glowCodexColorHex = UserDefaults.standard.string(forKey: "glowCodexColorHex") ?? "#0A84FF"
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
        // （升级无感，大梁老师定）——三个目录的 stat 检查毫秒级，不会拖慢启动
        if let raw = UserDefaults.standard.stringArray(forKey: AgentKind.selectionKey) {
            enabledAgents = Set(raw.compactMap(AgentKind.init(rawValue:)))
        } else {
            let detected = Set(AgentProbe.detect().filter(\.installed).map(\.kind))
            enabledAgents = detected
            UserDefaults.standard.set(detected.map(\.rawValue).sorted(),
                                      forKey: AgentKind.selectionKey)
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
