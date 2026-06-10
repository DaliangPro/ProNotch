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

    /// 当前屏幕有全屏应用时禁用悬停展开
    @Published var disableHoverInFullscreen: Bool {
        didSet {
            UserDefaults.standard.set(disableHoverInFullscreen,
                                      forKey: "disableHoverInFullscreen")
        }
    }

    private static var serviceStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    init() {
        launchAtLogin = Self.serviceStatus == .enabled
        disableHoverInFullscreen = UserDefaults.standard.bool(forKey: "disableHoverInFullscreen")
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
