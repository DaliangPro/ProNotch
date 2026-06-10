import AppKit

/// 无边框悬浮面板：层级高于菜单栏，常驻所有空间，不抢焦点
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        // 只在需要时（点击搜索框）才成为 key window，普通按钮点击不抢键盘
        becomesKeyOnlyIfNeeded = true
        // 面板是纯黑设计，外观锁定深色：系统切浅色时输入框占位符、
        // 光标等控件配色不随之变暗
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}
