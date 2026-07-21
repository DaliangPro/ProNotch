import Foundation

/// 进程内通知名的单一事实源。
///
/// 这些通知是设置层与消费方之间的解耦线：`SettingsStore` 的属性 `didSet` 里发一条，
/// 关心它的窗口/控制器各自监听——设置页因此不必知道谁在用这个开关。
///
/// 集中定义是因为原先每处都现写 `NSNotification.Name("ProNotchXxx")` 字符串字面量，
/// 一个通知名平均散落两三处；拼错一个字母不会报错，只会静默地不生效
/// （发的人发到一个没人听的名字上，或听的人永远等不到）。改成静态成员后拼错即编译失败。
///
/// 字符串值保持原样，不可改动：DEBUG 跨进程调试通道（见 DebugChannels.swift）
/// 用的是另一套 `com.daliangpro.ProNotch.*` 名字，那些是对外契约，不在此列。
extension Notification.Name {
    // MARK: - 窗口与面板

    /// 面板内齿轮按钮、额度面板的「设置」入口 → 打开设置窗
    static let proNotchOpenSettings = Notification.Name("ProNotchOpenSettings")
    /// 「显示屏幕」设置变更 → 立即按新范围重建刘海窗口
    static let proNotchScreenModeChanged = Notification.Name("ProNotchScreenModeChanged")
    /// 两侧功能区开关变更 → 影响收起态黑条宽度与悬停热区
    static let proNotchSlotSettingsChanged = Notification.Name("ProNotchSlotSettingsChanged")
    /// 展开面板内组件（内存、天气）显隐变更
    static let proNotchWidgetVisibilityChanged = Notification.Name("ProNotchWidgetVisibilityChanged")
    /// 「全屏时隐藏刘海」开关变更 → 立即重新评估当前屏
    static let proNotchFullscreenSettingChanged = Notification.Name("ProNotchFullscreenSettingChanged")
    /// 截图工具栏「问 AI」→ 挂图为闪问附件并展开到闪问页（object 为 NSImage）
    static let proNotchAskAIWithImage = Notification.Name("ProNotchAskAIWithImage")

    // MARK: - Agent 与额度

    /// Agent 接入勾选变更 → 额度、监控台、光晕的扫描范围随之变
    static let proNotchAgentSelectionChanged = Notification.Name("ProNotchAgentSelectionChanged")
    /// 每家 Agent 的「菜单栏显示」勾选变更 → 只影响额度栏标题渲染
    static let proNotchMenuBarAgentsChanged = Notification.Name("ProNotchMenuBarAgentsChanged")
    /// 额度菜单栏总开关变更（主菜单勾选与设置页开关改的是同一份）
    static let proNotchUsageMenuBarChanged = Notification.Name("ProNotchUsageMenuBarChanged")
    /// 光晕提醒设置变更（开关、配色、每家 Agent 的接入状态）
    static let proNotchGlowSettingsChanged = Notification.Name("ProNotchGlowSettingsChanged")

    // MARK: - 剪贴板

    /// 剪贴板记录开关变更 → 开则起轮询，关则真停机（历史仍可看）
    static let proNotchClipboardEnabledChanged = Notification.Name("ProNotchClipboardEnabledChanged")
    /// 剪贴板历史条数上限变更
    static let proNotchClipboardLimitChanged = Notification.Name("ProNotchClipboardLimitChanged")
    /// 设置页「清空历史」按钮
    static let proNotchClipboardClearRequested = Notification.Name("ProNotchClipboardClearRequested")

    // MARK: - 天气

    /// 恶劣天气预警的总开关或类型多选变更 → 兜底定时器随之起停
    static let proNotchWeatherAlertSettingsChanged = Notification.Name("ProNotchWeatherAlertSettingsChanged")

    // MARK: - 全局快捷键改键

    /// 三条改键通知各自触发对应热键的重注册（Carbon 需先注销再注册）
    static let proNotchScreenshotShortcutChanged = Notification.Name("ProNotchScreenshotShortcutChanged")
    static let proNotchClipboardShortcutChanged = Notification.Name("ProNotchClipboardShortcutChanged")
    static let proNotchChatShortcutChanged = Notification.Name("ProNotchChatShortcutChanged")
}
