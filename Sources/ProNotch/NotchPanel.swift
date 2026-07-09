import AppKit

/// 无边框悬浮面板：层级高于菜单栏，常驻所有空间，不抢焦点
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 锚定 frame：构造完成后钉死。刘海窗口 frame 在架构上永不改变（展开/收起只动窗口内部内容，
    /// 窗口本身始终等于 windowFrame），故任何把它挪离此 frame 的 setFrame——尤其窗口管理插件
    /// （Rectangle / Magnet / 旺铺等）经 Accessibility(AX) 强改位置或尺寸——一律吸附回锚点。
    /// isMovable=false 只能挡鼠标拖动、挡不住 AX 赋值，这里补上这道兜底。
    private var anchoredFrame: NSRect?

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
        anchoredFrame = frame   // 放最后：构造期间的初始 frame 照常生效，此后位置/尺寸钉死
    }

    // MARK: - 位置钉死（挡窗口管理插件经 AX 的强制挪动）

    /// 锚定后一切外部改动都吸附回锚点；ProNotch 自身构造后从不改 frame，故无需放行任何合法调用
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(anchoredFrame ?? frameRect, display: flag)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(anchoredFrame ?? frameRect, display: flag, animate: anchoredFrame == nil && animate)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(anchoredFrame?.origin ?? point)
    }
    override func setContentSize(_ size: NSSize) {
        if anchoredFrame != nil { return }   // 尺寸也钉死，防"最大化 / 铺满半屏"经 AX 改 size
        super.setContentSize(size)
    }

    // MARK: - 对窗口管理插件隐身

    /// 非标准 subrole：让按 kAXStandardWindow 过滤的窗口管理插件（Rectangle / Magnet / 旺铺等）
    /// 把刘海当系统浮层直接跳过——列表里根本不出现刘海，自然无从选中或摆放。
    /// 仅改窗口这一层的角色，内部搜索框、按钮等子元素的可访问性不受影响
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .floatingWindow }
}
