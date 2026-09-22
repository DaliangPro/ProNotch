import Foundation

/// 设置窗七个分区（2026-09-22 定稿）。通用在首，功能页在中，AI 模型配置在最后（大梁老师定）。
/// rawValue 即侧栏标题，也是外部跳转（pendingSection）与离屏快照（-snapshotSettings -section）用的名字。
/// 侧栏不带图标
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case notch = "刘海设置"
    case chat = "AI 闪问"
    case screenshot = "超级截图"
    case clipboard = "剪贴板与话术"
    case agent = "Agent 提醒"
    case models = "AI 模型配置"

    var id: String { rawValue }
}
