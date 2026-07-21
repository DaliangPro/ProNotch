import AppKit
import SwiftUI

/// 系统真实状态的读取口。
///
/// 抽出来是为了让「成功之后重新读系统状态」这条规则能被测到——
/// 而不是把预设值（`hide`、`mode`）直接写进 UI 当成事实
@MainActor
struct SystemStateProbe {
    var desktopIconsHidden: () -> Bool = QuickActionsStore.readDesktopIconsHidden
    var appearanceMode: () -> QuickActionsStore.AppearanceMode = QuickActionsStore.readAppearanceMode
}

/// 刘海两侧快捷操作：应用设置、防休眠、净屏、外观切换
@MainActor
final class QuickActionsStore: ObservableObject {
    enum AppearanceMode: String {
        case system = "系统"
        case dark = "深色"
        case light = "浅色"
    }

    @Published private(set) var caffeinateActive = false
    /// 桌面图标是否已隐藏（净屏模式）；跟随 Finder 的 CreateDesktop 偏好
    @Published private(set) var desktopIconsHidden: Bool
    /// 当前外观模式（跟随系统，外部切换也会同步）
    @Published private(set) var appearanceMode: AppearanceMode
    /// 最近一次快捷操作的失败原因；成功即清空
    @Published private(set) var actionError: String?

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

    private let runner: ProcessRunning
    private let probe: SystemStateProbe
    /// 正在跑的那次快捷操作，用来防连点，也给测试一个等待点
    private var pendingAction: Task<Void, Never>?

    /// `probe` 的默认值必须在 init 里构造：`SystemStateProbe` 是 MainActor 隔离的，
    /// 而默认参数在 nonisolated 上下文求值
    init(runner: ProcessRunning = SystemProcessRunner(),
         probe: SystemStateProbe? = nil) {
        let probe = probe ?? SystemStateProbe()
        self.runner = runner
        self.probe = probe
        desktopIconsHidden = probe.desktopIconsHidden()
        appearanceMode = probe.appearanceMode()
        // 系统外观变化（无论谁触发）都同步分段控件状态
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.appearanceMode = self.probe.appearanceMode()
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

    // MARK: - 子进程动作

    /// 排队跑一次快捷操作。同一时刻只允许一个：连点两下净屏会写两次相反的偏好，
    /// 后一次读到的还是前一次没落地的状态
    private func start(_ body: @escaping (QuickActionsStore) async -> Void) {
        guard pendingAction == nil else { return }
        actionError = nil
        pendingAction = Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.pendingAction = nil
        }
    }

    /// 跑子进程并判定成败。**只有退出码 0 才算成功**——
    /// 失败一律保持旧状态，把原因发布到 `actionError`，绝不让 UI 替系统撒谎
    private func succeeded(action: String, executable: String, arguments: [String]) async -> Bool {
        do {
            let result = try await runner.run(executable: executable, arguments: arguments)
            guard result.succeeded else {
                let message = ProcessFailureMessage.text(action: action, result: result)
                actionError = message
                print("[ProNotch] \(message)")
                return false
            }
            return true
        } catch {
            // 起都没起来（可执行文件缺失、沙箱拦截），同样不改状态
            let message = "\(action)失败：无法启动系统命令。"
            actionError = message
            print("[ProNotch] \(message)")
            return false
        }
    }

    /// 测试用等待点：等当前这次快捷操作跑完
    func waitForPendingAction() async {
        await pendingAction?.value
    }

    // MARK: - 外观切换

    /// 自动档标志来自全局偏好；当前深/浅用 effectiveAppearance 判断
    /// （自动模式下系统不一定写 AppleInterfaceStyle，读偏好不可靠）
    static func readAppearanceMode() -> AppearanceMode {
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
            start { await $0.runAppearance(mode) }
        }
    }

    private func runAppearance(_ mode: AppearanceMode) async {
        let script = "tell application \"System Events\" to tell appearance preferences "
            + "to set dark mode to \(mode == .dark)"
        guard await succeeded(action: "外观切换",
                              executable: "/usr/bin/osascript", arguments: ["-e", script]) else { return }
        // 读系统真实状态，不写预设值：脚本返回 0 只说明 AppleEvent 送达没报错。
        // 若系统状态还没传播到（少见），DistributedNotification 观察者随后会补正
        appearanceMode = probe.appearanceMode()
        print("[ProNotch] 外观切换为: \(appearanceMode.rawValue)")
    }

    /// 调试用：打印当前外观状态
    func debugProbeAppearance() {
        print("[ProNotch] 当前外观模式: \(appearanceMode.rawValue)，重新读取: \(Self.readAppearanceMode().rawValue)")
    }

    // MARK: - 其他快捷操作

    /// 打开 ProNotch 自己的设置窗口（窗口由 AppDelegate 持有，走通知解耦）
    func openAppSettings() {
        NotificationCenter.default.post(
            name: .proNotchOpenSettings, object: nil)
        print("[ProNotch] 打开应用设置")
    }

    /// 净屏开关：隐藏/恢复桌面全部图标。走 Finder 的 CreateDesktop 偏好（标准做法，
    /// 完全可逆），改完重启 Finder 生效——副作用是已打开的访达窗口会关闭
    func toggleDesktopIcons() {
        let hide = !desktopIconsHidden
        start { await $0.runDesktopToggle(hide: hide) }
    }

    private func runDesktopToggle(hide: Bool) async {
        // `&&` 让 defaults 失败时不再 killall，sh 也会把非 0 退出码带出来
        let command = "defaults write com.apple.finder CreateDesktop -bool "
            + "\(hide ? "false" : "true") && killall Finder"
        guard await succeeded(action: "净屏切换",
                              executable: "/bin/sh", arguments: ["-c", command]) else { return }
        desktopIconsHidden = probe.desktopIconsHidden()
        print("[ProNotch] 桌面图标已\(desktopIconsHidden ? "隐藏（净屏）" : "恢复显示")")
    }

    /// 读 Finder 的 CreateDesktop 偏好：缺省 / true = 显示图标
    static func readDesktopIconsHidden() -> Bool {
        // defaults write 发生在别的进程，不同步就可能读到本进程缓存的旧值
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
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
