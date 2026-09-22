import AppKit
import ApplicationServices
import CoreGraphics
import CoreLocation

/// 设置页要展示的三种系统权限。
///
/// 此前三处权限要么一句灰字要么什么都没有，屏幕录制更是截图最常见的故障点却无处可见
///（2026-09-21 产品审阅第 6 条）。现在通用页集中列三项，功能页只在未授权时弹一行警告
enum PermissionKind {
    /// 辅助功能：音量 / 亮度提示接管按键
    case accessibility
    /// 定位：天气
    case location
    /// 屏幕录制：超级截图
    case screenRecording

    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .location: return "定位"
        case .screenRecording: return "屏幕录制"
        }
    }

    /// 它管哪个功能（通用页权限卡的副标题）
    var usedBy: String {
        switch self {
        case .accessibility: return "音量与亮度"
        case .location: return "天气"
        case .screenRecording: return "截图"
        }
    }

    /// 系统设置「隐私与安全性」里对应面板的锚点
    fileprivate var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .location: return "Privacy_LocationServices"
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }
}

enum PermissionStatus {
    /// 当前是否已授权。全部是只读查询，不会弹系统授权框
    static func granted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .location:
            let status = CLLocationManager().authorizationStatus
            return status == .authorizedAlways || status == .authorized
        }
    }

    /// 「去授权」：打开系统设置对应的隐私面板
    static func openSystemSettings(_ kind: PermissionKind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
