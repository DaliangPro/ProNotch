import Foundation

/// 设置窗六个分区（2026-09-21 最终版）。顺序按 macOS 惯例通用在首，
/// 然后从看得见的刘海到后台 Agent。rawValue 即侧栏标题，也是外部跳转（pendingSection）
/// 与离屏快照（-snapshotSettings -section）用的名字
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case notch = "刘海"
    case screenshot = "超级截图"
    case clipboard = "剪贴板与话术"
    case chat = "AI 闪问"
    case agent = "Agent"

    var id: String { rawValue }

    /// 侧栏图标（SF Symbols）
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "macbook"
        case .screenshot: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .agent: return "cpu"
        }
    }
}
