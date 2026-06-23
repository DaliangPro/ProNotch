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

    /// 妙记的收件箱文件路径（支持 ~ 缩写）
    @Published var captureInboxPath: String {
        didSet {
            UserDefaults.standard.set(captureInboxPath, forKey: "captureInboxPath")
        }
    }

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

    // MARK: - 翻译（超级截图原位翻译）
    @Published var translateTargetLang: String { didSet { UserDefaults.standard.set(translateTargetLang, forKey: "translateTargetLang") } }
    @Published var translateUseChatAPI: Bool { didSet { UserDefaults.standard.set(translateUseChatAPI, forKey: "translateUseChatAPI") } }
    @Published var translateBaseURL: String { didSet { UserDefaults.standard.set(translateBaseURL, forKey: "translateBaseURL") } }
    @Published var translateModel: String { didSet { UserDefaults.standard.set(translateModel, forKey: "translateModel") } }
    /// 翻译提示词（可编辑）；其中 {lang} 翻译时替换为目标语言
    @Published var translatePrompt: String { didSet { UserDefaults.standard.set(translatePrompt, forKey: "translatePrompt") } }

    static let defaultTranslatePrompt = "You are a professional translation engine. Translate EVERY string in the input JSON array into {lang}, including single words, labels, UI text and technical terms. If a string is already in {lang} keep it; otherwise you MUST translate it — never leave non-{lang} text untranslated. Keep numbers, URLs and code symbols as-is. Return ONLY a JSON array of translated strings, same length and order, no explanations, no code fences."

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
            "captureInboxPath": "~/Documents/妙记.md",
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
        captureInboxPath = UserDefaults.standard.string(forKey: "captureInboxPath")
            ?? "~/Documents/妙记.md"
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
        translatePrompt = UserDefaults.standard.string(forKey: "translatePrompt") ?? Self.defaultTranslatePrompt
        if let data = UserDefaults.standard.data(forKey: "screenshotShortcut") {
            screenshotShortcut = try? JSONDecoder().decode(ScreenshotShortcut.self, from: data)
        } else {
            screenshotShortcut = nil
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
