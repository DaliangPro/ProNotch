import AppKit
import SwiftUI

/// SkyLight 私有框架封装：免授权即时切换系统外观（含「自动」档）。
/// 符号缺失时 available 为 false，上层自动降级到 osascript（仅深/浅）
private final class SkyLight {
    static let shared = SkyLight()

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetBoolFn = @convention(c) (Int32, Bool) -> Void

    private var connection: Int32 = 0
    private var setLegacy: SetBoolFn?
    private var setAuto: SetBoolFn?

    var available: Bool { setLegacy != nil && setAuto != nil }

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return
        }
        if let symbol = dlsym(handle, "SLSMainConnectionID") {
            connection = unsafeBitCast(symbol, to: ConnectionFn.self)()
        }
        if let symbol = dlsym(handle, "SLSSetAppearanceThemeLegacy") {
            setLegacy = unsafeBitCast(symbol, to: SetBoolFn.self)
        }
        if let symbol = dlsym(handle, "SLSSetAppearanceThemeSwitchesAutomatically") {
            setAuto = unsafeBitCast(symbol, to: SetBoolFn.self)
        }
    }

    func setDark(_ dark: Bool) {
        setLegacy?(connection, dark)
    }

    func setAutoSwitch(_ auto: Bool) {
        setAuto?(connection, auto)
    }
}

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

    private nonisolated static func readAppearanceMode() -> AppearanceMode {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically") {
            return .system
        }
        return defaults.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }

    func setAppearance(_ mode: AppearanceMode) {
        if SkyLight.shared.available {
            switch mode {
            case .system:
                SkyLight.shared.setAutoSwitch(true)
            case .dark:
                SkyLight.shared.setAutoSwitch(false)
                SkyLight.shared.setDark(true)
            case .light:
                SkyLight.shared.setAutoSwitch(false)
                SkyLight.shared.setDark(false)
            }
            appearanceMode = mode
            print("[NotchHub] 外观切换为: \(mode.rawValue)（SkyLight）")
            return
        }
        // 降级：osascript 只能切深/浅，「系统」档不可用
        guard mode != .system else {
            print("[NotchHub] 当前系统不支持「跟随系统」档（SkyLight 不可用）")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e",
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(mode == .dark)"]
        do {
            try task.run()
            appearanceMode = mode
            print("[NotchHub] 外观切换为: \(mode.rawValue)（osascript）")
        } catch {
            print("[NotchHub] 外观切换失败: \(error.localizedDescription)")
        }
    }

    /// 调试用：打印 SkyLight 可用性并以当前值安全回写一次（不改变实际外观）
    func debugProbeAppearance() {
        print("[NotchHub] SkyLight 可用: \(SkyLight.shared.available)，当前模式: \(appearanceMode.rawValue)")
        setAppearance(appearanceMode)
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
