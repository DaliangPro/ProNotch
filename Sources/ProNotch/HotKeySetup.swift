import AppKit

/// 三个全局快捷键的注册入口。
///
/// 它们共一套模式：注册触发闭包 → 按当前设置注册键位 → 监听设置变更通知重注册。
/// 抽出来是因为这套模式往下还会长（每加一个快捷键就是十来行），
/// 挤在 applicationDidFinishLaunching 里会把启动主线淹掉。
///
/// 快捷键属性本身仍归 AppDelegate 持有——Carbon 的 RegisterEventHotKey 是进程级注册，
/// 生命周期必须跟着 App 走。
extension AppDelegate {
    func setupHotKeys() {
        // 超级截图全局快捷键：按下即唤起区域截图；在设置里改快捷键后重新注册
        SuperScreenshotController.shared.settings = env.settings   // 翻译时惰性读配置
        SuperScreenshotController.shared.warmUp()   // 后台预热截图子系统，消除"截图第一下慢"
        screenshotHotKey.onTrigger = {
            Task { @MainActor in SuperScreenshotController.shared.capture() }
        }
        screenshotHotKey.update(env.settings.screenshotShortcut)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchScreenshotShortcutChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.screenshotHotKey.update(self.env.settings.screenshotShortcut)
            }
        }

        // 剪贴板切换器全局快捷键：按下唤出横向卡片面板；设置里改键后重新注册
        clipboardHotKey.onTrigger = {
            Task { @MainActor in ClipboardSwitcherController.shared.toggle() }
        }
        clipboardHotKey.update(env.settings.clipboardShortcut)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchClipboardShortcutChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clipboardHotKey.update(self.env.settings.clipboardShortcut)
            }
        }

        // AI 闪问全局快捷键：按下从刘海弹出对话页；已停在闪问页时再按收起。改键后重新注册
        chatHotKey.onTrigger = { [weak self] in
            Task { @MainActor in self?.toggleChatPanel() }
        }
        chatHotKey.update(env.settings.chatShortcut)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchChatShortcutChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.chatHotKey.update(self.env.settings.chatShortcut)
            }
        }
    }
}
