import AppKit
import SwiftUI

/// 刘海两侧快捷操作：区域截图、系统设置、防休眠、锁屏
@MainActor
final class QuickActionsStore: ObservableObject {
    @Published private(set) var caffeinateActive = false
    /// 当前是否深色模式（跟随系统，外部切换也会同步）
    @Published private(set) var isDarkMode: Bool
    private var caffeinateProcess: Process?
    private var themeObserver: Any?

    init() {
        isDarkMode = Self.readSystemDarkMode()
        // 系统外观变化（无论谁触发）都同步更新图标
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isDarkMode = Self.readSystemDarkMode()
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

    private nonisolated static func readSystemDarkMode() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// 深浅色切换：走 System Events 自动化接口，首次使用系统会请求授权
    func toggleAppearance() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e",
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"]
        do {
            try task.run()
            print("[NotchHub] 切换深浅色模式")
        } catch {
            print("[NotchHub] 深浅色切换失败: \(error.localizedDescription)")
        }
    }

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
