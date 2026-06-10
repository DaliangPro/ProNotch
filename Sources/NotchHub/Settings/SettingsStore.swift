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
                name: NSNotification.Name("NotchHubFullscreenSettingChanged"), object: nil)
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
                name: NSNotification.Name("NotchHubClipboardLimitChanged"), object: nil)
        }
    }

    static let clipboardLimitOptions = [50, 100, 200, 500]

    init() {
        launchAtLogin = Self.serviceStatus == .enabled
        UserDefaults.standard.register(defaults: [
            "hideNotchInFullscreen": true,
            "clipboardLimit": 200,
        ])
        hideNotchInFullscreen = UserDefaults.standard.bool(forKey: "hideNotchInFullscreen")
        clipboardLimit = UserDefaults.standard.integer(forKey: "clipboardLimit")
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
                ? "需要在 系统设置 → 通用 → 登录项 中允许 NotchHub"
                : nil
            print("[NotchHub] 开机自启\(launchAtLogin ? "开启" : "关闭")，登录项状态: \(status.rawValue)")
        } catch {
            loginItemHint = "设置失败: \(error.localizedDescription)"
            print("[NotchHub] 开机自启设置失败: \(error.localizedDescription)")
            launchAtLogin = Self.serviceStatus == .enabled
        }
    }
}
