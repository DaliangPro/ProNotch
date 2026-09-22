import AppKit
import SwiftUI

/// 设置窗口：菜单栏「设置…」打开的独立窗口。可缩放、记住尺寸与位置
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: SettingsStore, chatStore: ChatStore, glow: GlowController,
              updates: UpdateChecker, weather: WeatherStore, snippets: SnippetStore) {
        if window == nil {
            let root = SettingsView()
                .environmentObject(settings)
                .environmentObject(chatStore)
                .environmentObject(glow)
                .environmentObject(updates)
                .environmentObject(weather)
                .environmentObject(snippets)
            let hosting = NSHostingController(rootView: root)
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "ProNotch 设置"
            newWindow.titleVisibility = .hidden
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // 透明标题栏，底色由内容视图提供（Claude 桌面端同款暖灰）
            newWindow.titlebarAppearsTransparent = true
            newWindow.appearance = NSAppearance(named: .darkAqua)
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.isMovableByWindowBackground = true
            newWindow.isReleasedWhenClosed = false
            newWindow.contentMinSize = NSSize(width: 660, height: 540)
            newWindow.setContentSize(NSSize(width: 700, height: 620))
            newWindow.center()
            // 有存档则覆盖上面的默认尺寸与位置
            newWindow.setFrameAutosaveName("ProNotchSettingsWindow")
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
