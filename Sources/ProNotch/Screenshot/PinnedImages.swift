import AppKit

/// 贴图钉屏（Snipaste 式）：把截好的选区钉成置顶浮窗，参考资料常驻眼前。
/// 交互：拖动移动 · 滚轮缩放（80pt ~ 3×原尺寸）· 双击或 Esc 关闭 · 右键菜单；支持同时钉多张。
@MainActor
final class PinnedImageController {
    static let shared = PinnedImageController()
    private var panels: [PinPanel] = []

    /// 在全局坐标 frame 处钉住图片（frame = 选区在屏幕上的原位置，实现"原位贴图"）
    func pin(_ image: NSImage, at frame: NSRect) {
        let panel = PinPanel(image: image, frame: frame,
                             onClose: { [weak self] p in self?.panels.removeAll { $0 === p } },
                             onCloseAll: { [weak self] in self?.closeAll() })
        panels.append(panel)
        panel.orderFrontRegardless()
    }

    func closeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

/// 单张贴图窗：无边框置顶、背景拖动、不激活 App（点它不打断当前工作焦点）
private final class PinPanel: NSPanel {
    private let image: NSImage
    private let baseSize: NSSize
    private let onCloseCallback: (PinPanel) -> Void
    private let onCloseAll: () -> Void

    init(image: NSImage, frame: NSRect,
         onClose: @escaping (PinPanel) -> Void, onCloseAll: @escaping () -> Void) {
        self.image = image
        self.baseSize = frame.size
        self.onCloseCallback = onClose
        self.onCloseAll = onCloseAll
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = PinContentView(image: image)
        content.onDoubleClick = { [weak self] in self?.closePin() }
        content.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        content.menuProvider = { [weak self] in self?.buildMenu() }
        contentView = content
    }

    override var canBecomeKey: Bool { true }   // 点选后可接 Esc

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() }  // Esc
        else { super.keyDown(with: event) }
    }

    private func closePin() {
        orderOut(nil)
        onCloseCallback(self)
    }

    /// 以窗口中心为锚点缩放，宽度限制在 80pt ~ 3×原尺寸
    private func zoom(by factor: CGFloat) {
        var f = frame
        let newW = min(max(f.width * factor, 80), baseSize.width * 3)
        guard abs(newW - f.width) > 0.5 else { return }
        let k = newW / f.width
        let newH = f.height * k
        f.origin.x -= (newW - f.width) / 2
        f.origin.y -= (newH - f.height) / 2
        f.size = NSSize(width: newW, height: newH)
        setFrame(f, display: true)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "保存到桌面", action: #selector(saveToDesktop), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭", action: #selector(closeFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllFromMenu), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func saveToDesktop() {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/贴图 \(fmt.string(from: Date())).png")
        try? png.write(to: url)
    }

    @objc private func closeFromMenu() { closePin() }
    @objc private func closeAllFromMenu() { onCloseAll() }
}

/// 贴图内容视图：高质量绘制 + 细描边圆角；承接双击/滚轮/右键
private final class PinContentView: NSView {
    private let image: NSImage
    var onDoubleClick: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        else { super.mouseDown(with: event) }   // 交给窗口背景拖动
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.1 else { return }
        onZoom?(dy > 0 ? 1.08 : 1 / 1.08)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
