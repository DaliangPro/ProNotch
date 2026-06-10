import AppKit
import SwiftUI

/// 设置窗口：菜单栏「设置…」打开的独立窗口
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: SettingsStore, chatStore: ChatStore) {
        if window == nil {
            let root = SettingsView()
                .environmentObject(settings)
                .environmentObject(chatStore)
            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "NotchHub 设置"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
