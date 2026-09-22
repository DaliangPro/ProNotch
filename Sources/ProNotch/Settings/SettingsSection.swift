import Foundation

/// 设置窗七个分区（2026-09-22 定稿）。顺序：先基础后功能、被依赖的在前——
/// AI 模型配置放在闪问与截图之前，这两个功能都靠它。rawValue 即侧栏标题，
/// 也是外部跳转（pendingSection）与离屏快照（-snapshotSettings -section）用的名字。
/// 侧栏不带图标（大梁老师定）
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case notch = "刘海设置"
    case models = "AI 模型配置"
    case chat = "AI 闪问"
    case screenshot = "超级截图"
    case clipboard = "剪贴板与话术"
    case agent = "Agent 提醒"

    var id: String { rawValue }
}
