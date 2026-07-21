import Foundation

/// 设置项在 UserDefaults 里的键名，单一事实源。
///
/// 同一个键此前要在三处各写一遍字符串：`register(defaults:)` 注册默认值、
/// `init` 里读、属性 `didSet` 里写。少写一处或拼错一个字母都不会报错——
/// 读的人拿到默认值、写的人写进一个没人读的键，设置表现为「改了没反应」。
/// `clipboardLimit`、`chatBaseURL`、`chatModel` 更是跨文件重复，断链更难察觉。
///
/// 注：钥匙串账户名不在此列。`chatAPIKey` 这类字符串同时是旧版 UserDefaults 键
/// 和钥匙串账户名（见 ChatStore 的迁移逻辑），横跨两个存储系统，改动风险与收益不成正比。
/// 已就地定义为静态常量的键（`AgentKind.selectionKey`、`WeatherAlertType.masterKey`、
/// `LauncherStore.pinnedKey` 等）也保持原位——它们已经解决了同一个问题。
enum PrefKey {
    // MARK: - 刘海窗口
    static let hideNotchInFullscreen = "hideNotchInFullscreen"
    static let notchScreenMode = "notchScreenMode"
    static let notchLeftSlot = "notchLeftSlot"
    static let notchRightSlot = "notchRightSlot"

    // MARK: - 组件页卡片
    static let memoryWidgetEnabled = "memoryWidgetEnabled"
    static let weatherWidgetEnabled = "weatherWidgetEnabled"

    // MARK: - 剪贴板
    static let clipboardEnabled = "clipboardEnabled"
    /// 历史保留条数：SettingsStore 写、ClipboardStore 读
    static let clipboardLimit = "clipboardLimit"

    // MARK: - 全局快捷键
    static let screenshotShortcut = "screenshotShortcut"
    static let clipboardShortcut = "clipboardShortcut"
    /// 区分「从未设过」与「用户主动清空」：前者给默认 ⌥⌘V，后者尊重为无
    static let clipboardShortcutInitialized = "clipboardShortcutInitialized"
    static let chatShortcut = "chatShortcut"

    // MARK: - 菜单栏额度
    static let showUsageInMenuBar = "showUsageInMenuBar"
    static let menuBarAgents = "menuBarAgents"

    // MARK: - 光晕提醒
    static let glowEnabled = "glowEnabled"
    static let glowClaudeColorHex = "glowClaudeColorHex"
    static let glowCodexColorHex = "glowCodexColorHex"
    static let glowKimiColorHex = "glowKimiColorHex"
    static let glowGrokColorHex = "glowGrokColorHex"
    static let glowBreathPeriod = "glowBreathPeriod"
    static let glowIntensity = "glowIntensity"
    static let glowThickness = "glowThickness"

    // MARK: - 截图翻译
    static let translateTargetLang = "translateTargetLang"
    static let translateUseChatAPI = "translateUseChatAPI"
    static let translateBaseURL = "translateBaseURL"
    static let translateModel = "translateModel"
    static let translateParallel = "translateParallel"
    static let translateEngine = "translateEngine"
    static let translatePrompt = "translatePrompt"

    // MARK: - AI 闪问（ChatStore 拥有，翻译「复用闪问接口」时也要读）
    static let chatBaseURL = "chatBaseURL"
    static let chatModel = "chatModel"
}

/// 有默认值的设置项：默认值在此定义一次。
///
/// 注册与读取两条路径都取自这里——此前光晕四色与翻译目标语言的默认值
/// 在 `register(defaults:)` 和 `init` 的 `?? 字面量` 各写了一遍，
/// 改配色时漏改一处，两个值就会分叉（取决于用户有没有存过值，表现随机）。
enum PrefDefault {
    static let glowClaudeColor = "#FF8A00"
    static let glowCodexColor = "#0A84FF"
    static let glowKimiColor = "#2ED3B7"
    static let glowGrokColor = "#FFFFFF"
    static let translateTargetLang = "中文"

    /// 注册默认值。
    ///
    /// `register(defaults:)` 写的是**易失域**：进程内有效、不落盘，每次启动都要重注册。
    /// 因此 `bool(forKey:)` / `integer(forKey:)` / `double(forKey:)` 这些无默认值的读法
    /// 才能拿到 true / 200 / 90.0 而不是 false / 0 / 0.0——去掉任何一项，
    /// 从未改过该设置的老用户会静默地变成「关闭 / 0 条 / 0 粗细」。
    static func register() {
        UserDefaults.standard.register(defaults: [
            PrefKey.hideNotchInFullscreen: true,
            PrefKey.memoryWidgetEnabled: true,
            PrefKey.weatherWidgetEnabled: true,
            PrefKey.clipboardEnabled: true,
            PrefKey.clipboardLimit: 200,
            PrefKey.glowEnabled: true,
            PrefKey.glowClaudeColorHex: glowClaudeColor,
            PrefKey.glowCodexColorHex: glowCodexColor,
            PrefKey.glowKimiColorHex: glowKimiColor,
            PrefKey.glowGrokColorHex: glowGrokColor,
            PrefKey.glowBreathPeriod: 3.2,
            PrefKey.glowIntensity: 0.9,
            PrefKey.glowThickness: 90.0,
            PrefKey.translateTargetLang: translateTargetLang,
            PrefKey.translateUseChatAPI: true,
        ])
    }
}
