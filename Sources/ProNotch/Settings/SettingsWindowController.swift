import AppKit
import SwiftUI

/// 设置窗口：菜单栏「设置…」打开的独立窗口
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: SettingsStore, chatStore: ChatStore, glow: GlowController) {
        if window == nil {
            let root = SettingsView()
                .environmentObject(settings)
                .environmentObject(chatStore)
                .environmentObject(glow)
            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "ProNotch 设置"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            // 深色半透明风格：透明标题栏 + 毛玻璃背景由内容视图提供
            newWindow.titlebarAppearsTransparent = true
            newWindow.appearance = NSAppearance(named: .darkAqua)
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.isMovableByWindowBackground = true
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
