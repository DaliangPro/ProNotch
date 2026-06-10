import AppKit
import SwiftUI

/// 刘海两侧快捷操作：区域截图、系统设置、熄屏锁定、防休眠、外观切换
@MainActor
final class QuickActionsStore: ObservableObject {
    enum AppearanceMode: String {
        case system = "系统"
        case dark = "深色"
        case light = "浅色"
    }

    @Published private(set) var caffeinateActive = false
    /// 当前外观模式（跟随系统，外部切换也会同步）
    @Published private(set) var appearanceMode: AppearanceMode

    private var caffeinateProcess: Process?
    private var themeObserver: Any?

    init() {
        appearanceMode = Self.readAppearanceMode()
        // 系统外观变化（无论谁触发）都同步分段控件状态
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appearanceMode = Self.readAppearanceMode()
            }
        }
    }

    /// 窗口重建/退出前调用：清理子进程与监听
    func stop() {
        stopCaffeinate()
        if let observer = themeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            themeObserver = nil
        }
    }

    // MARK: - 外观切换

    /// 自动档标志来自全局偏好；当前深/浅用 effectiveAppearance 判断
    /// （自动模式下系统不一定写 AppleInterfaceStyle，读偏好不可靠）
    private static func readAppearanceMode() -> AppearanceMode {
        if UserDefaults.standard.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically") {
            return .system
        }
        let dark = NSApp?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .dark : .light
    }

    /// 深/浅走系统脚本接口（首次需授权自动化）；
    /// 「自动」档 macOS 未开放任何程序化接口（私有 SkyLight 接口在
    /// macOS 26 已失效），跳转系统设置外观面板由用户手动选择
    func setAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            print("[NotchHub] 跳转系统设置外观面板（系统未开放自动档接口）")
        case .dark, .light:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e",
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(mode == .dark)"]
            do {
                try task.run()
                appearanceMode = mode
                print("[NotchHub] 外观切换为: \(mode.rawValue)")
            } catch {
                print("[NotchHub] 外观切换失败: \(error.localizedDescription)")
            }
        }
    }

    /// 调试用：打印当前外观状态
    func debugProbeAppearance() {
        print("[NotchHub] 当前外观模式: \(appearanceMode.rawValue)，重新读取: \(Self.readAppearanceMode().rawValue)")
    }

    // MARK: - 其他快捷操作

    /// 区域截图到剪贴板（-i 交互选区 -c 进剪贴板，配合剪贴板历史自动入列）。
    /// 首次使用系统会请求屏幕录制权限
    func screenshotToClipboard() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-c"]
        do {
            try task.run()
            print("[NotchHub] 已唤起区域截图")
        } catch {
            print("[NotchHub] 截图唤起失败: \(error.localizedDescription)")
        }
    }

    func openSystemSettings() {
        let url = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        print("[NotchHub] 打开系统设置")
    }

    /// 熄屏锁定：CGSession 在新版 macOS 已移除，用 pmset 熄屏替代；
    /// 配合系统「唤醒后立即要求密码」（默认开启）即等效锁屏
    func lockScreen() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        do {
            try task.run()
            print("[NotchHub] 已熄屏锁定")
        } catch {
            print("[NotchHub] 熄屏失败: \(error.localizedDescription)")
        }
    }

    /// 防休眠开关：通过子进程 caffeinate -di 阻止显示器与系统休眠
    func toggleCaffeinate() {
        if caffeinateActive {
            stopCaffeinate()
        } else {
            startCaffeinate()
        }
    }

    func stopCaffeinate() {
        caffeinateProcess?.terminate()
        caffeinateProcess = nil
        if caffeinateActive {
            caffeinateActive = false
            print("[NotchHub] 防休眠已关闭")
        }
    }

    private func startCaffeinate() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-di"]
        do {
            try task.run()
            caffeinateProcess = task
            caffeinateActive = true
            print("[NotchHub] 防休眠已开启")
        } catch {
            print("[NotchHub] 防休眠启动失败: \(error.localizedDescription)")
        }
    }
}
