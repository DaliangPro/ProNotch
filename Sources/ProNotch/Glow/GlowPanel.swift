import AppKit

/// 覆盖整屏的光晕面板：层级高于菜单栏、所有空间可见、不抢焦点。
/// 关键是 `ignoresMouseEvents = true`——整窗对鼠标完全透明，所有点击 / 滚动 /
/// 拖拽都穿透到下层，纯提醒、绝不干扰用户对屏幕其他内容的操作。
final class GlowPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        // 面板随光晕熄灭被销毁重建（ARC 管理）；防有人误调 close() 触发额外 release
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
