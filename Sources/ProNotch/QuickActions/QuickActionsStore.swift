import AppKit
import SwiftUI

/// 刘海两侧快捷操作：区域截图、应用设置、熄屏锁定、防休眠、外观切换
@MainActor
final class QuickActionsStore: ObservableObject {
    enum AppearanceMode: String {
        case system = "系统"
        case dark = "深色"
        case light = "浅色"
    }

    /// 左侧快捷动作（可拖动排序）；声明序即默认序：锁屏在前、截图在后（大梁老师定）
    enum ActionKind: String, CaseIterable {
        case lockScreen
        case screenshot
        case appSettings

        /// 旧 rawValue 兼容映射（系统设置 → 应用设置），保留已存的拖动顺序
        static let legacyNames: [String: ActionKind] = ["systemSettings": .appSettings]
    }

    /// 快捷动作顺序（持久化）
    @Published var actionOrder: [ActionKind] {
        didSet {
            UserDefaults.standard.set(actionOrder.map(\.rawValue), forKey: "quickActionOrder2")
        }
    }

    @Published private(set) var caffeinateActive = false
    /// 桌面图标是否已隐藏（净屏模式）；跟随 Finder 的 CreateDesktop 偏好
    @Published private(set) var desktopIconsHidden: Bool
    /// 当前外观模式（跟随系统，外部切换也会同步）
    @Published private(set) var appearanceMode: AppearanceMode

    /// 当前实际是否深色（自动档时按系统实际呈现判断），滑动开关用
    var isEffectivelyDark: Bool {
        switch appearanceMode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return NSApp?.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private var caffeinateProcess: Process?
    private var themeObserver: Any?

    init() {
        // key 升位（quickActionOrder → quickActionOrder2）：默认序改为「锁屏、截图」，老持久化一次性重置
        let saved = (UserDefaults.standard.stringArray(forKey: "quickActionOrder2") ?? [])
            .compactMap { ActionKind(rawValue: $0) ?? ActionKind.legacyNames[$0] }
        actionOrder = Set(saved) == Set(ActionKind.allCases) ? saved : ActionKind.allCases
        desktopIconsHidden = Self.readDesktopIconsHidden()
        appearanceMode = Self.readAppearanceMode()
        // 系统外观变化（无论谁触发）都同步分段控件状态
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self?.appearanceMode = Self.readAppearanceMode()
                }
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
            print("[ProNotch] 跳转系统设置外观面板（系统未开放自动档接口）")
        case .dark, .light:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e",
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(mode == .dark)"]
            do {
                try task.run()
                appearanceMode = mode
                print("[ProNotch] 外观切换为: \(mode.rawValue)")
            } catch {
                print("[ProNotch] 外观切换失败: \(error.localizedDescription)")
            }
        }
    }

    /// 调试用：打印当前外观状态
    func debugProbeAppearance() {
        print("[ProNotch] 当前外观模式: \(appearanceMode.rawValue)，重新读取: \(Self.readAppearanceMode().rawValue)")
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
            print("[ProNotch] 已唤起区域截图")
        } catch {
            print("[ProNotch] 截图唤起失败: \(error.localizedDescription)")
        }
    }

    /// 打开 ProNotch 自己的设置窗口（窗口由 AppDelegate 持有，走通知解耦）
    func openAppSettings() {
        NotificationCenter.default.post(
            name: NSNotification.Name("ProNotchOpenSettings"), object: nil)
        print("[ProNotch] 打开应用设置")
    }

    /// 熄屏锁定：CGSession 在新版 macOS 已移除，用 pmset 熄屏替代；
    /// 配合系统「唤醒后立即要求密码」（默认开启）即等效锁屏
    func lockScreen() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        do {
            try task.run()
            print("[ProNotch] 已熄屏锁定")
        } catch {
            print("[ProNotch] 熄屏失败: \(error.localizedDescription)")
        }
    }

    /// 净屏开关：隐藏/恢复桌面全部图标。走 Finder 的 CreateDesktop 偏好（标准做法，
    /// 完全可逆），改完重启 Finder 生效——副作用是已打开的访达窗口会关闭
    func toggleDesktopIcons() {
        let hide = !desktopIconsHidden
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "defaults write com.apple.finder CreateDesktop -bool \(hide ? "false" : "true") && killall Finder"]
        do {
            try task.run()
            desktopIconsHidden = hide
            print("[ProNotch] 桌面图标已\(hide ? "隐藏（净屏）" : "恢复显示")")
        } catch {
            print("[ProNotch] 净屏切换失败: \(error.localizedDescription)")
        }
    }

    /// 读 Finder 的 CreateDesktop 偏好：缺省 / true = 显示图标
    private static func readDesktopIconsHidden() -> Bool {
        guard let v = CFPreferencesCopyAppValue("CreateDesktop" as CFString,
                                                "com.apple.finder" as CFString) else { return false }
        if let n = v as? NSNumber { return !n.boolValue }
        if let s = v as? String { return !(s as NSString).boolValue }
        return false
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
            print("[ProNotch] 防休眠已关闭")
        }
    }

    private func startCaffeinate() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d 防熄屏 -i 防闲置休眠 -s 插电时防系统休眠。
        // 注意：合盖休眠是系统强制行为，任何应用都拦不住；
        // 合盖不睡需走系统合盖模式（电源 + 外接屏 + 外接键鼠）
        task.arguments = ["-d", "-i", "-s"]
        do {
            try task.run()
            caffeinateProcess = task
            caffeinateActive = true
            print("[ProNotch] 防休眠已开启")
        } catch {
            print("[ProNotch] 防休眠启动失败: \(error.localizedDescription)")
        }
    }
}
