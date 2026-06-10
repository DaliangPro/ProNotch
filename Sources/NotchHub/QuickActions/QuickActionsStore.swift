import AppKit
import SwiftUI

/// 刘海两侧快捷操作：区域截图、系统设置、防休眠、锁屏
@MainActor
final class QuickActionsStore: ObservableObject {
    @Published private(set) var caffeinateActive = false
    private var caffeinateProcess: Process?

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
