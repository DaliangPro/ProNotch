import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import Vision
import CoreImage

/// 覆盖整屏的无边框窗口，承载选区视图
final class ScreenshotOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(image: CGImage, screen: NSScreen,
         translateProvider: @escaping () -> (ScreenshotTranslator.Config, String, String)?,
         onClose: @escaping () -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        animationBehavior = .none   // 去掉 NSWindow 默认淡入：覆盖层瞬间出现，压暗不带过渡动画
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        setFrame(screen.frame, display: true)
        contentView = ScreenshotOverlayView(image: image, screen: screen,
                                            translateProvider: translateProvider, onClose: onClose)
    }
}

/// 框选形状：矩形 / 椭圆
enum BoxShape { case rect, oval }

/// 选区 + 压暗 + 标注（框选 / 备注 / 流程）的绘制与交互视图（AppKit 左下原点）
final class ScreenshotOverlayView: NSView, NSTextViewDelegate {
    private enum Phase { case selecting, editing }
    /// 标注工具：none=可重新框选，box=框选，highlight=高亮（聚光灯），text=输入文字，pen=画笔，
    /// arrow=箭头，mosaic=马赛克，note=备注，flow=流程，watermark=水印
    private enum Tool { case none, box, highlight, text, pen, arrow, mosaic, note, flow, watermark }
    /// 马赛克模式：brush=像笔一样涂抹，box=框选区域
    private enum MosaicMode { case brush, box }
    /// 画笔/马赛克自由笔画
    private struct Stroke { var points: [NSPoint]; var colorHex: String; var lineWidth: CGFloat }
    /// 吸附出的可编辑规整形状（直线/矩形/椭圆）；p0/p1 = 直线两端 或 矩形/椭圆的外接框对角
    private struct Shape {
        enum Kind { case line, rect, ellipse, polyline }
        // 直线/矩形/椭圆用 p0/p1 两点；折线用 points 顶点序列
        var kind: Kind; var p0: NSPoint = .zero; var p1: NSPoint = .zero; var points: [NSPoint] = []; var colorHex: String; var lineWidth: CGFloat
        var rect: NSRect {
            if kind == .polyline {
                let xs = points.map { $0.x }, ys = points.map { $0.y }
                guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
                return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            return NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        }
    }
    /// 箭头：起点 → 终点两点拖出 + 颜色 + 粗细
    private struct Arrow { var start: NSPoint; var end: NSPoint; var colorHex: String; var lineWidth: CGFloat }
    private struct MosaicStroke { var points: [NSPoint]; var lineWidth: CGFloat }
    /// 框选：矩形 + 样式（形状/线型/颜色/粗细/高亮，逐框独立）
    private struct Box {
        var rect: NSRect
        var shape: BoxShape = .rect
        var dashed = false
        var highlight = false
        var colorHex = "#FFFFFF"
        var lineWidth: CGFloat = 2.5
        var rotation: CGFloat = 0   // 绕中心旋转角（弧度），选中后拖旋转手柄调整
        var center: NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
    }
    /// 点绕 c 旋转 angle 弧度
    private static func rotatePoint(_ p: NSPoint, around c: NSPoint, by angle: CGFloat) -> NSPoint {
        let dx = p.x - c.x, dy = p.y - c.y, ca = cos(angle), sa = sin(angle)
        return NSPoint(x: c.x + dx * ca - dy * sa, y: c.y + dx * sa + dy * ca)
    }
    /// 旋转框命中：把点逆旋转回框的本地坐标系再判包含
    private static func boxContains(_ b: Box, _ pt: NSPoint, inset: CGFloat = 0) -> Bool {
        b.rect.insetBy(dx: inset, dy: inset).contains(rotatePoint(pt, around: b.center, by: -b.rotation))
    }
    /// 备注：框 + 引导线 + 文字气泡（框/线可调色）
    private struct Marker { var box: NSRect; var textRect: NSRect; var text: String; var colorHex = "#FFFFFF" }
    /// 流程：序号角标 + 引导线 + 文字气泡（角标/线可调色）
    private struct Step { var center: NSPoint; var number: String; var textRect: NSRect; var text: String; var colorHex = "#FFFFFF" }
    /// 当前正在编辑的目标
    private enum Editing { case markerText(Int), stepText(Int), stepNumber(Int), annoText(Int) }
    /// 纯文字标注：点击处直接输入，落定后按颜色/字号渲染在图上（无框无引导线）
    private struct TextAnno { var rect: NSRect; var text: String; var colorHex: String; var fontSize: CGFloat }
    /// 拖动中的说明气泡引用（回车后可拖动文字框）
    private enum BubbleRef { case marker(Int); case step(Int) }
    private struct PendingBubble { let ref: BubbleRef; let grab: NSPoint; let down: NSPoint; var moved: Bool }
    /// 拖动中的流程角标
    private struct PendingBadge { let index: Int; let grab: NSPoint; let down: NSPoint; var moved: Bool }
    /// 备注框几何调整：移动(记抓取偏移) / 缩放(记对角固定点)
    private enum MarkerGrabMode { case move(NSPoint); case resize(fixed: NSPoint) }
    private struct MarkerGrab { let mode: MarkerGrabMode; var moved: Bool }
    /// 当前选中的标注（单击选中，可 ESC 删除）
    private enum AnnotationRef: Equatable { case box(Int); case marker(Int); case step(Int); case arrow(Int); case text(Int); case shape(Int) }
    /// 撤回快照：所有标注
    private struct Snapshot { let boxes: [Box]; let markers: [Marker]; let steps: [Step]; let pen: [Stroke]; let arrows: [Arrow]; let texts: [TextAnno]; let mosaicS: [MosaicStroke]; let mosaicR: [NSRect]; let shapes: [Shape] }

    private let cgImage: CGImage
    private let nsImage: NSImage
    private let screen: NSScreen
    private let onClose: () -> Void
    private let translateProvider: () -> (ScreenshotTranslator.Config, String, String)?
    private var translatedOverride: NSImage?   // 翻译后盖在选区上的译图（缓存，切换/导出复用）
    private var translatePartial: [String]?    // 渐进翻译累积（空串=该块未回，渲染跳过保留原文）
    private var showingOriginal = false        // 译图在手时，是否临时显示原文
    private var translating = false            // 翻译请求进行中（翻译按钮呈「按下」高亮态）
    private var hintView: NSView?              // 「翻译中…」/错误 提示气泡
    private var hintLabel: NSTextField?        // 气泡内文字（原位更新进度，不重建视图）
    private var hintSpinning = false           // 气泡当前是否带转圈

    private var phase: Phase = .selecting {
        didSet { if phase != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var tool: Tool = .none
    private var selection: NSRect? {
        didSet { if selection != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var dragOrigin: NSPoint?
    // 窗口吸附：框选阶段悬停自动高亮光标下的窗口，单击即整窗选中
    private var snapWindows: [(rect: NSRect, id: CGWindowID)]?   // 吸附候选：截图冻结时刻的普通窗口（边框 + 窗口 ID，视图坐标、Z 序前→后）；nil=未加载
    private var hoverWindowRect: NSRect?    // 光标当前所在窗口的吸附框
    private var hoverWindowID: CGWindowID?  // 光标当前所在窗口的 ID（供单击吸附时记录）
    private var snappedWindowRect: NSRect?  // 单击整窗吸附选中的窗口框——导出时据此裁成窗口真实形状
    private var snappedWindowID: CGWindowID?      // 吸附窗口的 ID
    private var snappedWindowImage: CGImage?      // 该窗口真实形状图（带真圆角 alpha），异步截得；导出时用它精确裁边，曲率与窗口一致

    private var boxes: [Box] = []
    private var boxShape: BoxShape = .rect   // 框选样式：矩形 / 椭圆
    private var boxDashed = false            // 框选样式：实线 / 虚线
    private var boxColorHex = "#FFFFFF"      // 框选样式：颜色（默认白）
    private var boxLineWidth: CGFloat = 2.5  // 框选样式：粗细
    private var hlShape: BoxShape = .rect    // 高亮工具形状：矩形 / 椭圆（高亮是一级工具，画出即聚光灯框）
    private var optionsHost: NSHostingView<AnyView>?   // 工具子选项面板（框选/画笔/马赛克）

    // 画笔
    private var penStrokes: [Stroke] = []
    private var shapes: [Shape] = []                   // 吸附出的可编辑形状（直线/矩形/椭圆）
    private var snappedShape: SnappedShape?            // 当前笔画吸附出的形状：mouseUp 据此决定存 Shape 还是自由笔画
    private var penColorHex = "#FFFFFF"   // 画笔颜色（默认白）
    private var penLineWidth: CGFloat = 4
    // 箭头（起点 → 终点拖出）
    private var arrows: [Arrow] = []
    private var currentArrow: Arrow?         // 正在拖的箭头预览
    private var arrowColorHex = "#FF453A"    // 箭头颜色（默认红，大梁老师定）
    private var arrowLineWidth: CGFloat = 6.5 // 箭头粗细（默认最粗档）
    // 文字标注（点击处直接输入）
    private var texts: [TextAnno] = []
    private var textColorHex = "#FF453A"     // 文字颜色（默认红）
    private var textFontSize: CGFloat = 18   // 文字字号（14/18/24 三档取中）
    // 水印：铺满选区的重复斜排文字；文字现场输入（无默认），为空＝无水印。
    // 属全局显示态而非单笔标注，不进撤销栈——清空文字即移除
    private var wmText = ""
    private var wmColorHex = "#FFFFFF"
    private var wmOpacity: Double = 0.3
    private var wmDensity = 1                // 0 稀 / 1 中 / 2 密
    private var noteColorHex = "#FFFFFF"  // 备注新建颜色（默认白）
    private var flowColorHex = "#FFFFFF"  // 流程新建颜色（默认白）
    // 马赛克
    private var mosaicStrokes: [MosaicStroke] = []
    private var mosaicRects: [NSRect] = []
    private var mosaicMode: MosaicMode = .box   // 默认区域框选
    private var mosaicLineWidth: CGFloat = 22
    private var currentStroke: [NSPoint]?    // 正在画的画笔/马赛克涂抹笔画
    private var hoverPoint: NSPoint?         // 马赛克涂抹时的笔刷光标位置
    // 画笔「停住不松手 → 吸附成直线/圆/折线」
    private var shapeSnapTimer: Timer?
    private var rawStrokeBeforeSnap: [NSPoint]?   // 吸附前的原始轨迹，继续拖动则恢复
    private let shapeSnapDelay: TimeInterval = 0.6
    private lazy var mosaicImage: NSImage = makeMosaicImage()
    private var markers: [Marker] = []
    private var steps: [Step] = []
    private var currentBox: NSRect?
    private var boxOrigin: NSPoint?
    private var editingField: AnnotationTextView?
    private var editing: Editing?
    private var pendingBubble: PendingBubble?   // 回车后拖动说明气泡（拖＝移动，单击＝重新编辑）
    private var pendingBadge: PendingBadge?      // 拖动流程角标（拖＝移动，单击＝编辑文字，双击＝改序号）
    private var activeMarker: Int?              // 双击备注框＝进入几何调整（拖框身移动、拖角缩放，文字保留）
    private var markerGrab: MarkerGrab?
    /// 选中的框选/箭头的拖拽调整：move=整体移动，boxResize=四角缩放(对角固定)，arrowEnd=拖箭头某一端
    /// 选中框选/箭头的拖拽调整：move=整体移动；boxResize=四角缩放（fixed 为本地坐标系对角，
    /// center/angle 记拖拽起始时的旋转中心与角度，全程用它换算避免漂移）；boxRotate=拖旋转手柄；arrowEnd=拖箭头端
    private enum SelGrabMode {
        case move(NSPoint)
        case boxResize(fixed: NSPoint, center: NSPoint, angle: CGFloat)
        case boxRotate(center: NSPoint)
        case arrowEnd(start: Bool)
        case polyVertex(Int)   // 折线：拖第 index 个折角顶点
    }
    private var selGrab: (mode: SelGrabMode, moved: Bool)?
    /// 截图选区自身的边缘调整：拖四角（对角固定）或四条边（单边移动），没截准不用重来
    private enum SelRectMode { case corner(fixed: NSPoint); case left, right, top, bottom }
    private var selRectGrab: SelRectMode?
    private var selected: AnnotationRef? {      // 单击选中的标注，ESC 可删除 / 二次调参
        didSet {
            guard selected != oldValue else { return }
            // 选中态变化且非绘制中 → 刷新参数条：弹出选中组件的可调参数（二次调参），或取消选中后收起
            if currentBox == nil, currentArrow == nil, currentStroke == nil, let bar = toolbarHost {
                updateToolOptions(below: bar.frame)
            }
        }
    }
    private var undoStack: [Snapshot] = []      // 撤回栈（Cmd+Z）

    private var toolbarHost: NSHostingView<ScreenshotToolbar>?
    private var toolbarMoved = false        // 用户拖过工具栏 → 保持手动位置，不再自动跟随选区
    private var toolbarDragBase: NSPoint?   // 本次拖拽起始时的工具栏 origin（位移基准）
    private var ocrPanel: NSHostingView<OCRResultPanel>?

    // 长截图（程序自动匀速滚动 + 逐帧拼接）
    private var recordingLong = false
    private var longActive = false               // 自动滚动循环进行中
    private var longStitcher: LongShotStitcher?
    private var longFilter: SCContentFilter?
    private var longConfig: SCStreamConfiguration?
    private var longCapturePx = CGRect.zero      // 选区像素裁剪框（左上原点）
    private var longTallPx = CGRect.zero         // 选区列「框顶→屏底」的高裁剪框（补尾部用）
    private var longTallUpPx = CGRect.zero       // 选区列「屏顶→框底」的高裁剪框（补头部用）
    private var longWinTopPx: CGFloat = 0        // 目标 App 窗口上边（捕获像素，相对屏顶）——补全延展上界
    private var longWinBottomPx: CGFloat = 0     // 目标 App 窗口下边（捕获像素，相对屏顶）——补全延展下界
    private var longDirPanel: NSPanel?           // 方向选择面板（点长截图后先选向上/向下）
    private var longScanTimer: Timer?            // 扫描取景条动画定时器
    private var longScanPhase: CGFloat = 0       // 扫描条位置（0=框顶 → 1=框底，循环）
    private var longScrolling = false            // 后台连续滚动开关（暂停/到端/补全时关）
    private var longStretchRect: NSRect?         // 补全时选框拉伸到的矩形（向下到视口底 / 向上到视口顶）；nil=不拉伸
    private var longPanel: NSPanel?
    private var longSession: LongShotSession?
    private var longFinished = false             // 录制结束、等用户选输出（复制/存盘/丢弃）
    private var longResultCG: CGImage?
    private var longResultImg: NSImage?
    private var longCaptureRect: NSRect = .zero  // 选区（视图坐标）
    private var scrollWheelFlipped = false       // 滚轮方向补偿（自然滚动/反转工具会翻转合成事件，开滚前实测校准）
    private var longInspectPanel: NSPanel?       // 长图检视面板（双击预览打开，放大确认拼接质量）

    private let badgeRadius: CGFloat = 13
    private let textFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private let numFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private var textAttrs: [NSAttributedString.Key: Any] { [.font: textFont, .foregroundColor: NSColor.white] }

    // 标注统一配色（贴合应用深色调性：低饱和、圆角、细描边、轻投影）
    private static let accent = NSColor.systemCyan                                           // 主色：应用青（与设置激活态一致）
    private static let bubbleBG = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 0.92)  // 气泡/标签底：近黑深灰
    private static let bubbleStroke = NSColor.white.withAlphaComponent(0.14)                 // 气泡细描边

    private let bubbleMaxWidth: CGFloat = 220   // 说明文字超过此宽度自动换行
    private let bubblePadX: CGFloat = 10
    private let bubblePadY: CGFloat = 7
    /// 气泡文字属性：白字 + 左对齐（文字从左往右排）；整段靠等高文字区在框内垂直居中
    private var bubbleAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.alignment = .left; p.lineBreakMode = .byWordWrapping
        return [.font: textFont, .foregroundColor: NSColor.white, .paragraphStyle: p]
    }
    /// 按文字内容算气泡尺寸：宽度自适应（短文字贴合、超 maxWidth 换行），高度按行数；
    /// 空文字按占位符宽度，保证刚出现时占位符能完整显示
    private func bubbleSize(_ text: String, maxWidth: CGFloat) -> NSSize {
        let t = text.isEmpty ? "输入说明…" : text
        let textMax = maxWidth - bubblePadX * 2   // 文字区最大宽（换行点），与输入框文字容器宽度一致
        let bound = (t as NSString).boundingRect(
            with: NSSize(width: textMax, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: bubbleAttrs)
        return NSSize(width: ceil(bound.width) + bubblePadX * 2,
                      height: ceil(bound.height) + bubblePadY * 2)
    }

    /// 输入框按文字实际排版尺寸收紧：底框严丝合缝贴住文字，不留多余空白
    private func fittedSize(_ tv: AnnotationTextView) -> NSSize {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return tv.frame.size }
        lm.ensureLayout(for: tc)
        // 用字形实际包围盒，而非 usedRect——后者含末尾光标的「额外行片段」(整条容器宽)，会把框撑宽留白
        let used = lm.boundingRect(forGlyphRange: lm.glyphRange(for: tc), in: tc)
        let inset = tv.textContainerInset
        return NSSize(width: ceil(used.width) + inset.width * 2,
                      height: ceil(used.height) + inset.height * 2)
    }

    init(image: CGImage, screen: NSScreen,
         translateProvider: @escaping () -> (ScreenshotTranslator.Config, String, String)?,
         onClose: @escaping () -> Void) {
        self.cgImage = image
        self.screen = screen
        self.nsImage = NSImage(cgImage: image, size: screen.frame.size)
        self.translateProvider = translateProvider
        self.onClose = onClose
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    /// 光标反馈：默认十字准星；编辑态在选区四边/四角覆盖对应的调整光标——
    /// 只画手柄用户看不出「能拖」，鼠标一靠近就变形才有感知。命中带宽与 selectionGrabMode 一致（±7pt）
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard phase == .editing, let sel = selection else { return }
        let t: CGFloat = 7
        if sel.height > 2 * t {   // 左右边：去掉两端 t，让角优先
            addCursorRect(NSRect(x: sel.minX - t, y: sel.minY + t, width: 2 * t, height: sel.height - 2 * t),
                          cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: sel.maxX - t, y: sel.minY + t, width: 2 * t, height: sel.height - 2 * t),
                          cursor: .resizeLeftRight)
        }
        if sel.width > 2 * t {    // 上下边
            addCursorRect(NSRect(x: sel.minX + t, y: sel.maxY - t, width: sel.width - 2 * t, height: 2 * t),
                          cursor: .resizeUpDown)
            addCursorRect(NSRect(x: sel.minX + t, y: sel.minY - t, width: sel.width - 2 * t, height: 2 * t),
                          cursor: .resizeUpDown)
        }
        // 四角（非翻转坐标系：minY 是底边）
        let nwse = Self.diagonalResizeCursor(nwse: true)
        let nesw = Self.diagonalResizeCursor(nwse: false)
        func cornerRect(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - t, y: y - t, width: 2 * t, height: 2 * t)
        }
        addCursorRect(cornerRect(sel.minX, sel.minY), cursor: nesw)   // 左下 ↙↗
        addCursorRect(cornerRect(sel.maxX, sel.maxY), cursor: nesw)   // 右上
        addCursorRect(cornerRect(sel.minX, sel.maxY), cursor: nwse)   // 左上 ↖↘
        addCursorRect(cornerRect(sel.maxX, sel.minY), cursor: nwse)   // 右下
    }

    /// 对角调整光标：系统到 macOS 15 才开放 NSCursor.frameResize，本项目部署到 14，
    /// 故走私有 selector；取不到就回退成上下调整光标（仍有「可拖」反馈，不影响功能）
    private static func diagonalResizeCursor(nwse: Bool) -> NSCursor {
        let name = nwse ? "_windowResizeNorthWestSouthEastCursor"
                        : "_windowResizeNorthEastSouthWestCursor"
        let sel = NSSelectorFromString(name)
        if NSCursor.responds(to: sel),
           let cursor = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .resizeUpDown
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        // 框选阶段（未开始拖拽）：悬停吸附光标下的窗口，单击即整窗选中；一旦拖拽走自由框选
        if phase == .selecting, dragOrigin == nil, !recordingLong, !longFinished, ocrPanel == nil, hintView == nil {
            let pt = convert(event.locationInWindow, from: nil)
            let hit = snapWindowHit(under: pt)
            if hit?.rect != hoverWindowRect {
                hoverWindowRect = hit?.rect
                hoverWindowID = hit?.id
                needsDisplay = true
            }
            return
        }
        guard tool == .mosaic, mosaicMode == .brush else { if hoverPoint != nil { hoverPoint = nil; needsDisplay = true }; return }
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    // MARK: - 窗口吸附

    /// 光标下最顶层可见窗口的吸附框（视图坐标）；候选列表只取一次——覆盖层显示后画面已冻结，窗口不会再动
    private func snapWindowHit(under pt: NSPoint) -> (rect: NSRect, id: CGWindowID)? {
        if snapWindows == nil {
            snapWindows = Self.loadSnapWindows(screen: screen, bounds: bounds,
                                               excludeNumbers: Set([window?.windowNumber].compactMap { $0 }))
        }
        return snapWindows?.first { $0.rect.contains(pt) }
    }

    /// 枚举屏上可见窗口 → 视图坐标（Z 序前→后）。不限 layer 0：刘海面板、各 App 浮动面板都能吸附；
    /// 只排除截图覆盖层自身、桌面层（负 layer）、全屏遮罩层（高 layer 且盖满整屏，如光晕层）与过小窗口。
    private static func loadSnapWindows(screen: NSScreen, bounds: NSRect, excludeNumbers: Set<Int>) -> [(rect: NSRect, id: CGWindowID)] {
        guard let displayID = screen.displayID,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let b = CGDisplayBounds(displayID)   // 本屏 CG 全局框（左上原点）
        var out: [(rect: NSRect, id: CGWindowID)] = []
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let num = info[kCGWindowNumber as String] as? Int, !excludeNumbers.contains(num),
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let wf = CGRect(dictionaryRepresentation: bd), wf.width >= 40, wf.height >= 40 else { continue }
            // CG 全局（左上原点、y 向下） → 本屏视图坐标（左下原点、y 向上）
            let r = NSRect(x: wf.minX - b.minX, y: bounds.height - (wf.maxY - b.minY),
                           width: wf.width, height: wf.height).intersection(bounds)
            guard r.width >= 40, r.height >= 40 else { continue }
            // 高 layer 且盖满整屏 = 遮罩层（光晕/覆盖层同类），不是可截的窗口；layer 0 的全屏 App 窗口保留
            if layer > 0, r.width >= bounds.width * 0.95, r.height >= bounds.height * 0.95 { continue }
            out.append((r, CGWindowID(num)))
        }
        return out
    }

    /// 异步按窗口 ID 单独截该窗口，得到带真实圆角 alpha 的形状图（不含阴影），供 compose 精确裁边。
    /// 用窗口自己的真实形状，曲率与该窗口完全一致，避免固定圆角在不同软件上留背景/切边
    private func captureWindowShape(id: CGWindowID) {
        let scale = screen.backingScaleFactor
        Task { [weak self] in
            let img = await Self.captureWindow(id: id, scale: scale)
            await MainActor.run { self?.snappedWindowImage = img }
        }
    }

    private static func captureWindow(id: CGWindowID, scale: CGFloat) async -> CGImage? {
        guard let content = try? await SCShareableContent.current,
              let win = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(win.frame.width * scale))
        cfg.height = max(1, Int(win.frame.height * scale))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true    // 只要窗口本体形状，不含系统阴影（背景默认即 clear 透明）
        let filter = SCContentFilter(desktopIndependentWindow: win)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        if longFinished {   // 出图选择态：整屏压暗，输出条浮在上面
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(rect: bounds).fill()
            return
        }
        if recordingLong {   // 录制态：压暗四周，抓取列挖成透明洞透出实时内容（捕获另走 SCK、排除本窗口）
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(rect: bounds).fill()
            let col = longStretchRect ?? longCaptureRect   // 补全时选框拉伸到视口端
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: col).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // 扫描取景条：随动画自上而下扫过框内，传达"正在往下截取"（视觉上跟着截图走）
            let bandH = max(28, min(70, col.height * 0.16))
            let cy = col.maxY - longScanPhase * col.height          // 中心线从框顶扫到框底（左下原点）
            let bandRect = NSRect(x: col.minX, y: cy - bandH / 2, width: col.width, height: bandH).intersection(col)
            if !bandRect.isEmpty,
               let g = NSGradient(colors: [.clear, NSColor.systemRed.withAlphaComponent(0.32), .clear]) {
                g.draw(in: bandRect, angle: 90)                      // 垂直渐变：中间亮、两头透
            }
            if cy >= col.minY, cy <= col.maxY {
                NSColor.white.withAlphaComponent(0.85).setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: col.minX, y: cy)); line.line(to: NSPoint(x: col.maxX, y: cy))
                line.lineWidth = 1.5; line.stroke()
            }
            NSColor.systemRed.withAlphaComponent(0.95).setStroke()
            let b = NSBezierPath(rect: col); b.lineWidth = 2; b.stroke()
            return
        }
        nsImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.5).setFill()

        guard let sel = selection, max(sel.width, sel.height) >= 4 else {
            // 无选区（或刚按下还没拖开）：有吸附窗口就亮出它 + 描边，否则整屏压暗
            if phase == .selecting, let hw = hoverWindowRect {
                let mask = NSBezierPath(rect: bounds)
                mask.append(NSBezierPath(rect: hw))
                mask.windingRule = .evenOdd
                mask.fill()
                withShadow(blur: 6, alpha: 0.4) {
                    Self.accent.setStroke()
                    let p = NSBezierPath(rect: hw); p.lineWidth = 2.5; p.stroke()
                }
                drawSizeLabel(for: hw)
            } else {
                NSBezierPath(rect: bounds).fill()
            }
            return
        }
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(rect: sel))
        mask.windingRule = .evenOdd
        mask.fill()
        if let t = translatedOverride, !showingOriginal { t.draw(in: sel) }   // 译图盖住选区（除非临时看原文）

        drawMosaics(dx: 0, dy: 0)   // 马赛克：盖在原图上、压在标注下

        // 聚光灯：仅「高亮」框（含正在拖的高亮框）作亮窗，选区内其余压暗；没有高亮框就不压暗
        var spots: [(rect: NSRect, shape: BoxShape, rotation: CGFloat)] = boxes.filter { $0.highlight }.map { ($0.rect, $0.shape, $0.rotation) }
        if tool == .highlight, let c = currentBox { spots.append((c, hlShape, 0)) }   // 高亮工具拖拽预览
        if !spots.isEmpty { drawSpotlight(spots, in: sel) }

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: sel); border.lineWidth = 1; border.stroke()
        if phase == .editing { drawSelectionEdgeHandles(sel) }   // 选区可调提示：四角+四边中点手柄

        for b in boxes where !b.highlight { drawBoxStyled(b) }   // 非高亮框按各自样式画
        for (i, m) in markers.enumerated() { drawMarker(m, editing: isEditing(.markerText(i)), active: i == activeMarker) }
        for (i, s) in steps.enumerated() {
            drawStep(s, editingNumber: isEditing(.stepNumber(i)), editingText: isEditing(.stepText(i)))
        }
        drawPenStrokes(dx: 0, dy: 0)   // 画笔：盖在最上层
        drawArrows(dx: 0, dy: 0)       // 箭头：与画笔同层
        drawTexts(dx: 0, dy: 0)        // 文字标注：与画笔同层
        drawWatermark(in: sel, dx: 0, dy: 0)   // 水印：铺在所有标注之上
        if let sel = selected {
            if editingField == nil, activeMarker == nil { drawSelection(sel) }   // 空闲选中＝虚线高亮
            drawDeleteButton(sel)                                                 // 选中即显示删除按钮(×)，点它删整个组件
        }
        if let c = currentBox {
            if tool == .box { drawBoxStyled(currentStyleBox(c)) }   // 框选预览（高亮工具预览走聚光灯）
            else if tool == .note { strokeBox(c, color: NSColor(Color(hex: noteColorHex))) }   // 备注框预览（当前色）
        }
        drawMosaicHints()   // 马赛克范围提示（框/轮廓/笔刷光标）
        drawSizeLabel(for: sel)
    }

    private func isEditing(_ e: Editing) -> Bool {
        switch (editing, e) {
        case (.markerText(let a), .markerText(let b)): return a == b
        case (.stepText(let a), .stepText(let b)): return a == b
        case (.stepNumber(let a), .stepNumber(let b)): return a == b
        case (.annoText(let a), .annoText(let b)): return a == b
        default: return false
        }
    }

    /// 给一段绘制加统一的轻投影，让标注从任意截图背景上「浮起」而不刺眼
    private func withShadow(blur: CGFloat = 5, alpha: CGFloat = 0.35, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(alpha)
        s.shadowBlurRadius = blur
        s.shadowOffset = NSSize(width: 0, height: -1)
        s.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 精致圆角强调框（珊瑚红 + 圆角 + 轻投影），框选与备注共用
    private func strokeBox(_ rect: NSRect, color: NSColor? = nil) {
        withShadow(blur: 4, alpha: 0.3) {
            (color ?? Self.accent).setStroke()
            let p = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6); p.lineWidth = 2; p.stroke()
        }
    }

    /// 用当前框选样式包一个 Box（新框 / 预览用）
    private func currentStyleBox(_ rect: NSRect) -> Box {
        Box(rect: rect, shape: boxShape, dashed: boxDashed, highlight: false, colorHex: boxColorHex, lineWidth: boxLineWidth)
    }

    /// 按框各自样式画：矩形/椭圆、实线/虚线、颜色、粗细、旋转
    private func drawBoxStyled(_ box: Box) {
        let path = box.shape == .oval
            ? NSBezierPath(ovalIn: box.rect)
            : NSBezierPath(roundedRect: box.rect, xRadius: 6, yRadius: 6)
        if box.rotation != 0 { path.transform(using: Self.rotationTransform(box.rotation, around: box.center)) }
        path.lineWidth = box.lineWidth
        if box.dashed { path.setLineDash([box.lineWidth * 2.6, box.lineWidth * 2.3], count: 2, phase: 0) }
        withShadow(blur: 4, alpha: 0.28) {
            NSColor(Color(hex: box.colorHex)).setStroke()
            path.stroke()
        }
    }

    /// 绕 c 旋转 angle 的仿射变换（NSBezierPath 用）
    private static func rotationTransform(_ angle: CGFloat, around c: NSPoint) -> AffineTransform {
        var t = AffineTransform(translationByX: c.x, byY: c.y)
        t.rotate(byRadians: angle)
        t.translate(x: -c.x, y: -c.y)
        return t
    }

    private func drawMarker(_ m: Marker, editing: Bool, active: Bool = false) {
        let c = NSColor(Color(hex: m.colorHex))
        strokeBox(m.box, color: c)
        if active { drawHandles(m.box) }   // 几何调整态：四角手柄
        let anchor = NSPoint(x: m.box.maxX, y: m.box.minY)
        if editing, let f = editingField {
            leader(from: anchor, to: NSPoint(x: f.frame.minX, y: f.frame.maxY), color: c)   // 编辑时引导线跟随输入框
        } else if !m.text.isEmpty {
            leader(from: anchor, to: NSPoint(x: m.textRect.minX, y: m.textRect.maxY), color: c)
            drawTextBubble(m.text, in: m.textRect)
        }
    }

    /// 几何调整态的四角手柄（白底 + 主色描边）
    private func drawHandles(_ box: NSRect) {
        let s: CGFloat = 7
        for p in [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                  NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)] {
            let r = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            Self.accent.setStroke()
            let bp = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5); bp.lineWidth = 1.5; bp.stroke()
        }
    }

    /// 选中标注的高亮指示（白色虚线外框/外环）；按 ESC 删除
    private func drawSelection(_ ref: AnnotationRef) {
        NSColor.white.withAlphaComponent(0.95).setStroke()
        func ring(_ rect: NSRect) {
            let p = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8)
            p.lineWidth = 1.5; p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
        }
        switch ref {
        case .box(let i):    if boxes.indices.contains(i) { drawBoxSelectionChrome(boxes[i]) }
        case .marker(let i): if markers.indices.contains(i) { ring(markers[i].box) }
        case .text(let i):   if texts.indices.contains(i) { ring(texts[i].rect) }
        case .arrow(let i):  if arrows.indices.contains(i) {
            let a = arrows[i]
            for p in [a.start, a.end] {   // 两端圆手柄：可拖动调整箭头起点/终点
                let r = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
                Self.accent.setStroke(); let bp = NSBezierPath(ovalIn: r); bp.lineWidth = 1.5; bp.stroke()
            }
        }
        case .step(let i):   if steps.indices.contains(i) {
            let c = steps[i].center, rr = badgeRadius + 4
            let p = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            p.lineWidth = 1.5; p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
        }
        case .shape(let i):  if shapes.indices.contains(i) { drawShapeSelectionChrome(shapes[i]) }
        }
    }

    /// 选中形状的调整手柄：直线=两端圆钮；矩形/椭圆=虚线环 + 四角方块（无旋转）
    private func drawShapeSelectionChrome(_ s: Shape) {
        if s.kind == .line || s.kind == .polyline {   // 直线画两端，折线画每个折角
            for p in (s.kind == .line ? [s.p0, s.p1] : s.points) {
                let r = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
                Self.accent.setStroke(); let bp = NSBezierPath(ovalIn: r); bp.lineWidth = 1.5; bp.stroke()
            }
        } else {
            let rect = s.rect
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8)
            ring.lineWidth = 1.5; ring.setLineDash([4, 3], count: 2, phase: 0); ring.stroke()
            let sz: CGFloat = 7
            for corner in [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                           NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)] {
                let r = NSRect(x: corner.x - sz / 2, y: corner.y - sz / 2, width: sz, height: sz)
                NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
                Self.accent.setStroke(); let bp = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5); bp.lineWidth = 1.5; bp.stroke()
            }
        }
    }

    /// 选中框选的整套调整手柄：旋转的虚线环 + 四角缩放手柄 + 顶部旋转手柄（全部跟随框的旋转角）
    private func drawBoxSelectionChrome(_ b: Box) {
        let t = Self.rotationTransform(b.rotation, around: b.center)
        // 虚线环（随框旋转）
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let ringPath = NSBezierPath(roundedRect: b.rect.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8)
        if b.rotation != 0 { ringPath.transform(using: t) }
        ringPath.lineWidth = 1.5; ringPath.setLineDash([4, 3], count: 2, phase: 0); ringPath.stroke()
        // 四角缩放手柄（白底方块 + 主色描边，位置随旋转）
        let s: CGFloat = 7
        for corner in [NSPoint(x: b.rect.minX, y: b.rect.minY), NSPoint(x: b.rect.maxX, y: b.rect.minY),
                       NSPoint(x: b.rect.minX, y: b.rect.maxY), NSPoint(x: b.rect.maxX, y: b.rect.maxY)] {
            let p = Self.rotatePoint(corner, around: b.center, by: b.rotation)
            let r = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            Self.accent.setStroke()
            let bp = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5); bp.lineWidth = 1.5; bp.stroke()
        }
        // 旋转手柄：顶边中点向外伸的连线 + 圆钮
        let topMid = Self.rotatePoint(NSPoint(x: b.rect.midX, y: b.rect.maxY), around: b.center, by: b.rotation)
        let knob = Self.boxRotateHandle(b)
        Self.accent.withAlphaComponent(0.85).setStroke()
        let line = NSBezierPath(); line.move(to: topMid); line.line(to: knob); line.lineWidth = 1.2; line.stroke()
        let kr = NSRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10)
        NSColor.white.setFill(); NSBezierPath(ovalIn: kr).fill()
        Self.accent.setStroke(); let kp = NSBezierPath(ovalIn: kr); kp.lineWidth = 1.5; kp.stroke()
    }

    /// 旋转手柄圆钮位置：未旋转坐标系顶边中点上方 18pt，再随框旋转
    private static func boxRotateHandle(_ b: Box) -> NSPoint {
        rotatePoint(NSPoint(x: b.rect.midX, y: b.rect.maxY + 18), around: b.center, by: b.rotation)
    }

    /// 选中组件右上角的删除按钮(×)矩形；命中它＝删除整个组件
    private func deleteButtonRect(_ ref: AnnotationRef) -> NSRect {
        let s: CGFloat = 19
        var corner = NSPoint.zero
        switch ref {
        case .box(let i):    guard boxes.indices.contains(i) else { return .zero }
            corner = Self.rotatePoint(NSPoint(x: boxes[i].rect.maxX, y: boxes[i].rect.maxY),
                                      around: boxes[i].center, by: boxes[i].rotation)   // 右上角随旋转走
        case .marker(let i): guard markers.indices.contains(i) else { return .zero }; corner = NSPoint(x: markers[i].box.maxX, y: markers[i].box.maxY)
        case .step(let i):   guard steps.indices.contains(i) else { return .zero }; corner = NSPoint(x: steps[i].center.x + badgeRadius, y: steps[i].center.y + badgeRadius)
        case .arrow(let i):  guard arrows.indices.contains(i) else { return .zero }; corner = arrows[i].end   // 删除按钮放箭尖
        case .text(let i):   guard texts.indices.contains(i) else { return .zero }; corner = NSPoint(x: texts[i].rect.maxX, y: texts[i].rect.maxY)
        case .shape(let i):  guard shapes.indices.contains(i) else { return .zero }
            let sh = shapes[i]
            // 删除按钮放"某段中点 + 法向偏移"：随形状平滑移动不跳，又避开两端/顶点手柄
            switch sh.kind {
            case .line: corner = Self.midEdgeOffset(sh.p0, sh.p1)
            case .polyline where sh.points.count >= 2: corner = Self.midEdgeOffset(sh.points[0], sh.points[1])
            default: corner = NSPoint(x: sh.rect.maxX, y: sh.rect.maxY)
            }
        }
        return NSRect(x: corner.x - s / 2, y: corner.y - s / 2, width: s, height: s)
    }

    /// 删除按钮定位：线段中点沿法向偏移一段，避开端点/顶点手柄，又随形状平滑移动不跳
    private static func midEdgeOffset(_ a: NSPoint, _ b: NSPoint) -> NSPoint {
        let mid = NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let off: CGFloat = 22
        return NSPoint(x: mid.x - dy / len * off, y: mid.y + dx / len * off)
    }

    /// 画删除按钮：深灰底 + 细白边 + 白 ×（与气泡/工具栏同调性）
    private func drawDeleteButton(_ ref: AnnotationRef) {
        let r = deleteButtonRect(ref)
        guard r.width > 0 else { return }
        withShadow(blur: 4, alpha: 0.35) {
            Self.bubbleBG.setFill()
            NSBezierPath(ovalIn: r).fill()
        }
        Self.bubbleStroke.setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)); ring.lineWidth = 1; ring.stroke()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let inset: CGFloat = 6, p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + inset, y: r.minY + inset)); p.line(to: NSPoint(x: r.maxX - inset, y: r.maxY - inset))
        p.move(to: NSPoint(x: r.minX + inset, y: r.maxY - inset)); p.line(to: NSPoint(x: r.maxX - inset, y: r.minY + inset))
        p.lineWidth = 1.6; p.lineCapStyle = .round; p.stroke()
    }

    private func drawStep(_ s: Step, editingNumber: Bool, editingText: Bool) {
        let r = badgeRadius
        let circle = NSRect(x: s.center.x - r, y: s.center.y - r, width: r * 2, height: r * 2)
        let c = NSColor(Color(hex: s.colorHex))
        let numColor: NSColor = c.luma > 0.62 ? .black : .white   // 角标亮→黑字、暗→白字，保证序号可见
        let hasText = !s.text.isEmpty
        // 引导线从圆心出发、先画，被圆盖住根部 → 视觉上从角标中心往外延伸
        if editingText, let f = editingField {
            leader(from: s.center, to: NSPoint(x: f.frame.minX, y: f.frame.minY), color: c)
        } else if hasText {
            leader(from: s.center, to: NSPoint(x: s.textRect.minX, y: s.textRect.minY), color: c)
        }
        withShadow(blur: 4, alpha: 0.35) {
            c.setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        (numColor == .black ? NSColor.black : NSColor.white).withAlphaComponent(0.85).setStroke()   // 细边圈随字色，更立体
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5; ring.stroke()
        if !editingNumber {
            let attrs: [NSAttributedString.Key: Any] = [.font: numFont, .foregroundColor: numColor]
            let sz = (s.number as NSString).size(withAttributes: attrs)
            (s.number as NSString).draw(at: NSPoint(x: s.center.x - sz.width / 2, y: s.center.y - sz.height / 2), withAttributes: attrs)
        }
        if !editingText, hasText { drawTextBubble(s.text, in: s.textRect) }
    }

    private func leader(from a: NSPoint, to b: NSPoint, color: NSColor? = nil) {
        withShadow(blur: 4, alpha: 0.3) {   // 与选框一致：2 粗 + 同样的轻投影
            (color ?? Self.accent).setStroke()
            let line = NSBezierPath(); line.move(to: a); line.line(to: b)
            line.lineWidth = 2; line.lineCapStyle = .round; line.stroke()
        }
    }

    private func drawTextBubble(_ text: String, in rect: NSRect) {
        withShadow(blur: 6, alpha: 0.4) {
            Self.bubbleBG.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        Self.bubbleStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8); border.lineWidth = 1; border.stroke()
        // 文字区＝气泡去内边距，高度恰等于文字高 → 文字左对齐排布 + 整段在框内垂直居中
        (text as NSString).draw(in: rect.insetBy(dx: bubblePadX, dy: bubblePadY), withAttributes: bubbleAttrs)
    }

    private func drawSizeLabel(for sel: NSRect) {
        let scale = screen.backingScaleFactor
        let text = "\(Int(sel.width * scale)) × \(Int(sel.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = NSPoint(x: sel.minX, y: sel.maxY + 6)
        if origin.y + size.height + 8 > bounds.height { origin.y = sel.maxY - size.height - 10 }
        let padX: CGFloat = 8, padY: CGFloat = 4
        let bg = NSRect(x: origin.x, y: origin.y, width: size.width + padX * 2, height: size.height + padY * 2)
        withShadow(blur: 5, alpha: 0.35) {
            Self.bubbleBG.setFill()
            NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        }
        (text as NSString).draw(at: NSPoint(x: origin.x + padX, y: origin.y + padY), withAttributes: attrs)
    }

    /// 聚光灯：在选区内离屏铺一层暗，再把每个高亮框从暗层里挖空（destinationOut）透出原图。
    /// 重叠区只挖不补，不会像 even-odd 那样被反选回暗色。
    private func drawSpotlight(_ spots: [(rect: NSRect, shape: BoxShape, rotation: CGFloat)], in sel: NSRect) {
        guard !spots.isEmpty, sel.width > 0, sel.height > 0 else { return }
        let layer = NSImage(size: sel.size)
        layer.lockFocus()
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: sel.size)).fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut   // 把框内暗色擦透明
        NSColor.black.setFill()
        for s in spots {
            let r = s.rect.offsetBy(dx: -sel.minX, dy: -sel.minY)
            let path = s.shape == .oval ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
            if s.rotation != 0 {   // 挖洞随框旋转
                path.transform(using: Self.rotationTransform(s.rotation, around: NSPoint(x: r.midX, y: r.midY)))
            }
            path.fill()
        }
        layer.unlockFocus()
        layer.draw(in: sel)   // 叠到主上下文：框外半透明黑(暗)、框内透明(露原图)
    }

    /// 生成整屏的毛玻璃模糊版（高斯模糊）；按需求路径裁剪显示，替代早期的像素块马赛克
    private func makeMosaicImage() -> NSImage {
        guard let tiff = nsImage.tiffRepresentation, let ci = CIImage(data: tiff) else { return nsImage }
        // clampedToExtent：边缘像素外延，避免模糊后四周出现半透明黑边；模糊完裁回原尺寸
        let blurred = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
            .cropped(to: ci.extent)
        let ctx = CIContext(options: nil)
        guard let cg = ctx.createCGImage(blurred, from: ci.extent) else { return nsImage }
        return NSImage(cgImage: cg, size: bounds.size)
    }

    /// 把自由笔画转成「描粗后的填充区域」CGPath（单点＝小圆点）
    private func strokeCGPath(_ points: [NSPoint], width: CGFloat, dx: CGFloat, dy: CGFloat) -> CGPath {
        let pts = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        if pts.count == 1 { let r = width / 2; return CGPath(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: width, height: width), transform: nil) }
        let p = CGMutablePath(); p.addLines(between: pts)
        return p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// 马赛克：区域矩形 + 涂抹笔画（含正在涂的预览），用路径裁剪显示马赛克图
    private func drawMosaics(dx: CGFloat, dy: CGFloat) {
        let drawingNew = tool == .mosaic
        guard !mosaicRects.isEmpty || !mosaicStrokes.isEmpty || drawingNew else { return }
        let imgRect = NSRect(x: dx, y: dy, width: bounds.width, height: bounds.height)
        func clipDraw(_ path: CGPath) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(cgPath: path).addClip()   // AppKit 裁剪，结束后干净恢复，不影响后续绘制
            mosaicImage.draw(in: imgRect)
            NSGraphicsContext.restoreGraphicsState()
        }
        for r in mosaicRects { clipDraw(CGPath(rect: r.offsetBy(dx: dx, dy: dy), transform: nil)) }
        for ms in mosaicStrokes { clipDraw(strokeCGPath(ms.points, width: ms.lineWidth, dx: dx, dy: dy)) }
        if drawingNew, mosaicMode == .box, let c = currentBox { clipDraw(CGPath(rect: c.offsetBy(dx: dx, dy: dy), transform: nil)) }
        if drawingNew, mosaicMode == .brush, let pts = currentStroke { clipDraw(strokeCGPath(pts, width: mosaicLineWidth, dx: dx, dy: dy)) }
    }

    /// 马赛克范围提示（仅编辑界面，不导出）：区域虚线框 / 涂抹轮廓 / 笔刷光标圆
    /// 黑白双色虚线（蚂蚁线）：黑、白各画一遍并错位，任何背景下都可见
    private func dashedStroke(_ path: NSBezierPath, width: CGFloat = 1.2) {
        let dash: [CGFloat] = [5, 4]
        path.lineWidth = width
        NSColor.black.withAlphaComponent(0.55).setStroke(); path.setLineDash(dash, count: 2, phase: 0); path.stroke()
        NSColor.white.setStroke(); path.setLineDash(dash, count: 2, phase: dash[0]); path.stroke()
    }

    private func drawMosaicHints() {
        guard tool == .mosaic else { return }
        for r in mosaicRects { dashedStroke(NSBezierPath(rect: r), width: 1) }   // 已完成区域：编辑界面显示边框（不导出）
        if mosaicMode == .box {
            if let c = currentBox { dashedStroke(NSBezierPath(rect: c), width: 1.4) }
        } else {
            if let pts = currentStroke {
                dashedStroke(NSBezierPath(cgPath: strokeCGPath(pts, width: mosaicLineWidth, dx: 0, dy: 0)), width: 1)
            } else if let h = hoverPoint, (selection ?? .zero).contains(h) {
                let r = mosaicLineWidth / 2
                dashedStroke(NSBezierPath(ovalIn: NSRect(x: h.x - r, y: h.y - r, width: mosaicLineWidth, height: mosaicLineWidth)), width: 1)
            }
        }
    }

    /// 画笔：已有笔画 + 正在画的预览
    private func drawPenStrokes(dx: CGFloat, dy: CGFloat) {
        for s in shapes { strokeShape(s, dx: dx, dy: dy) }   // 吸附出的可编辑形状
        for ps in penStrokes { strokePen(ps.points, color: ps.colorHex, width: ps.lineWidth, dx: dx, dy: dy) }
        if tool == .pen, let pts = currentStroke { strokePen(pts, color: penColorHex, width: penLineWidth, dx: dx, dy: dy) }
    }

    private func strokeShape(_ s: Shape, dx: CGFloat, dy: CGFloat) {
        NSColor(Color(hex: s.colorHex)).setStroke()
        let path = NSBezierPath()
        path.lineWidth = s.lineWidth
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch s.kind {
        case .line:
            path.move(to: NSPoint(x: s.p0.x + dx, y: s.p0.y + dy))
            path.line(to: NSPoint(x: s.p1.x + dx, y: s.p1.y + dy))
        case .rect: path.appendRect(s.rect.offsetBy(dx: dx, dy: dy))
        case .ellipse: path.appendOval(in: s.rect.offsetBy(dx: dx, dy: dy))
        case .polyline:
            guard let f = s.points.first else { break }
            path.move(to: NSPoint(x: f.x + dx, y: f.y + dy))
            for p in s.points.dropFirst() { path.line(to: NSPoint(x: p.x + dx, y: p.y + dy)) }
        }
        path.stroke()
    }

    // MARK: - 画笔停顿吸附成形状

    /// 把点夹在选区内：画笔/吸附形状不画出截图选区范围
    private func clampToSel(_ pt: NSPoint) -> NSPoint {
        guard let sel = selection else { return pt }
        return NSPoint(x: min(max(pt.x, sel.minX), sel.maxX), y: min(max(pt.y, sel.minY), sel.maxY))
    }

    /// 每次移动重置计时；停住 shapeSnapDelay 秒不动后，识别当前笔画并规整成形状
    private func scheduleShapeSnap() {
        shapeSnapTimer?.invalidate()
        guard tool == .pen else { return }   // 只画笔吸附，马赛克涂抹不参与
        shapeSnapTimer = Timer.scheduledTimer(withTimeInterval: shapeSnapDelay, repeats: false) { [weak self] _ in
            self?.applyShapeSnap()
        }
    }

    /// 停顿触发：认出直线/圆/折线就用规整点替换，原始轨迹留底供继续拖动时恢复
    private func applyShapeSnap() {
        guard tool == .pen, rawStrokeBeforeSnap == nil,
              let pts = currentStroke, let shape = ShapeSnap.recognize(pts) else { return }
        rawStrokeBeforeSnap = pts
        snappedShape = shape
        currentStroke = shape.points
        needsDisplay = true
    }

    private func cancelShapeSnap() {
        shapeSnapTimer?.invalidate(); shapeSnapTimer = nil
        rawStrokeBeforeSnap = nil; snappedShape = nil
    }
    private func strokePen(_ points: [NSPoint], color: String, width: CGFloat, dx: CGFloat, dy: CGFloat) {
        let c = NSColor(Color(hex: color))
        if points.count == 1 { let r = width / 2, pt = points[0]; c.setFill(); NSBezierPath(ovalIn: NSRect(x: pt.x + dx - r, y: pt.y + dy - r, width: width, height: width)).fill(); return }
        c.setStroke()
        let path = NSBezierPath(); path.move(to: NSPoint(x: points[0].x + dx, y: points[0].y + dy))
        for p in points.dropFirst() { path.line(to: NSPoint(x: p.x + dx, y: p.y + dy)) }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    }

    /// 文字标注：按各自颜色/字号渲染 + 轻阴影（屏上与导出共用，dx/dy 平移）。
    /// 屏上（dx=dy=0）正在编辑的那条交给输入框显示，跳过
    private func drawTexts(dx: CGFloat, dy: CGFloat) {
        for (i, t) in texts.enumerated() {
            if dx == 0, dy == 0, isEditing(.annoText(i)) { continue }
            guard !t.text.isEmpty else { continue }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: t.fontSize, weight: .semibold),
                .foregroundColor: NSColor(Color(hex: t.colorHex))]
            withShadow(blur: 3, alpha: 0.45) {
                // 与编辑输入框同套内边距，落定后文字位置与编辑时严丝合缝
                (t.text as NSString).draw(in: t.rect.offsetBy(dx: dx, dy: dy).insetBy(dx: bubblePadX, dy: bubblePadY), withAttributes: attrs)
            }
        }
    }

    /// 箭头：已落定 + 正在拖的预览（屏上与导出共用，dx/dy 平移）
    private func drawArrows(dx: CGFloat, dy: CGFloat) {
        for a in arrows { strokeArrow(a, dx: dx, dy: dy) }
        if let c = currentArrow { strokeArrow(c, dx: dx, dy: dy) }
    }
    /// 一体成型锥形箭头（大梁老师定稿）：尾端最细 → 杆身微微渐宽 → 三角头最宽，
    /// 整支箭是一个填充多边形，杆与头无拼接痕。头长随粗细走、短箭头自动收敛不失衡
    private func strokeArrow(_ a: Arrow, dx: CGFloat, dy: CGFloat) {
        let s = NSPoint(x: a.start.x + dx, y: a.start.y + dy)
        let e = NSPoint(x: a.end.x + dx, y: a.end.y + dy)
        let len = hypot(e.x - s.x, e.y - s.y)
        guard len > 0.5 else { return }
        let ang = atan2(e.y - s.y, e.x - s.x)
        let ux = cos(ang), uy = sin(ang)     // 箭身方向单位向量
        let nx = -uy, ny = ux                // 法线单位向量（宽度方向）
        let w = a.lineWidth
        let headLen = min(max(11, w * 3.4), len * 0.55)   // 头长
        let barbHalf = max(4.5, w * 1.6)     // 头根半宽：全箭最宽处
        let rootHalf = max(1.6, w * 0.62)    // 杆身到头根处的半宽
        let tailHalf = max(0.6, w * 0.22)    // 尾端半宽：最细
        let root = NSPoint(x: e.x - headLen * ux, y: e.y - headLen * uy)
        func off(_ p: NSPoint, _ k: CGFloat) -> NSPoint { NSPoint(x: p.x + nx * k, y: p.y + ny * k) }
        let path = NSBezierPath()
        path.move(to: off(s, tailHalf))      // 尾上缘
        path.line(to: off(root, rootHalf))   // 杆身渐宽至头根
        path.line(to: off(root, barbHalf))   // 张开成头
        path.line(to: e)                     // 箭尖
        path.line(to: off(root, -barbHalf))
        path.line(to: off(root, -rootHalf))
        path.line(to: off(s, -tailHalf))     // 尾下缘
        path.close()
        withShadow(blur: 4, alpha: 0.3) {
            NSColor(Color(hex: a.colorHex)).setFill()
            path.fill()
        }
    }

    /// 水印：选区内平铺 -30° 斜排半透明文字（文字为空不画）；隔行错位半步铺得更自然。
    /// 屏上与导出共用：dx/dy 把选区坐标平移到目标上下文
    private func drawWatermark(in sel: NSRect, dx: CGFloat, dy: CGFloat) {
        let text = wmText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let rect = sel.offsetBy(dx: dx, dy: dy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(Color(hex: wmColorHex)).withAlphaComponent(wmOpacity)]
        let sz = (text as NSString).size(withAttributes: attrs)
        let gapScale: [CGFloat] = [2.6, 1.5, 0.7]   // 稀 / 中 / 密：间距倍数
        let g = gapScale[min(max(wmDensity, 0), 2)]
        let stepX = sz.width + 90 * g
        let stepY = sz.height + 55 * g
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let t = NSAffineTransform()
        t.translateX(by: rect.midX, yBy: rect.midY)
        t.rotate(byDegrees: -30)
        t.concat()
        // 旋转后以选区对角线为半径平铺，保证四角无空缺
        let r = hypot(rect.width, rect.height) / 2 + max(stepX, stepY)
        var y = -r, row = 0
        while y < r {
            var x = -r + (row % 2 == 0 ? 0 : stepX / 2)
            while x < r {
                (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                x += stepX
            }
            y += stepY; row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 鼠标

    /// 选区可调手柄：四角 + 四边中点共 8 个白底方点（编辑态常显，提示边缘可拖）
    private func drawSelectionEdgeHandles(_ sel: NSRect) {
        let s: CGFloat = 6
        let pts = [
            NSPoint(x: sel.minX, y: sel.minY), NSPoint(x: sel.midX, y: sel.minY), NSPoint(x: sel.maxX, y: sel.minY),
            NSPoint(x: sel.minX, y: sel.midY), NSPoint(x: sel.maxX, y: sel.midY),
            NSPoint(x: sel.minX, y: sel.maxY), NSPoint(x: sel.midX, y: sel.maxY), NSPoint(x: sel.maxX, y: sel.maxY),
        ]
        for p in pts {
            let r = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            NSColor.white.setFill(); NSBezierPath(rect: r).fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let bp = NSBezierPath(rect: r); bp.lineWidth = 0.5; bp.stroke()
        }
    }

    /// 选区边缘命中 → 调整模式：四角 ±7pt（对角固定）优先，四条边 ±7pt 带（单边移动）次之
    private func selectionGrabMode(at pt: NSPoint) -> SelRectMode? {
        guard let sel = selection else { return nil }
        let t: CGFloat = 7
        let corners: [(NSPoint, NSPoint)] = [
            (NSPoint(x: sel.minX, y: sel.minY), NSPoint(x: sel.maxX, y: sel.maxY)),
            (NSPoint(x: sel.maxX, y: sel.minY), NSPoint(x: sel.minX, y: sel.maxY)),
            (NSPoint(x: sel.minX, y: sel.maxY), NSPoint(x: sel.maxX, y: sel.minY)),
            (NSPoint(x: sel.maxX, y: sel.maxY), NSPoint(x: sel.minX, y: sel.minY)),
        ]
        for (corner, fixed) in corners where abs(pt.x - corner.x) <= t && abs(pt.y - corner.y) <= t {
            return .corner(fixed: fixed)
        }
        let insideY = pt.y >= sel.minY - t && pt.y <= sel.maxY + t
        let insideX = pt.x >= sel.minX - t && pt.x <= sel.maxX + t
        if abs(pt.x - sel.minX) <= t, insideY { return .left }
        if abs(pt.x - sel.maxX) <= t, insideY { return .right }
        if abs(pt.y - sel.maxY) <= t, insideX { return .top }
        if abs(pt.y - sel.minY) <= t, insideX { return .bottom }
        return nil
    }

    /// 译图与渐进翻译缓存作废（选区变更时调用，避免旧译图错位/拉伸变形）
    private func clearTranslationOverride() {
        guard translatedOverride != nil || translatePartial != nil else { return }
        translatedOverride = nil; translatePartial = nil; showingOriginal = false
    }

    override func mouseDown(with event: NSEvent) {
        guard !recordingLong, !longFinished else { return }      // 长截图录制/选方向/出图阶段，覆盖层不响应背景点击
        guard ocrPanel == nil, hintView == nil else { return }   // OCR 面板/翻译中不响应背景点击
        let pt = convert(event.locationInWindow, from: nil)
        // 点选中组件的删除按钮(×) → 删除整个组件（优先于一切，正在编辑也能删）
        if let sel = selected, deleteButtonRect(sel).contains(pt) {
            let f = editingField; editingField = nil; editing = nil; f?.removeFromSuperview()   // 丢弃编辑器，不提交
            record(); deleteSelected(); needsDisplay = true
            return
        }
        // 点在顶部工具栏 / 样式面板范围内（含按钮之间的透明间隙）：交给面板响应，别当"空白点击"把选中清掉
        if let th = toolbarHost, th.frame.insetBy(dx: -6, dy: -6).contains(pt) { return }
        if let oh = optionsHost, oh.frame.insetBy(dx: -6, dy: -6).contains(pt) { return }
        // 已选中框选/箭头：命中手柄=缩放/拖端点，命中身体=整体移动（像系统选中对象，优先于画新）
        if phase == .editing, let g = hitSelectedGrab(at: pt) {
            commitEditing()
            // 双击旋转手柄 → 恢复默认角度（归零）
            if case .boxRotate = g.mode, event.clickCount >= 2,
               case .box(let i)? = selected, boxes.indices.contains(i) {
                record(); boxes[i].rotation = 0; needsDisplay = true
                return
            }
            selGrab = g; needsDisplay = true
            return
        }
        // 选区自身边缘调整：拖四角/四边重截边界，没截准不用重来（不影响已画标注）
        if phase == .editing, let mode = selectionGrabMode(at: pt) {
            commitEditing(); selected = nil
            clearTranslationOverride()   // 选区将变，按旧选区渲染的译图作废
            selRectGrab = mode
            needsDisplay = true
            return
        }
        // 画笔 / 马赛克涂抹：自由起笔（优先于标注交互）
        if phase == .editing, tool == .pen || (tool == .mosaic && mosaicMode == .brush) {
            // 画笔工具下先判是否点在已有吸附形状边框上：命中＝选中它（可拖动/改色/缩放/删除），空白＝起笔画新
            if tool == .pen, let hit = hitAnnotation(at: pt), case .shape = hit {
                commitEditing(); selected = hit; needsDisplay = true
                return
            }
            commitEditing(); selected = nil; record(); currentStroke = [clampToSel(pt)]; needsDisplay = true
            return
        }
        // 区域马赛克：拖矩形
        if phase == .editing, tool == .mosaic, mosaicMode == .box {
            commitEditing(); selected = nil; boxOrigin = pt; currentBox = NSRect(origin: pt, size: .zero); needsDisplay = true
            return
        }
        // 箭头：按下起点，拖出终点
        if phase == .editing, tool == .arrow {
            commitEditing()
            selected = hitAnnotation(at: pt)   // 点在已有箭头/标注上先选中：没拖=保留选中（二次调参），拖了=画新箭头
            currentArrow = Arrow(start: pt, end: pt, colorHex: arrowColorHex, lineWidth: arrowLineWidth)
            needsDisplay = true
            return
        }
        // 文字：点已有文字重新编辑，点空白新建输入
        if phase == .editing, tool == .text {
            commitEditing()
            if let i = texts.lastIndex(where: { $0.rect.contains(pt) }) {
                selected = nil
                startTextEdit(i)
            } else if (selection ?? .zero).insetBy(dx: -40, dy: -40).contains(pt) {   // 选区外围也可放字（导出会带上）
                selected = nil
                record()
                let size = bubbleSize("", maxWidth: bubbleMaxWidth)
                texts.append(TextAnno(rect: NSRect(x: pt.x, y: pt.y - size.height, width: size.width, height: size.height),
                                      text: "", colorHex: textColorHex, fontSize: textFontSize))
                startTextEdit(texts.count - 1)
            }
            needsDisplay = true
            return
        }
        if phase == .editing { selected = hitAnnotation(at: pt) }   // 命中标注＝选中，空白＝清空
        // 几何调整态：优先处理 activeMarker 的角手柄/框身（拖角缩放、拖身移动、点框外退出）
        if phase == .editing, let i = activeMarker, markers.indices.contains(i) {
            let box = markers[i].box
            if let fixed = resizeAnchor(box, at: pt) {
                selected = .marker(i)   // 几何调整中保持选中，删除「×」不消失
                commitEditing()
                markerGrab = MarkerGrab(mode: .resize(fixed: fixed), moved: false)
                return
            } else if box.contains(pt) {
                selected = .marker(i)
                commitEditing()
                markerGrab = MarkerGrab(mode: .move(NSPoint(x: pt.x - box.minX, y: pt.y - box.minY)), moved: false)
                return
            } else {
                activeMarker = nil   // 点框外 → 退出几何调整，继续按常规处理
            }
        }
        // 优先：点中已有说明气泡 → 准备拖动（拖＝移动文字框，单击＝重新编辑文字），不论当前工具
        if phase == .editing, let ref = bubbleHit(at: pt) {
            commitEditing()
            let o = bubbleOrigin(ref)
            pendingBubble = PendingBubble(ref: ref, grab: NSPoint(x: pt.x - o.x, y: pt.y - o.y), down: pt, moved: false)
            needsDisplay = true
            return
        }
        if phase == .editing, tool == .flow {
            commitEditing()
            if let i = steps.firstIndex(where: { hypot($0.center.x - pt.x, $0.center.y - pt.y) <= badgeRadius + 2 }) {
                if event.clickCount >= 2 { startStepNumberEdit(i) }   // 双击角标 → 改序号
                else {                                                 // 单击角标 → 待拖动(拖=移动角标，松手没拖=编辑文字)
                    pendingBadge = PendingBadge(index: i, grab: NSPoint(x: pt.x - steps[i].center.x, y: pt.y - steps[i].center.y), down: pt, moved: false)
                }
            } else if event.clickCount == 1, (selection ?? .zero).contains(pt) {
                addStep(at: pt)                                        // 单击空白 → 新角标
            }
        } else if phase == .editing, tool == .box || tool == .note || tool == .highlight {
            commitEditing()
            if tool == .note, let i = markerBoxIndex(at: pt) {
                // 备注单击：同时进入文字编辑 + 几何调整（输入框、四角手柄一起出现）
                activeMarker = i
                startMarkerTextEdit(i)
            } else {
                boxOrigin = pt
                currentBox = NSRect(origin: pt, size: .zero)
            }
        } else if phase == .editing, tool == .watermark {
            commitEditing()   // 水印工具下点画布不作画，避免误触重新框选（水印靠子选项条输入）
        } else {
            phase = .selecting
            removeToolbar()
            commitEditing()
            boxes.removeAll(); markers.removeAll(); steps.removeAll(); penStrokes.removeAll(); arrows.removeAll(); texts.removeAll(); mosaicStrokes.removeAll(); mosaicRects.removeAll(); shapes.removeAll()
            activeMarker = nil; selected = nil; undoStack.removeAll()
            dragOrigin = pt
            selection = NSRect(origin: pt, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !recordingLong, !longFinished else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if let mode = selRectGrab, var sel = selection {   // 选区边缘调整（宽高保底 8pt 防翻面）
            switch mode {
            case .corner(let fixed): sel = Self.rect(fixed, pt)
            case .left:   sel = NSRect(x: min(pt.x, sel.maxX - 8), y: sel.minY, width: max(8, sel.maxX - pt.x), height: sel.height)
            case .right:  sel = NSRect(x: sel.minX, y: sel.minY, width: max(8, pt.x - sel.minX), height: sel.height)
            case .top:    sel = NSRect(x: sel.minX, y: sel.minY, width: sel.width, height: max(8, pt.y - sel.minY))
            case .bottom: sel = NSRect(x: sel.minX, y: min(pt.y, sel.maxY - 8), width: sel.width, height: max(8, sel.maxY - pt.y))
            }
            selection = sel
            needsDisplay = true
            return
        }
        if currentStroke != nil {   // 自由笔画
            if let raw = rawStrokeBeforeSnap { currentStroke = raw; rawStrokeBeforeSnap = nil; snappedShape = nil }   // 已吸附又继续动 → 撤销吸附、回自由轨迹
            currentStroke?.append(clampToSel(pt)); needsDisplay = true
            scheduleShapeSnap()
            return
        }
        if currentArrow != nil { currentArrow?.end = pt; needsDisplay = true; return }       // 箭头拖拽预览
        if var grab = markerGrab, let i = activeMarker, markers.indices.contains(i) {
            if !grab.moved { record() }   // 首次移动前记录撤回点
            grab.moved = true; markerGrab = grab
            switch grab.mode {
            case .move(let g):
                markers[i].box.origin = NSPoint(x: pt.x - g.x, y: pt.y - g.y)   // 移动整个框
            case .resize(let fixed):
                markers[i].box = Self.rect(fixed, pt)   // 拖角缩放，对角固定；范围放开到整屏（导出仍按选区裁剪）
            }
            needsDisplay = true
            return
        }
        if var g = selGrab {   // 选中框选/箭头的拖拽调整（移动 / 缩放 / 拖端点）
            if !g.moved { record() }
            g.moved = true; selGrab = g
            applySelGrab(g.mode, to: pt)
            needsDisplay = true
            return
        }
        if let pb = pendingBubble {
            if !pb.moved, hypot(pt.x - pb.down.x, pt.y - pb.down.y) <= 4 { return }   // 未超阈值＝仍按单击，不误判成拖动
            if !pb.moved { record() }
            pendingBubble?.moved = true
            moveBubble(pb.ref, to: NSPoint(x: pt.x - pb.grab.x, y: pt.y - pb.grab.y))   // 拖动气泡，引导线随之同步
            needsDisplay = true
            return
        }
        if let pb = pendingBadge {
            if !pb.moved, hypot(pt.x - pb.down.x, pt.y - pb.down.y) <= 4 { return }   // 未超阈值＝仍按单击，不误判成拖动
            if !pb.moved { record() }
            pendingBadge?.moved = true
            if steps.indices.contains(pb.index) { steps[pb.index].center = NSPoint(x: pt.x - pb.grab.x, y: pt.y - pb.grab.y) }   // 拖动角标，引导线随之
            needsDisplay = true
            return
        }
        if (tool == .box || tool == .note || tool == .highlight || (tool == .mosaic && mosaicMode == .box)), let o = boxOrigin {
            currentBox = Self.rect(o, pt).intersection(selection ?? .zero)
        } else if let o = dragOrigin {
            selection = Self.rect(o, pt)
            // 真正拖开了 = 自由框选，撤掉窗口吸附高亮
            if hoverWindowRect != nil, let s = selection, max(s.width, s.height) >= 4 { hoverWindowRect = nil }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !recordingLong, !longFinished else { return }
        if selRectGrab != nil {   // 结束选区边缘调整：按新选区重定位工具栏
            selRectGrab = nil
            if let sel = selection { showToolbar(for: sel) }
            needsDisplay = true
            return
        }
        if let g = selGrab {   // 结束选中对象的拖拽调整；文字标注没拖＝单击 → 重新编辑
            selGrab = nil
            if !g.moved, case .move = g.mode, case .text(let i)? = selected, texts.indices.contains(i) {
                selected = nil
                startTextEdit(i)
            }
            needsDisplay = true
            return
        }
        if let pts = currentStroke {   // 画笔 / 马赛克涂抹收尾
            currentStroke = nil
            let snapped = snappedShape
            cancelShapeSnap()
            if tool == .pen {
                // 吸附成规整形状 → 存为可编辑 Shape；折线/自由涂鸦 → 存自由笔画
                switch snapped {
                case .line(let a, let b):
                    shapes.append(Shape(kind: .line, p0: a, p1: b, colorHex: penColorHex, lineWidth: penLineWidth))
                case .rect(let r):
                    shapes.append(Shape(kind: .rect, p0: NSPoint(x: r.minX, y: r.minY), p1: NSPoint(x: r.maxX, y: r.maxY), colorHex: penColorHex, lineWidth: penLineWidth))
                case .ellipse(let r):
                    shapes.append(Shape(kind: .ellipse, p0: NSPoint(x: r.minX, y: r.minY), p1: NSPoint(x: r.maxX, y: r.maxY), colorHex: penColorHex, lineWidth: penLineWidth))
                case .polyline(let vertices):   // 折线：存为可编辑形状（多顶点）
                    shapes.append(Shape(kind: .polyline, points: vertices, colorHex: penColorHex, lineWidth: penLineWidth))
                case .none:
                    if !pts.isEmpty { penStrokes.append(Stroke(points: pts, colorHex: penColorHex, lineWidth: penLineWidth)) }
                }
            } else if !pts.isEmpty {
                mosaicStrokes.append(MosaicStroke(points: pts, lineWidth: mosaicLineWidth))
            }
            needsDisplay = true
            return
        }
        if let a = currentArrow {   // 箭头收尾：拖出才画新箭头；没拖=保留 mouseDown 时选中的已有标注（二次调参）
            currentArrow = nil
            if hypot(a.end.x - a.start.x, a.end.y - a.start.y) >= 8 { record(); arrows.append(a); selected = nil }
            needsDisplay = true
            return
        }
        if let grab = markerGrab {
            markerGrab = nil
            if !grab.moved, case .move = grab.mode, let i = activeMarker {
                if markers.indices.contains(i) { startMarkerTextEdit(i) }   // 框身单击(没拖) → 重新聚焦文字编辑，手柄保持
            }
            needsDisplay = true
            return
        }
        if let pb = pendingBubble {
            pendingBubble = nil
            if !pb.moved {                       // 没拖动＝单击 → 重新编辑该气泡文字
                switch pb.ref {
                case .marker(let i): if markers.indices.contains(i) { startMarkerTextEdit(i) }
                case .step(let i):   if steps.indices.contains(i) { startStepTextEdit(i) }
                }
            }
            needsDisplay = true
            return
        }
        if let pb = pendingBadge {
            pendingBadge = nil
            if !pb.moved, steps.indices.contains(pb.index) { startStepTextEdit(pb.index) }   // 没拖＝单击 → 编辑文字
            needsDisplay = true
            return
        }
        if phase == .selecting, let sel = selection {
            dragOrigin = nil
            if sel.width >= 4, sel.height >= 4 {
                hoverWindowRect = nil
                phase = .editing; showToolbar(for: sel)
            } else if let hw = hoverWindowRect {
                // 没拖开 = 单击吸附窗口 → 整窗选中，直接进编辑态
                selection = hw
                snappedWindowRect = hw            // 记为整窗吸附：导出时裁成窗口真实形状
                snappedWindowID = hoverWindowID
                snappedWindowImage = nil
                if let id = hoverWindowID { captureWindowShape(id: id) }   // 异步截该窗口真实圆角形状
                hoverWindowRect = nil
                phase = .editing; showToolbar(for: hw)
            } else { selection = nil }
        } else if phase == .editing, tool == .mosaic, mosaicMode == .box, let b = currentBox {
            currentBox = nil; boxOrigin = nil
            if b.width >= 6, b.height >= 6 { record(); mosaicRects.append(b) }   // 区域马赛克
        } else if phase == .editing, tool == .box || tool == .note || tool == .highlight, let b = currentBox {
            currentBox = nil; boxOrigin = nil
            if b.width >= 6, b.height >= 6 {
                if tool == .box { record(); boxes.append(currentStyleBox(b)) }
                else if tool == .highlight {   // 高亮工具：拖出即聚光灯框（一级工具，不再走框选灯泡/双击）
                    record(); boxes.append(Box(rect: b, shape: hlShape, highlight: true))
                }
                else { addMarker(box: b) }
            }
        } else {
            currentBox = nil; boxOrigin = nil
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if recordingLong { if event.keyCode == 53 { cancelLongShot() }; return }   // 录制中：Esc 取消，其余键忽略
        if longFinished { if event.keyCode == 53 { cleanupLongShot(); close() }; return }   // 选输出态：Esc 丢弃
        // Cmd+Z 撤回任意标注操作（文字编辑时归 NSTextView 自己处理，不会走到这里）
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            undo(); return
        }
        switch event.keyCode {
        case 53:                                 // Esc：编辑中先结束编辑，几何调整中先退出，有选中标注先删除，否则取消截图
            if editingField != nil { commitEditing() }
            else if activeMarker != nil { activeMarker = nil; markerGrab = nil; needsDisplay = true }
            else if selected != nil { record(); deleteSelected(); needsDisplay = true }
            else { close() }
        case 36, 76:                             // Return/Enter：先结束当前所处的任何状态(编辑/几何调整/选中)，全不在才完成(复制)
            if editingField != nil { commitEditing() }
            else if activeMarker != nil { activeMarker = nil; markerGrab = nil; needsDisplay = true }
            else if selected != nil { selected = nil; needsDisplay = true }   // 退出选中态(保留组件)，不直接保存截图
            else { copyToClipboard() }
        default: super.keyDown(with: event)
        }
    }

    private static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 命中已有备注选框（用于单击重新输入文字、双击进入几何调整）
    private func markerBoxIndex(at pt: NSPoint) -> Int? { markers.lastIndex(where: { $0.box.contains(pt) }) }

    /// 命中任意标注（备注气泡/框、流程气泡/角标、箭头、框选）→ 用于「单击选中、ESC 删除、二次调参」
    private func hitAnnotation(at pt: NSPoint) -> AnnotationRef? {
        if let i = texts.lastIndex(where: { !$0.text.isEmpty && $0.rect.contains(pt) }) { return .text(i) }
        if let i = markers.lastIndex(where: { !$0.text.isEmpty && $0.textRect.contains(pt) }) { return .marker(i) }
        if let i = markers.lastIndex(where: { $0.box.contains(pt) }) { return .marker(i) }
        if let i = steps.lastIndex(where: { !$0.text.isEmpty && $0.textRect.contains(pt) }) { return .step(i) }
        if let i = steps.lastIndex(where: { hypot($0.center.x - pt.x, $0.center.y - pt.y) <= badgeRadius + 2 }) { return .step(i) }
        if let i = arrows.lastIndex(where: { Self.pointSegDistance(pt, $0.start, $0.end) <= max(10, $0.lineWidth + 6) }) { return .arrow(i) }
        if let i = boxes.lastIndex(where: { Self.boxContains($0, pt) }) { return .box(i) }
        if let i = shapes.lastIndex(where: { Self.shapeContains($0, pt) }) { return .shape(i) }
        return nil
    }

    /// 形状命中检测：直线=贴线；矩形/椭圆=贴边框（不填充内部，避免挡住下层内容）
    private static func shapeContains(_ s: Shape, _ pt: NSPoint) -> Bool {
        switch s.kind {
        case .line: return pointSegDistance(pt, s.p0, s.p1) <= max(18, s.lineWidth + 12)   // 细线放宽命中带，好点中
        case .rect:
            let pad = max(14, s.lineWidth + 6)
            return s.rect.insetBy(dx: -pad, dy: -pad).contains(pt) && !s.rect.insetBy(dx: pad, dy: pad).contains(pt)   // 矩形框内容，只命中边框环
        case .ellipse:
            let pad = max(14, s.lineWidth + 6)
            return s.rect.insetBy(dx: -pad, dy: -pad).contains(pt)   // 圆整块可选，好点中
        case .polyline:
            guard s.points.count >= 2 else { return false }
            for i in 1..<s.points.count where pointSegDistance(pt, s.points[i - 1], s.points[i]) <= max(18, s.lineWidth + 12) { return true }
            return false
        }
    }

    /// 点到线段最短距离（箭头命中检测用）
    private static func pointSegDistance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 改选中框选的样式（二次调参）：record 一次快照后原地改选中的那个 Box
    private func updateSelectedBox(_ change: (inout Box) -> Void) {
        guard case .box(let i)? = selected, boxes.indices.contains(i) else { return }
        record(); change(&boxes[i]); refreshToolbars()
    }
    /// 改选中箭头的颜色/粗细（二次调参）
    private func updateSelectedArrow(_ change: (inout Arrow) -> Void) {
        guard case .arrow(let i)? = selected, arrows.indices.contains(i) else { return }
        record(); change(&arrows[i]); refreshToolbars()
    }
    /// 改选中吸附形状的颜色/粗细（二次调参）
    private func updateSelectedShape(_ change: (inout Shape) -> Void) {
        guard case .shape(let i)? = selected, shapes.indices.contains(i) else { return }
        record(); change(&shapes[i]); refreshToolbars()
    }
    /// 改选中文字标注的颜色/字号（二次调参）；字号变了按新字体重排文字框（左上角固定）
    private func updateSelectedText(_ change: (inout TextAnno) -> Void) {
        guard case .text(let i)? = selected, texts.indices.contains(i) else { return }
        record(); change(&texts[i])
        let t = texts[i]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: t.fontSize, weight: .semibold)]
        let bound = (t.text as NSString).boundingRect(
            with: NSSize(width: bubbleMaxWidth - bubblePadX * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        let size = NSSize(width: ceil(bound.width) + bubblePadX * 2, height: ceil(bound.height) + bubblePadY * 2)
        texts[i].rect = NSRect(x: t.rect.minX, y: t.rect.maxY - size.height, width: size.width, height: size.height)
        refreshToolbars()
    }

    /// 命中已选中的框选/箭头 → 拖拽模式：框四角=缩放、框内=移动；箭头端点=拖端、线身=移动
    private func hitSelectedGrab(at pt: NSPoint) -> (mode: SelGrabMode, moved: Bool)? {
        switch selected {
        case .box(let i)? where boxes.indices.contains(i):
            let b = boxes[i]
            // 旋转手柄优先（圆钮 10pt 命中带）
            let knob = Self.boxRotateHandle(b)
            if hypot(pt.x - knob.x, pt.y - knob.y) <= 10 { return (.boxRotate(center: b.center), false) }
            // 四角缩放/框身移动：都换算到框的本地坐标系判断（跟随旋转）
            let local = Self.rotatePoint(pt, around: b.center, by: -b.rotation)
            if let fixed = resizeAnchor(b.rect, at: local) {
                return (.boxResize(fixed: fixed, center: b.center, angle: b.rotation), false)
            }
            if b.rect.insetBy(dx: -6, dy: -6).contains(local) {
                return (.move(NSPoint(x: pt.x - b.rect.minX, y: pt.y - b.rect.minY)), false)
            }
        case .arrow(let i)? where arrows.indices.contains(i):
            let a = arrows[i]
            if hypot(pt.x - a.end.x, pt.y - a.end.y) <= 11 { return (.arrowEnd(start: false), false) }
            if hypot(pt.x - a.start.x, pt.y - a.start.y) <= 11 { return (.arrowEnd(start: true), false) }
            if Self.pointSegDistance(pt, a.start, a.end) <= max(11, a.lineWidth + 6) {
                return (.move(NSPoint(x: pt.x - a.start.x, y: pt.y - a.start.y)), false)
            }
        case .text(let i)? where texts.indices.contains(i):
            let r = texts[i].rect
            if r.insetBy(dx: -4, dy: -4).contains(pt) {
                return (.move(NSPoint(x: pt.x - r.minX, y: pt.y - r.minY)), false)
            }
        case .shape(let i)? where shapes.indices.contains(i):
            let s = shapes[i]
            if s.kind == .polyline {   // 折线：顶点圆钮拖折角，线身整体移动
                for (idx, v) in s.points.enumerated() where hypot(pt.x - v.x, pt.y - v.y) <= 13 {
                    return (.polyVertex(idx), false)
                }
                if s.points.count >= 2 {
                    for k in 1..<s.points.count where Self.pointSegDistance(pt, s.points[k - 1], s.points[k]) <= max(18, s.lineWidth + 12) {
                        return (.move(NSPoint(x: pt.x - s.points[0].x, y: pt.y - s.points[0].y)), false)
                    }
                }
            } else if s.kind == .line {   // 直线：两端圆钮拖端点，线身移动（复用 arrowEnd 语义）
                if hypot(pt.x - s.p1.x, pt.y - s.p1.y) <= 13 { return (.arrowEnd(start: false), false) }
                if hypot(pt.x - s.p0.x, pt.y - s.p0.y) <= 13 { return (.arrowEnd(start: true), false) }
                if Self.pointSegDistance(pt, s.p0, s.p1) <= max(18, s.lineWidth + 12) {
                    return (.move(NSPoint(x: pt.x - s.p0.x, y: pt.y - s.p0.y)), false)
                }
            } else {               // 矩形/椭圆：四角缩放，框内移动（无旋转）
                if let fixed = resizeAnchor(s.rect, at: pt) {
                    return (.boxResize(fixed: fixed, center: NSPoint(x: s.rect.midX, y: s.rect.midY), angle: 0), false)
                }
                if s.rect.insetBy(dx: -6, dy: -6).contains(pt) {
                    return (.move(NSPoint(x: pt.x - s.rect.minX, y: pt.y - s.rect.minY)), false)
                }
            }
        default: break
        }
        return nil
    }

    /// 应用选中对象拖拽：整体移动 / 框四角缩放 / 框旋转 / 拖箭头某端（不限制到选区，可到整屏）
    private func applySelGrab(_ mode: SelGrabMode, to pt: NSPoint) {
        switch selected {
        case .box(let i)? where boxes.indices.contains(i):
            switch mode {
            case .move(let o): boxes[i].rect.origin = NSPoint(x: pt.x - o.x, y: pt.y - o.y)
            case .boxResize(let fixed, let center, let angle):
                // 拖点换算到拖拽起始时的本地坐标系再定新框（中心/角度用起始快照，避免逐帧漂移）
                let local = Self.rotatePoint(pt, around: center, by: -angle)
                boxes[i].rect = Self.rect(fixed, local)
            case .boxRotate(let center):
                // 拖点相对中心的方位角 − 手柄初始方位（正上方 π/2）＝旋转角
                boxes[i].rotation = atan2(pt.y - center.y, pt.x - center.x) - .pi / 2
            case .arrowEnd, .polyVertex: break
            }
        case .arrow(let i)? where arrows.indices.contains(i):
            switch mode {
            case .move(let o):
                let ns = NSPoint(x: pt.x - o.x, y: pt.y - o.y)          // 新起点
                let dx = ns.x - arrows[i].start.x, dy = ns.y - arrows[i].start.y
                arrows[i].start = ns
                arrows[i].end = NSPoint(x: arrows[i].end.x + dx, y: arrows[i].end.y + dy)
            case .arrowEnd(let isStart):
                if isStart { arrows[i].start = pt } else { arrows[i].end = pt }
            case .boxResize, .boxRotate, .polyVertex: break
            }
        case .text(let i)? where texts.indices.contains(i):
            if case .move(let o) = mode { texts[i].rect.origin = NSPoint(x: pt.x - o.x, y: pt.y - o.y) }
        case .shape(let i)? where shapes.indices.contains(i):
            switch mode {
            case .move(let o):
                if shapes[i].kind == .line {   // 整条平移，保持长度和方向
                    let ns = NSPoint(x: pt.x - o.x, y: pt.y - o.y)
                    let dx = ns.x - shapes[i].p0.x, dy = ns.y - shapes[i].p0.y
                    shapes[i].p0 = ns
                    shapes[i].p1 = NSPoint(x: shapes[i].p1.x + dx, y: shapes[i].p1.y + dy)
                } else if shapes[i].kind == .polyline {   // 整条折线平移，所有顶点同移
                    guard let base = shapes[i].points.first else { break }
                    let ns = NSPoint(x: pt.x - o.x, y: pt.y - o.y)
                    let dx = ns.x - base.x, dy = ns.y - base.y
                    for k in shapes[i].points.indices { shapes[i].points[k].x += dx; shapes[i].points[k].y += dy }
                } else {                       // 整框平移，保持宽高
                    let r = shapes[i].rect
                    let no = NSPoint(x: pt.x - o.x, y: pt.y - o.y)
                    shapes[i].p0 = no
                    shapes[i].p1 = NSPoint(x: no.x + r.width, y: no.y + r.height)
                }
            case .arrowEnd(let isStart):       // 直线端点
                if isStart { shapes[i].p0 = pt } else { shapes[i].p1 = pt }
            case .boxResize(let fixed, _, _):  // 矩形/椭圆角缩放（对角固定）
                shapes[i].p0 = fixed; shapes[i].p1 = pt
            case .polyVertex(let vi):          // 折线：拖某个折角顶点
                if shapes[i].points.indices.contains(vi) { shapes[i].points[vi] = pt }
            case .boxRotate: break
            }
        default: break
        }
    }

    /// 删除当前选中的标注
    private func deleteSelected() {
        switch selected {
        case .box(let i):    if boxes.indices.contains(i) { boxes.remove(at: i) }
        case .marker(let i): if markers.indices.contains(i) { markers.remove(at: i) }
        case .step(let i):   if steps.indices.contains(i) { steps.remove(at: i) }
        case .arrow(let i):  if arrows.indices.contains(i) { arrows.remove(at: i) }
        case .text(let i):   if texts.indices.contains(i) { texts.remove(at: i) }
        case .shape(let i):  if shapes.indices.contains(i) { shapes.remove(at: i) }
        case .none: break
        }
        selected = nil; activeMarker = nil
    }

    /// 撤回：记录当前标注快照 / 回退到上一步
    private func record() {
        undoStack.append(Snapshot(boxes: boxes, markers: markers, steps: steps, pen: penStrokes, arrows: arrows, texts: texts, mosaicS: mosaicStrokes, mosaicR: mosaicRects, shapes: shapes))
        if undoStack.count > 80 { undoStack.removeFirst() }
    }
    private func undo() {
        let f = editingField; editingField = nil; editing = nil   // 丢弃正在编辑的输入框（不计入历史）
        f?.removeFromSuperview()
        guard let s = undoStack.popLast() else { return }
        boxes = s.boxes; markers = s.markers; steps = s.steps
        penStrokes = s.pen; arrows = s.arrows; texts = s.texts; mosaicStrokes = s.mosaicS; mosaicRects = s.mosaicR; shapes = s.shapes
        selected = nil; activeMarker = nil; markerGrab = nil; pendingBubble = nil; pendingBadge = nil; currentStroke = nil; currentArrow = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// 命中备注框某个角手柄 → 返回其对角（缩放时固定的点）；都没命中返回 nil
    private func resizeAnchor(_ box: NSRect, at pt: NSPoint) -> NSPoint? {
        let hit: CGFloat = 11
        let pairs: [(NSPoint, NSPoint)] = [
            (NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.maxY)),
            (NSPoint(x: box.maxX, y: box.minY), NSPoint(x: box.minX, y: box.maxY)),
            (NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.minY)),
            (NSPoint(x: box.maxX, y: box.maxY), NSPoint(x: box.minX, y: box.minY)),
        ]
        for (corner, opposite) in pairs where abs(pt.x - corner.x) <= hit && abs(pt.y - corner.y) <= hit {
            return opposite
        }
        return nil
    }

    /// 命中已有说明气泡（有文字的备注/流程文字框），用于拖动或重新编辑
    private func bubbleHit(at pt: NSPoint) -> BubbleRef? {
        if let i = markers.lastIndex(where: { !$0.text.isEmpty && $0.textRect.contains(pt) }) { return .marker(i) }
        if let i = steps.lastIndex(where: { !$0.text.isEmpty && $0.textRect.contains(pt) }) { return .step(i) }
        return nil
    }
    private func bubbleOrigin(_ ref: BubbleRef) -> NSPoint {
        switch ref {
        case .marker(let i): return markers[i].textRect.origin
        case .step(let i):   return steps[i].textRect.origin
        }
    }
    private func moveBubble(_ ref: BubbleRef, to origin: NSPoint) {
        switch ref {
        case .marker(let i): if markers.indices.contains(i) { markers[i].textRect.origin = origin }
        case .step(let i):   if steps.indices.contains(i) { steps[i].textRect.origin = origin }
        }
    }

    // MARK: - 备注 / 流程 创建

    private func addMarker(box: NSRect) {
        guard let sel = selection else { return }
        record()
        let gap: CGFloat = 20
        let size = bubbleSize("", maxWidth: bubbleMaxWidth)
        var x = box.maxX + gap                       // 文字框左边
        let topY = box.minY - gap                     // 左上角 y（框右下 45°）；换行时此处固定，引导线不动
        x = max(sel.minX + 4, min(x, sel.maxX - size.width - 4))
        markers.append(Marker(box: box, textRect: NSRect(x: x, y: topY - size.height, width: size.width, height: size.height), text: "", colorHex: noteColorHex))
        startMarkerTextEdit(markers.count - 1)
        needsDisplay = true
    }

    private func addStep(at center: NSPoint) {
        guard let sel = selection else { return }
        record()
        let r = badgeRadius, gap: CGFloat = 16
        let size = bubbleSize("", maxWidth: bubbleMaxWidth)
        // 角标右上角往右上 45° 偏移作为文字框左下角；换行时此处固定，引导线不动
        var x = center.x + r / 2.0.squareRoot() + gap
        let bottomY = center.y + r / 2.0.squareRoot() + gap
        x = max(sel.minX + 4, min(x, sel.maxX - size.width - 4))
        // 序号顺延：取屏幕上现有序号的最大值 +1（被手动改过也以最大值为准）
        let next = (steps.compactMap { Int($0.number) }.max() ?? 0) + 1
        steps.append(Step(center: center, number: "\(next)",
                          textRect: NSRect(x: x, y: bottomY, width: size.width, height: size.height), text: "", colorHex: flowColorHex))
        startStepTextEdit(steps.count - 1)
        needsDisplay = true
    }

    // MARK: - 文字编辑（统一）

    @discardableResult
    private func makeField(_ frame: NSRect, value: String, placeholder: String, numeric: Bool,
                           font: NSFont? = nil) -> AnnotationTextView {
        var size = numeric ? frame.size : bubbleSize(value, maxWidth: bubbleMaxWidth)
        let tv = AnnotationTextView(frame: NSRect(origin: frame.origin, size: size))   // 左下角锚点
        tv.font = font ?? (numeric ? numFont : textFont)   // 文字标注传自定字号，与落定渲染一致
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.drawsBackground = false
        tv.isRichText = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.string = value
        tv.alignment = numeric ? .center : .left          // 序号居中；说明左对齐
        tv.delegate = self
        tv.placeholder = placeholder
        tv.placeholderAttrs = [.font: tv.font ?? textFont, .foregroundColor: NSColor.white.withAlphaComponent(0.4)]
        // 内边距与换行宽度：textContainerInset 是系统级留白，编辑态/多行都精确生效
        let padX: CGFloat = numeric ? 5 : bubblePadX
        let numLineH = ceil(numFont.ascender - numFont.descender)
        let padY: CGFloat = numeric ? max(2, (size.height - numLineH) / 2) : bubblePadY
        tv.textContainerInset = NSSize(width: padX, height: padY)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: (numeric ? size.width : bubbleMaxWidth) - padX * 2,
                                                 height: .greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        // 已有文字：按实际排版尺寸收紧，底框贴住文字、不留多余空白（左下角锚点不动）
        if !numeric, !value.isEmpty {
            size = fittedSize(tv)
            tv.frame = NSRect(origin: frame.origin, size: size)
        }
        tv.wantsLayer = true
        tv.layer?.backgroundColor = (numeric ? Self.accent : Self.bubbleBG).cgColor
        tv.layer?.cornerRadius = numeric ? size.height / 2 : 8
        addSubview(tv)
        editingField = tv
        window?.makeFirstResponder(tv)
        return tv
    }

    private func startMarkerTextEdit(_ i: Int) {
        commitEditing()
        makeField(markers[i].textRect, value: markers[i].text, placeholder: "输入说明…", numeric: false)
        editing = .markerText(i)
    }
    private func startTextEdit(_ i: Int) {
        commitEditing()
        makeField(texts[i].rect, value: texts[i].text, placeholder: "输入文字…", numeric: false,
                  font: .systemFont(ofSize: texts[i].fontSize, weight: .semibold))
        editing = .annoText(i)
    }
    private func startStepTextEdit(_ i: Int) {
        commitEditing()
        makeField(steps[i].textRect, value: steps[i].text, placeholder: "输入说明…", numeric: false)
        editing = .stepText(i)
    }
    private func startStepNumberEdit(_ i: Int) {
        commitEditing()
        let c = steps[i].center, s: CGFloat = 26
        makeField(NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s),
                  value: steps[i].number, placeholder: "", numeric: true)
        editing = .stepNumber(i)
    }

    private func commitEditing() {
        guard let field = editingField, let e = editing else { return }
        editingField = nil; editing = nil      // 先清空避免回调重入
        let v = field.string
        switch e {
        case .markerText(let i): if markers.indices.contains(i) {
            if markers[i].text != v { record() }
            markers[i].text = v
            markers[i].textRect = field.frame   // 直接采用输入框最终位置+尺寸（锚角已调好）
        }
        case .stepText(let i):   if steps.indices.contains(i) {
            if steps[i].text != v { record() }
            steps[i].text = v
            steps[i].textRect = field.frame
        }
        case .stepNumber(let i): if steps.indices.contains(i), !v.isEmpty, steps[i].number != v { record(); steps[i].number = v }
        case .annoText(let i): if texts.indices.contains(i) {
            if v.isEmpty { texts.remove(at: i); selected = nil }   // 空文字＝放弃（创建前快照已在栈里，可撤）
            else {
                if texts[i].text != v { record() }
                texts[i].text = v
                texts[i].rect = field.frame   // 采用输入框最终位置+尺寸
            }
        }
        }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// 输入时实时把输入框宽高调整到贴合文字（自适应 + 自动换行），锚角不动
    func textDidChange(_ notification: Notification) {
        guard let tv = editingField, let e = editing else { return }
        tv.needsDisplay = true                 // 占位符随空/非空刷新
        if case .stepNumber = e { return }     // 序号短，固定框
        let size = tv.string.isEmpty ? bubbleSize("", maxWidth: bubbleMaxWidth) : fittedSize(tv)
        guard tv.frame.size != size else { return }
        var origin = tv.frame.origin
        switch e {   // 备注/文字标注：左上角固定(向下长)；流程：左下角固定(向上长)
        case .markerText, .annoText: origin.y = tv.frame.maxY - size.height
        default: break
        }
        tv.frame = NSRect(origin: origin, size: size)
        needsDisplay = true   // 引导线跟随
    }

    func textDidEndEditing(_ notification: Notification) { commitEditing() }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.cancelOperation(_:)) {
            commitEditing()
            return true   // 回车/Esc＝确认文字，不插入换行、不冒泡到完成截图
        }
        return false
    }

    // MARK: - 工具栏

    private func showToolbar(for sel: NSRect) {
        let host = toolbarHost ?? NSHostingView(rootView: makeToolbar())
        host.rootView = makeToolbar()
        if toolbarHost == nil { addSubview(host); toolbarHost = host }
        let size = host.fittingSize
        if toolbarMoved {   // 用户拖过 → 保持手动位置，只按新尺寸原位适配（不跳回自动定位）
            var o = host.frame.origin
            o.x = max(4, min(o.x, bounds.width - size.width - 4))
            o.y = max(4, min(o.y, bounds.height - size.height - 4))
            host.frame = NSRect(origin: o, size: size)
            updateToolOptions(below: host.frame)
            return
        }
        var y = sel.minY - size.height - 8            // 首选：选区下方
        if y < 8 { y = sel.maxY + 8 }                 // 放不下 → 选区上方
        var x = sel.midX - size.width / 2
        if y + size.height > bounds.height - 8 {      // 上方也超屏（选区近全屏）→ 选区内右下角，保证不跑出屏幕
            y = sel.minY + 8
            x = sel.maxX - size.width - 8
        }
        x = max(8, min(x, bounds.width - size.width - 8))
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        updateToolOptions(below: host.frame)   // 框选/画笔/马赛克时主栏下方弹子选项面板（放不下自动翻到上方）
    }

    /// 拖拽手柄回调：SwiftUI 手势给全局累计位移（y 向下），换算到视图坐标（y 向上）移动整条工具栏。
    /// 位移基于拖拽起始 origin 计算，避免逐帧叠加误差；子选项条随行
    private func dragToolbar(translation: CGSize, ended: Bool) {
        guard let host = toolbarHost else { return }
        let base = toolbarDragBase ?? host.frame.origin
        toolbarDragBase = base
        var o = NSPoint(x: base.x + translation.width, y: base.y - translation.height)
        o.x = max(4, min(o.x, bounds.width - host.frame.width - 4))
        o.y = max(4, min(o.y, bounds.height - host.frame.height - 4))
        host.setFrameOrigin(o)
        toolbarMoved = true
        updateToolOptions(below: host.frame)
        if ended { toolbarDragBase = nil }
    }

    private func removeToolbar() {
        toolbarHost?.removeFromSuperview(); toolbarHost = nil
        toolbarMoved = false; toolbarDragBase = nil   // 工具栏退场即忘掉手动位置，下次回到自动定位
        removeToolOptions()
    }

    /// 工具子选项面板：框选/画笔/马赛克各自的样式选项，显示在主工具栏下方
    private func updateToolOptions(below main: NSRect) {
        guard let panel = makeOptions() else { removeToolOptions(); return }
        let h = optionsHost ?? NSHostingView(rootView: panel)
        h.rootView = panel
        if optionsHost == nil { addSubview(h); optionsHost = h }
        let size = h.fittingSize
        var y = main.minY - size.height - 6
        if y < 6 { y = main.maxY + 6 }
        var x = main.midX - size.width / 2
        x = max(8, min(x, bounds.width - size.width - 8))
        h.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
    private func removeToolOptions() { optionsHost?.removeFromSuperview(); optionsHost = nil }

    private func makeOptions() -> AnyView? {
        // 二次调参：已选中某标注时，参数条优先显示该组件当前样式，改动实时套用到它本身
        if let sel = selected {
            switch sel {
            case .box(let i) where boxes.indices.contains(i):
                let b = boxes[i]
                return AnyView(BoxOptionsBar(
                    shape: b.shape, dashed: b.dashed, highlight: b.highlight, colorHex: b.colorHex, lineWidth: b.lineWidth,
                    onShape: { [weak self] v in self?.updateSelectedBox { $0.shape = v } },
                    onDashed: { [weak self] v in self?.updateSelectedBox { $0.dashed = v } },
                    onHighlight: { [weak self] in self?.updateSelectedBox { $0.highlight.toggle() } },
                    onColor: { [weak self] v in self?.updateSelectedBox { $0.colorHex = v } },
                    onWidth: { [weak self] v in self?.updateSelectedBox { $0.lineWidth = v } }))
            case .arrow(let i) where arrows.indices.contains(i):
                let a = arrows[i]
                return AnyView(PenOptionsBar(
                    colorHex: a.colorHex, lineWidth: a.lineWidth,
                    onColor: { [weak self] v in self?.updateSelectedArrow { $0.colorHex = v } },
                    onWidth: { [weak self] v in self?.updateSelectedArrow { $0.lineWidth = v } }))
            case .text(let i) where texts.indices.contains(i):
                let t = texts[i]
                return AnyView(TextOptionsBar(
                    colorHex: t.colorHex, fontSize: t.fontSize,
                    onColor: { [weak self] v in self?.updateSelectedText { $0.colorHex = v } },
                    onSize: { [weak self] v in self?.updateSelectedText { $0.fontSize = v } }))
            case .shape(let i) where shapes.indices.contains(i):   // 吸附形状：颜色 + 粗细（复用画笔面板）
                let sh = shapes[i]
                return AnyView(PenOptionsBar(
                    colorHex: sh.colorHex, lineWidth: sh.lineWidth,
                    onColor: { [weak self] v in self?.updateSelectedShape { $0.colorHex = v } },
                    onWidth: { [weak self] v in self?.updateSelectedShape { $0.lineWidth = v } }))
            case .marker(let i) where markers.indices.contains(i):
                return AnyView(ColorOptionsBar(colorHex: markers[i].colorHex, onColor: { [weak self] in self?.applyNoteColor($0) }))
            case .step(let i) where steps.indices.contains(i):
                return AnyView(ColorOptionsBar(colorHex: steps[i].colorHex, onColor: { [weak self] in self?.applyFlowColor($0) }))
            default: break
            }
        }
        switch tool {
        case .box:
            // 工具态不显示灯泡：高亮已是一级工具；选中已有框时（上方 selected 分支）仍可切换
            return AnyView(BoxOptionsBar(
                shape: boxShape, dashed: boxDashed, highlight: false, colorHex: boxColorHex, lineWidth: boxLineWidth,
                showHighlight: false,
                onShape: { [weak self] in self?.boxShape = $0; self?.refreshToolbars() },
                onDashed: { [weak self] in self?.boxDashed = $0; self?.refreshToolbars() },
                onHighlight: {},
                onColor: { [weak self] in self?.boxColorHex = $0; self?.refreshToolbars() },
                onWidth: { [weak self] in self?.boxLineWidth = $0; self?.refreshToolbars() }))
        case .highlight:   // 高亮工具子选项：只有形状
            return AnyView(HighlightOptionsBar(
                shape: hlShape,
                onShape: { [weak self] in self?.hlShape = $0; self?.refreshToolbars() }))
        case .text:        // 文字工具子选项：颜色 + 字号
            return AnyView(TextOptionsBar(
                colorHex: textColorHex, fontSize: textFontSize,
                onColor: { [weak self] in self?.textColorHex = $0; self?.refreshToolbars() },
                onSize: { [weak self] in self?.textFontSize = $0; self?.refreshToolbars() }))
        case .pen:
            return AnyView(PenOptionsBar(
                colorHex: penColorHex, lineWidth: penLineWidth,
                onColor: { [weak self] in self?.penColorHex = $0; self?.refreshToolbars() },
                onWidth: { [weak self] in self?.penLineWidth = $0; self?.refreshToolbars() }))
        case .arrow:   // 箭头子选项：颜色 + 粗细（与画笔同一套面板）
            return AnyView(PenOptionsBar(
                colorHex: arrowColorHex, lineWidth: arrowLineWidth,
                onColor: { [weak self] in self?.arrowColorHex = $0; self?.refreshToolbars() },
                onWidth: { [weak self] in self?.arrowLineWidth = $0; self?.refreshToolbars() }))
        case .watermark:
            return AnyView(WatermarkOptionsBar(
                text: wmText, density: wmDensity, colorHex: wmColorHex, opacity: wmOpacity,
                onText: { [weak self] in self?.wmText = $0; self?.needsDisplay = true },   // 输入不重建面板，避免丢焦点
                onDensity: { [weak self] in self?.wmDensity = $0; self?.refreshToolbars() },
                onColor: { [weak self] in self?.wmColorHex = $0; self?.refreshToolbars() },
                onOpacity: { [weak self] in self?.wmOpacity = $0; self?.refreshToolbars() }))
        case .mosaic:
            return AnyView(MosaicOptionsBar(
                isBox: mosaicMode == .box, lineWidth: mosaicLineWidth,
                onMode: { [weak self] in self?.mosaicMode = $0 ? .box : .brush; self?.refreshToolbars() },
                onWidth: { [weak self] in self?.mosaicLineWidth = $0; self?.refreshToolbars() }))
        case .note:
            var cur = noteColorHex
            if case .marker(let i)? = selected, markers.indices.contains(i) { cur = markers[i].colorHex }
            return AnyView(ColorOptionsBar(colorHex: cur, onColor: { [weak self] in self?.applyNoteColor($0) }))
        case .flow:
            var cur = flowColorHex
            if case .step(let i)? = selected, steps.indices.contains(i) { cur = steps[i].colorHex }
            return AnyView(ColorOptionsBar(colorHex: cur, onColor: { [weak self] in self?.applyFlowColor($0) }))
        default:
            return nil
        }
    }
    private func refreshToolbars() {
        if let sel = selection { showToolbar(for: sel) }   // 重建面板反映新状态
        needsDisplay = true
    }

    /// 改色：有选中就改选中的那个组件，没选中才改「新建色」
    private func applyNoteColor(_ hex: String) {
        if case .marker(let i)? = selected, markers.indices.contains(i) { record(); markers[i].colorHex = hex }
        else { noteColorHex = hex }
        refreshToolbars()
    }
    private func applyFlowColor(_ hex: String) {
        if case .step(let i)? = selected, steps.indices.contains(i) { record(); steps[i].colorHex = hex }
        else { flowColorHex = hex }
        refreshToolbars()
    }

    private func makeToolbar() -> ScreenshotToolbar {
        let tTitle = translatedOverride == nil ? "翻译" : (showingOriginal ? "显示译文" : "显示原文")
        // 翻译按钮「按下」高亮：正在翻译，或译图在手且当前显示译文（切回原文则熄灭）
        let translateActive = translating || (translatedOverride != nil && !showingOriginal)
        return ScreenshotToolbar(
            boxActive: tool == .box, hlActive: tool == .highlight, textActive: tool == .text,
            penActive: tool == .pen,
            arrowActive: tool == .arrow,
            mosaicActive: tool == .mosaic, noteActive: tool == .note, flowActive: tool == .flow,
            wmActive: tool == .watermark,
            translateTitle: tTitle, translateActive: translateActive,
            onBox: { [weak self] in self?.toggleTool(.box) },
            onHighlightTool: { [weak self] in self?.toggleTool(.highlight) },
            onTextTool: { [weak self] in self?.toggleTool(.text) },
            onPen: { [weak self] in self?.toggleTool(.pen) },
            onArrow: { [weak self] in self?.toggleTool(.arrow) },
            onMosaic: { [weak self] in self?.toggleTool(.mosaic) },
            onNote: { [weak self] in self?.toggleTool(.note) },
            onFlow: { [weak self] in self?.toggleTool(.flow) },
            onWatermark: { [weak self] in self?.toggleTool(.watermark) },
            onUndo: { [weak self] in self?.undo() },
            onOCR: { [weak self] in self?.runOCR() },
            onLongShot: { [weak self] in self?.startLongShot() },
            onPin: { [weak self] in self?.pinSelection() },
            onAskAI: { [weak self] in self?.askAIWithSelection() },
            onTranslate: { [weak self] in self?.translateButtonTapped() },
            onSave: { [weak self] in self?.saveToDesktop() },
            onCopy: { [weak self] in self?.copyToClipboard() },
            onCancel: { [weak self] in self?.close() },
            onDragToolbar: { [weak self] in self?.dragToolbar(translation: $0, ended: $1) })
    }

    /// 钉在屏幕：把当前选区（含标注/译图）原位钉成置顶贴图，随后关闭覆盖层
    private func pinSelection() {
        guard let sel = selection, let img = compose() else { return }
        let global = NSRect(x: screen.frame.minX + sel.minX,
                            y: screen.frame.minY + sel.minY,
                            width: sel.width, height: sel.height)
        PinnedImageController.shared.pin(img, at: global)
        close()
    }

    /// 截图问 AI：把当前选区（含标注/译图）交给 AI 闪问作为附件，展开刘海等用户提问
    private func askAIWithSelection() {
        guard let img = compose() else { return }
        NotificationCenter.default.post(name: NSNotification.Name("ProNotchAskAIWithImage"), object: img)
        close()
    }

    private func toggleTool(_ t: Tool) {
        commitEditing()
        activeMarker = nil; markerGrab = nil
        tool = (tool == t) ? .none : t
        if let sel = selection { showToolbar(for: sel) }
        needsDisplay = true
    }

    // MARK: - 合成 / 输出

    /// 所有标注的并集包围盒（视图坐标，含线宽余量）；无标注返回 nil。
    /// 马赛克不计入——它只遮挡选区内内容，超出选区无意义（大梁老师明确）
    private func annotationsBounds() -> NSRect? {
        var r: NSRect?
        func add(_ rect: NSRect) { r = r.map { $0.union(rect) } ?? rect }
        for b in boxes {
            if b.rotation == 0 { add(b.rect) } else {
                // 旋转框：四角旋转后的包围盒
                let corners = [NSPoint(x: b.rect.minX, y: b.rect.minY), NSPoint(x: b.rect.maxX, y: b.rect.minY),
                               NSPoint(x: b.rect.minX, y: b.rect.maxY), NSPoint(x: b.rect.maxX, y: b.rect.maxY)]
                    .map { Self.rotatePoint($0, around: b.center, by: b.rotation) }
                let xs = corners.map(\.x), ys = corners.map(\.y)
                add(NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            }
        }
        for m in markers { add(m.box); if !m.text.isEmpty { add(m.textRect) } }
        for s in steps {
            add(NSRect(x: s.center.x - badgeRadius, y: s.center.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2))
            if !s.text.isEmpty { add(s.textRect) }
        }
        for a in arrows {
            add(NSRect(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y),
                       width: abs(a.end.x - a.start.x), height: abs(a.end.y - a.start.y)).insetBy(dx: -a.lineWidth * 2, dy: -a.lineWidth * 2))
        }
        for st in penStrokes { for p in st.points { add(NSRect(x: p.x - st.lineWidth, y: p.y - st.lineWidth, width: st.lineWidth * 2, height: st.lineWidth * 2)) } }
        for s in shapes { add(s.rect.insetBy(dx: -s.lineWidth, dy: -s.lineWidth)) }
        for t in texts where !t.text.isEmpty { add(t.rect) }
        return r
    }

    /// compose 实际输出范围（视图坐标）：贴图定位用，因为导出图会扩到含选区外标注
    private var lastComposeRect: NSRect?

    private func compose() -> NSImage? {
        commitEditing()
        guard let sel = selection else { return nil }
        // 导出范围 = 选区 ∪ 标注包围盒，裁到屏幕内 —— 超出选区的标注连同其背景一起保留在最终图
        var out = sel
        if let ab = annotationsBounds() { out = out.union(ab.insetBy(dx: -6, dy: -6)) }
        out = out.intersection(bounds)
        guard out.width >= 1, out.height >= 1 else { return nil }
        lastComposeRect = out
        let scale = screen.backingScaleFactor
        let crop = CGRect(x: out.minX * scale, y: (bounds.height - out.maxY) * scale,
                          width: out.width * scale, height: out.height * scale)
        guard let cropped = cgImage.cropping(to: crop) else { return nil }
        let outSize = out.size
        let result = NSImage(size: outSize)
        result.lockFocus()
        // 纯窗口吸附且真实形状已就绪：直接用窗口本体图（自带真实圆角、干净边缘、透明四角）。
        // 不走"整屏裁剪 + 遮罩"——整屏图里窗口的投影会在遮罩边缘透出一圈黑边
        let usedWindowShape = snappedWindowRect != nil && sel == snappedWindowRect
            && out == sel && snappedWindowImage != nil
        if usedWindowShape, let shape = snappedWindowImage {
            NSImage(cgImage: shape, size: outSize).draw(in: NSRect(origin: .zero, size: outSize))
        } else {
            NSImage(cgImage: cropped, size: outSize).draw(in: NSRect(origin: .zero, size: outSize))
        }
        let dx = -out.minX, dy = -out.minY
        // 译图（若有）只盖在选区那块位置
        if let t = translatedOverride, !showingOriginal {
            t.draw(in: NSRect(x: sel.minX + dx, y: sel.minY + dy, width: sel.width, height: sel.height))
        }
        drawMosaics(dx: dx, dy: dy)   // 马赛克：压在标注下
        let spots = boxes.filter { $0.highlight }
        if !spots.isEmpty {   // 聚光灯：离屏铺暗层再挖框，重叠区只挖不补、不反选
            let layer = NSImage(size: outSize)
            layer.lockFocus()
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: outSize)).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            for b in spots {
                let r = b.rect.offsetBy(dx: dx, dy: dy)
                let path = b.shape == .oval ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
                if b.rotation != 0 {   // 挖洞随框旋转
                    path.transform(using: Self.rotationTransform(b.rotation, around: NSPoint(x: r.midX, y: r.midY)))
                }
                path.fill()
            }
            layer.unlockFocus()
            layer.draw(in: NSRect(origin: .zero, size: outSize))
        }
        for b in boxes where !b.highlight {
            var bb = b; bb.rect = b.rect.offsetBy(dx: dx, dy: dy); drawBoxStyled(bb)
        }
        for m in markers {
            drawMarker(Marker(box: m.box.offsetBy(dx: dx, dy: dy),
                              textRect: m.textRect.offsetBy(dx: dx, dy: dy), text: m.text, colorHex: m.colorHex), editing: false)
        }
        for s in steps {
            var c = s.center; c.x += dx; c.y += dy
            drawStep(Step(center: c, number: s.number, textRect: s.textRect.offsetBy(dx: dx, dy: dy), text: s.text, colorHex: s.colorHex),
                     editingNumber: false, editingText: false)
        }
        drawPenStrokes(dx: dx, dy: dy)   // 画笔：最上层
        drawArrows(dx: dx, dy: dy)       // 箭头：与画笔同层
        drawTexts(dx: dx, dy: dy)        // 文字标注：与画笔同层
        drawWatermark(in: sel, dx: dx, dy: dy)   // 水印：铺在最上
        // 整窗吸附且导出范围恰为窗口本身（选区未被改动、无标注外扩）：挖掉圆角外四角，
        // 得到与系统截窗口一致的圆角图，不再把窗口背后的背景带进四角
        // 窗口吸附但真实形状未就绪（极快操作，兜底罕见）→ 固定圆角挖角，仍去掉直角背景
        if let wr = snappedWindowRect, sel == wr, out == sel, !usedWindowShape {
            let radius: CGFloat = 10
            let clip = NSBezierPath(rect: NSRect(origin: .zero, size: outSize))
            clip.append(NSBezierPath(roundedRect: NSRect(origin: .zero, size: outSize),
                                     xRadius: radius, yRadius: radius))
            clip.windingRule = .evenOdd
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            clip.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        result.unlockFocus()
        return result
    }

    private func copyToClipboard() {
        Task { @MainActor in
            await ensureWindowShape()
            guard let img = compose() else { close(); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
            close()
        }
    }

    /// 导出前确保窗口真实形状已就绪：吸附后立刻导出时，异步截图可能还没返回，这里同步补截一次
    private func ensureWindowShape() async {
        guard snappedWindowRect != nil, snappedWindowImage == nil, let id = snappedWindowID else { return }
        snappedWindowImage = await Self.captureWindow(id: id, scale: screen.backingScaleFactor)
    }

    private func saveToDesktop() {
        Task { @MainActor in
            await ensureWindowShape()
            // tiff→png 编码链的临时大 data 圈进池里，写盘即释放（不等 runloop 收尾）
            autoreleasepool {
                guard let img = compose(),
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop/截图 \(fmt.string(from: Date())).png")
                try? png.write(to: url)
            }
            close()
        }
    }

    // MARK: - 长截图（程序自动匀速滚动 + 逐帧拼接）

    /// 进入长截图：固定选区为视口，先选方向，再程序自动匀速滚动并逐帧拼接，滚到端自动停。
    private func startLongShot() {
        commitEditing()
        guard ocrPanel == nil, hintView == nil, !recordingLong else { return }   // OCR/翻译中或已在录制：忽略
        guard let sel = selection, sel.width > 24, sel.height > 80 else { return }
        guard AXPermission.ensure() else { return }   // 未授权：已弹系统授权框，本次不进入
        // 工具栏保持在场（选方向阶段还能反悔）；真正开始录制时才隐藏
        tool = .none; selected = nil; activeMarker = nil; markerGrab = nil
        longCaptureRect = sel
        longStretchRect = nil                  // 重置拉伸态
        recordingLong = true                   // 显示取景框（先不滚动）
        needsDisplay = true
        presentDirectionPicker(sel)            // 先选方向：向上 / 向下
    }

    /// 选定方向后真正开始：呈现控制条 + 扫描动画 + 穿透，启动滚动拼接
    private func beginLongShot(_ sel: NSRect, _ dir: LongShotDirection) {
        removeToolbar()                       // 录制开始，工具栏此刻才退场
        longDirPanel?.orderOut(nil); longDirPanel = nil
        longActive = true
        presentLongPanel()
        startScanAnimation()                  // 扫描取景条动画
        window?.ignoresMouseEvents = true     // 穿透，合成滚轮事件可达下面的 App
        Task { @MainActor in await runAutoScroll(sel, dir) }
    }

    /// 方向选择面板（浮在选区中央）
    private func presentDirectionPicker(_ sel: NSRect) {
        let bar = NSHostingView(rootView: LongShotDirectionBar(
            onUp:     { [weak self] in self?.beginLongShot(sel, .up) },
            onDown:   { [weak self] in self?.beginLongShot(sel, .down) },
            onCancel: { [weak self] in self?.cancelLongShot() }))
        let size = bar.fittingSize
        bar.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .screenSaver + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = bar
        let sf = screen.frame
        panel.setFrameOrigin(NSPoint(x: sf.minX + sel.midX - size.width / 2,
                                     y: sf.minY + sel.midY - size.height / 2))
        longDirPanel = panel
        panel.orderFrontRegardless()
    }

    /// 扫描取景条：~30fps 让取景条循环自上而下扫过，只重绘录制态
    private func startScanAnimation() {
        longScanTimer?.invalidate()
        longScanPhase = 0
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recordingLong else { return }
                self.longScanPhase += 0.014
                if self.longScanPhase > 1 { self.longScanPhase -= 1 }
                let box = self.longStretchRect ?? self.longCaptureRect   // 拉伸态按拉伸后的框重绘
                self.setNeedsDisplay(box.insetBy(dx: -3, dy: -3))   // 含红框，只重绘框区
            }
        }
        RunLoop.main.add(t, forMode: .common)
        longScanTimer = t
    }

    /// 补全：把选框从原位平滑拉伸到目标矩形（向下到视口底 / 向上到视口顶），给「截到端了」的明确感知
    private func animateBoxStretch(to target: NSRect) async {
        let s = longCaptureRect
        guard abs(target.height - s.height) > 1 else { longStretchRect = target; return }
        let dirty = s.union(target).insetBy(dx: -4, dy: -4)
        let steps = 26
        for i in 1...steps {
            guard recordingLong else { break }
            let t = CGFloat(i) / CGFloat(steps)
            let e = t * t * (3 - 2 * t)                // smoothstep 缓动
            longStretchRect = NSRect(x: s.minX + (target.minX - s.minX) * e, y: s.minY + (target.minY - s.minY) * e,
                                     width: s.width + (target.width - s.width) * e, height: s.height + (target.height - s.height) * e)
            setNeedsDisplay(dirty)
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        longStretchRect = target
        setNeedsDisplay(dirty)
    }

    /// 自动滚动主循环：移光标到选区中心 → 截首帧 → 循环(滚一格→截→拼)→ 滚到端自动停。dir 决定向上/向下。
    private func runAutoScroll(_ sel: NSRect, _ dir: LongShotDirection) async {
        guard await prepareLongCapture(sel) else { cancelLongShot(); return }
        let up = (dir == .up)
        warpCursorToSelectionCenter(sel)
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard longActive, let first = await captureLongFrame() else { cancelLongShot(); return }
        var dbg = 0                                              // 帧计数（驱动预览刷新频率）
        longStitcher = LongShotStitcher(firstFrame: first)
        let scale = screen.backingScaleFactor
        let stepPx = max(30, min(80, Int(sel.height * scale / 9)))      // 每步滚小一点 → 更顺、且给匹配更大余量
        let expDelta = max(1, Int(Double(stepPx) * scale))              // 首帧预期实际位移≈命令量×屏幕缩放
        // 滚轮方向自校准：合成滚动事件会被「自然滚动 / Mos 等反转工具」再翻一道，按钮的向上/向下
        // 就与实际相反。开滚前先滚一小段实测内容动向：反了就全程反向补偿；随后滚回原位干净起步。
        scrollWheelFlipped = false
        let probePt = max(16, stepPx / 2)
        scrollBy(pixels: probePt, up: up)
        try? await Task.sleep(nanoseconds: 250_000_000)
        if longActive, let probeFrame = await captureLongFrame() {
            let moved = longStitcher?.probeDirection(probeFrame) ?? 0   // +1=内容呈「向下滚」动向
            if moved != 0 {
                scrollBy(pixels: probePt, up: !up)                      // 物理反向撤销探测滚动，回到原位
                let expected = up ? -1 : 1
                if moved == -expected {
                    scrollWheelFlipped = true
                    print("[ProNotch] 检测到滚轮方向被反转（自然滚动/反转工具），已自动补偿")
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        var prevFrame = first
        var noMove = 0
        let boxPxH = Int(longCapturePx.height)
        let tallUpH = Int(longTallUpPx.height)
        // 补全延展到「目标窗口边」（含固定对话框/页头，不含 Dock/桌面）：下界=窗口下边，上界=窗口上边
        let viewportBottom = max(boxPxH, min(Int(longTallPx.height), Int(longWinBottomPx) - Int(longCapturePx.minY)))
        let viewportTop = max(0, min(tallUpH - boxPxH, Int(longWinTopPx)))
        // 选区的全局坐标（判断你有没有把鼠标移出去接管）
        let dispBounds = screen.displayID.map { CGDisplayBounds($0) } ?? screen.frame
        let globalSel = CGRect(x: dispBounds.minX + sel.minX, y: dispBounds.minY + (screen.frame.height - sel.maxY),
                               width: sel.width, height: sel.height)
        // 后台连续滚动：每 ~8ms 推一更小步，画面持续匀速滑动（暂停/到端由 longScrolling 控制；截取与滚动并行）
        let tickPx = max(2, stepPx / 9)
        longScrolling = true
        let scroller = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.longActive == true {
                if self?.longScrolling == true { self?.scrollBy(pixels: tickPx, up: up) }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        let cadence: TimeInterval = 0.11                         // 固定帧间隔留足余量 → δ 抖动更小、更稳
        var userPaused = false
        longSession?.phase = .scrolling
        while longActive {
            let cycleStart = Date()
            // 鼠标移出选区（多半要去点「停止」或自己操作）→ 暂停滚动、松手
            if let cur = CGEvent(source: nil)?.location, !globalSel.contains(cur) {
                if !userPaused { userPaused = true; longScrolling = false; longSession?.phase = .paused }
                try? await Task.sleep(nanoseconds: 180_000_000)
                continue
            }
            if userPaused {                                      // 鼠标移回 → 先 resync 接住漂移，再恢复滚动
                userPaused = false; noMove = 0; longSession?.phase = .scrolling
                if longActive, let f = await captureLongFrame() {
                    _ = up ? longStitcher?.prependFrame(f, expectedDelta: 0, resync: true)
                           : longStitcher?.addFrame(f, expectedDelta: 0, resync: true)
                    prevFrame = f
                    updateLongProgress(scale: scale)
                }
                longScrolling = true
                continue
            }
            if noMove > 0 { warpCursorForRetry(sel, attempt: noMove) }   // 疑似卡住 → 换落点，避开吞滚动的子元素
            if let frame = await captureLongFrame() {            // 即时快照（连续滚动中也清晰）
                // 停稳判定放后台线程，主线程(滚动)不被占用
                let pf = prevFrame
                let stable = await Task.detached(priority: .userInitiated) { Self.framesStable(pf, frame) }.value
                if stable {                                      // 连续推也纹丝不动 = 到端
                    noMove += 1
                    longSession?.phase = .confirming
                    if noMove >= 12 { break }                    // 持续没动 → 确实到端（连续滚已给懒加载时间）
                } else {
                    noMove = 0
                    longSession?.phase = .scrolling
                    dbg += 1
                    // 拼接(灰度+匹配+裁剪)放后台线程 → 滚动不被打断；await 串行化，无并发
                    if let st = longStitcher {
                        await Task.detached(priority: .userInitiated) {
                            _ = up ? st.prependFrame(frame, expectedDelta: expDelta) : st.addFrame(frame, expectedDelta: expDelta)
                        }.value
                    }
                    prevFrame = frame
                    if dbg % 2 == 0, let st = longStitcher {     // 预览生成(随段增长而变重)放后台线程
                        let cg = await Task.detached(priority: .utility) { st.previewImage(width: 150) }.value
                        longSession?.pointHeight = Int((CGFloat(st.totalHeight) / scale).rounded())
                        if let cg { longSession?.preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
                    }
                }
            }
            // 配速到固定 cadence：滚动在 await/sleep 间持续进行 → δ 稳定
            let used = Date().timeIntervalSince(cycleStart)
            if used < cadence { try? await Task.sleep(nanoseconds: UInt64((cadence - used) * 1_000_000_000)) }
        }
        longScrolling = false
        scroller.cancel()
        if longActive {
            if up {
                // 到顶：补「框上方 → 视口顶」头部 + 选框向上拉伸
                if viewportTop < tallUpH - boxPxH {
                    longSession?.phase = .finalizing
                    let targetTopY = screen.frame.height - CGFloat(viewportTop) / scale     // 视图坐标的框顶目标
                    let target = NSRect(x: longCaptureRect.minX, y: longCaptureRect.minY,
                                        width: longCaptureRect.width, height: targetTopY - longCaptureRect.minY)
                    await animateBoxStretch(to: target)
                    if let tall = await captureLongFrameTallUp() {
                        _ = longStitcher?.addHead(tall, viewportTop: viewportTop)
                        updateLongProgress(scale: scale)
                    }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            } else {
                // 到底：补「框下方 → 视口底」尾部 + 选框向下拉伸
                if viewportBottom > boxPxH {
                    longSession?.phase = .finalizing
                    let targetBottomY = longCaptureRect.maxY - CGFloat(viewportBottom) / scale
                    let target = NSRect(x: longCaptureRect.minX, y: targetBottomY,
                                        width: longCaptureRect.width, height: longCaptureRect.maxY - targetBottomY)
                    await animateBoxStretch(to: target)
                    if let tall = await captureLongFrameTall() {
                        _ = longStitcher?.addTail(tall, viewportBottom: viewportBottom)
                        updateLongProgress(scale: scale)
                    }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
            finishLongShot()                                     // 滚到端自动完成（取消时已置 false）
        }
    }

    /// 刷新控制条：已拼高度 + 实时长图预览（随截随长）
    private func updateLongProgress(scale: CGFloat) {
        guard let st = longStitcher else { return }
        longSession?.pointHeight = Int((CGFloat(st.totalHeight) / scale).rounded())
        if let cg = st.previewImage(width: 150) {
            longSession?.preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    nonisolated private static func framesStable(_ a: CGImage, _ b: CGImage) -> Bool {
        func sig(_ cg: CGImage) -> [UInt8]? {
            let s = 40
            guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: s, height: s))
            guard let d = ctx.data else { return nil }
            let p = d.bindMemory(to: UInt8.self, capacity: s * s)
            return Array(UnsafeBufferPointer(start: p, count: s * s))
        }
        guard let sa = sig(a), let sb = sig(b) else { return false }
        var t = 0; for i in 0..<sa.count { let v = Int(sa[i]) - Int(sb[i]); t += v < 0 ? -v : v }
        return t / sa.count < 4   // 平均差 <4 → 画面停稳
    }

    /// 构建捕获过滤器 + 配置（整屏，排除本覆盖层/控制条）、选区像素裁剪框
    private func prepareLongCapture(_ sel: NSRect) async -> Bool {
        guard let displayID = screen.displayID,
              let content = try? await SCShareableContent.current,
              let scd = content.displays.first(where: { $0.displayID == displayID }) else { return false }
        let mine = Set([window?.windowNumber, longPanel?.windowNumber].compactMap { $0 })
        let exclude = content.windows.filter { mine.contains(Int($0.windowID)) }
        let scale = screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(scd.width) * scale)
        cfg.height = Int(CGFloat(scd.height) * scale)
        cfg.showsCursor = false
        longFilter = SCContentFilter(display: scd, excludingWindows: exclude)
        longConfig = cfg
        longCapturePx = CGRect(x: (sel.minX * scale).rounded(.down),
                               y: ((bounds.height - sel.maxY) * scale).rounded(.down),
                               width: (sel.width * scale).rounded(.down),
                               height: (sel.height * scale).rounded(.down))
        // 同一列、从框顶一直伸到屏幕底：到底后补「框下方」尾部
        let screenPxH = CGFloat(scd.height) * scale
        longTallPx = CGRect(x: longCapturePx.minX, y: longCapturePx.minY,
                            width: longCapturePx.width,
                            height: max(longCapturePx.height, screenPxH - longCapturePx.minY))
        // 向上对称：同一列、从屏幕顶伸到框底（框在其底部），到顶后补「框上方」头部
        longTallUpPx = CGRect(x: longCapturePx.minX, y: 0,
                              width: longCapturePx.width,
                              height: max(longCapturePx.height, longCapturePx.maxY))
        // 目标 App 窗口边界：补全延展到「窗口边」——含固定对话框/页头，但不越过窗口外的 Dock/桌面。
        // 用 CGWindowList（明确左上全局坐标），只认最前面那个普通(layer 0)且含选区中心的 App 窗口；找不到则退到屏幕边。
        let b = CGDisplayBounds(displayID)
        let center = CGPoint(x: b.minX + sel.midX, y: b.minY + (bounds.height - sel.midY))   // 选区中心(CG 全局左上)
        var winFrame: CGRect?
        if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for info in infos {
                guard let num = info[kCGWindowNumber as String] as? Int, !mine.contains(num),
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let bd = info[kCGWindowBounds as String] as? NSDictionary,
                      let wf = CGRect(dictionaryRepresentation: bd), wf.width > 80, wf.height > 80,
                      wf.contains(center) else { continue }
                winFrame = wf; break                          // 最前面那个普通窗口 = 目标 App 窗口
            }
        }
        longWinTopPx = (((winFrame?.minY).map { max(b.minY, $0) } ?? b.minY) - b.minY) * scale
        longWinBottomPx = (((winFrame?.maxY).map { min(b.maxY, $0) } ?? b.maxY) - b.minY) * scale
        return true
    }

    private func captureLongFrame() async -> CGImage? {
        guard let f = longFilter, let c = longConfig,
              let full = try? await SCScreenshotManager.captureImage(contentFilter: f, configuration: c) else { return nil }
        return full.cropping(to: longCapturePx)
    }


    /// 捕获「框顶→屏底」的高帧（补尾部 / 探测视口底用）
    private func captureLongFrameTall() async -> CGImage? {
        guard let f = longFilter, let c = longConfig,
              let full = try? await SCScreenshotManager.captureImage(contentFilter: f, configuration: c) else { return nil }
        return full.cropping(to: longTallPx)
    }

    /// 捕获「屏顶→框底」的高帧（补头部 / 探测视口顶用）
    private func captureLongFrameTallUp() async -> CGImage? {
        guard let f = longFilter, let c = longConfig,
              let full = try? await SCScreenshotManager.captureImage(contentFilter: f, configuration: c) else { return nil }
        return full.cropping(to: longTallUpPx)
    }

    /// 把鼠标移到选区中心（合成滚轮事件作用于光标下的窗口）
    private func warpCursorToSelectionCenter(_ sel: NSRect) {
        guard let displayID = screen.displayID else { return }
        let b = CGDisplayBounds(displayID)
        let localTopY = screen.frame.height - sel.midY          // 视图左下原点 → 显示器左上原点
        CGWarpMouseCursorPosition(CGPoint(x: b.minX + sel.midX, y: b.minY + localTopY))
    }

    /// 卡住时换个落点再滚：横向轮播/内嵌滚动区会吞掉竖直滚轮，挪开光标即可命中页面主滚动。
    /// 候选点偏上、横向错开，避开页面中部常见的横向卡片区。
    private func warpCursorForRetry(_ sel: NSRect, attempt: Int) {
        guard let displayID = screen.displayID else { return }
        let b = CGDisplayBounds(displayID)
        let fracs: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.22, 0.18), (0.78, 0.18), (0.5, 0.82)]
        let (fx, fy) = fracs[max(0, attempt) % fracs.count]
        let px = sel.minX + sel.width * fx
        let py = sel.minY + sel.height * fy
        CGWarpMouseCursorPosition(CGPoint(x: b.minX + px, y: b.minY + (screen.frame.height - py)))
    }

    /// 合成滚动事件（像素单位，绕过加速、贴近 1:1）；up=true 向上、false 向下
    /// 合成滚轮事件（像素精确）。scrollWheelFlipped=true 时反向发送——
    /// 抵消「自然滚动 / Mos 等反转工具」对合成事件的二次翻转（每次开滚前实测校准）
    private func scrollBy(pixels: Int, up: Bool) {
        let u = scrollWheelFlipped ? !up : up
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: Int32(u ? pixels : -pixels), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }


    /// 确认/申请辅助功能权限（合成滚轮事件需要）
    /// 完成：停循环 → 取拼好的长图 → 进入「选择输出」态（带预览）
    private func finishLongShot() {
        longActive = false
        longScrolling = false
        recordingLong = false
        longScanTimer?.invalidate(); longScanTimer = nil   // 停扫描动画
        showLongResult(longStitcher?.result())
    }

    private func showLongResult(_ cg: CGImage?) {
        dismissLongInspector()                  // 暂停时若开着检视面板，出图后关掉换新内容
        guard let cg else { cleanupLongShot(); close(); return }
        longResultCG = cg
        longResultImg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        longFinished = true
        window?.ignoresMouseEvents = false      // 整屏压暗，等用户选输出
        needsDisplay = true
        let scale = screen.backingScaleFactor
        let sizeText = "\(Int((CGFloat(cg.width)/scale).rounded()))×\(Int((CGFloat(cg.height)/scale).rounded()))"
        let bar = NSHostingView(rootView: LongShotResultBar(
            sizeText: sizeText, preview: longResultImg,
            onInspect: { [weak self] in self?.toggleLongInspector() },
            onCopy: { [weak self] in self?.copyLongResult() },
            onSave: { [weak self] in self?.saveLongResult() },
            onDiscard: { [weak self] in self?.cleanupLongShot(); self?.close() }))
        swapLongBar(bar)
    }

    private func copyLongResult() {
        if let cg = longResultCG {
            let rep = NSBitmapImageRep(cgImage: cg)
            let img = NSImage(size: NSSize(width: cg.width, height: cg.height))
            img.addRepresentation(rep)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
        }
        cleanupLongShot(); close()
    }

    private func saveLongResult() {
        // 长截图整图的 png 编码临时 data 可达数百 MB，圈进池里写盘即释放
        autoreleasepool {
            if let cg = longResultCG, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop/长截图 \(fmt.string(from: Date())).png")
                try? png.write(to: url)
            }
        }
        cleanupLongShot(); close()
    }

    /// 把控制条面板换成另一块内容（录制条 → 输出选择条），并按尺寸重新居中到选区下方
    private func swapLongBar(_ bar: NSView) {
        guard let panel = longPanel else { return }
        let size = bar.fittingSize
        bar.frame = NSRect(origin: .zero, size: size)
        panel.contentView = bar
        let sf = screen.frame                                    // 带预览的输出条较大 → 居中屏幕
        let gx = sf.minX + (sf.width - size.width) / 2
        let gy = sf.minY + (sf.height - size.height) / 2
        panel.setFrame(NSRect(x: gx, y: gy, width: size.width, height: size.height), display: true)
    }

    private func cancelLongShot() {
        longActive = false
        recordingLong = false
        cleanupLongShot()
        close()
    }

    private func cleanupLongShot() {
        longScrolling = false
        longScanTimer?.invalidate(); longScanTimer = nil
        longStretchRect = nil
        dismissLongInspector()
        longDirPanel?.orderOut(nil); longDirPanel = nil
        longPanel?.orderOut(nil); longPanel = nil; longSession = nil
        longFinished = false; longResultCG = nil; longResultImg = nil
        longStitcher = nil; longFilter = nil; longConfig = nil
        window?.ignoresMouseEvents = false
    }

    /// 录制控制条：独立面板，浮在选区下方（覆盖层穿透时仍可点）
    private func presentLongPanel() {
        let session = LongShotSession(
            onFinish: { [weak self] in self?.finishLongShot() },
            onCancel: { [weak self] in self?.cancelLongShot() })
        longSession = session
        let bar = NSHostingView(rootView: LongShotControlBar(
            session: session,
            onInspect: { [weak self] in self?.toggleLongInspector() }))
        let size = bar.fittingSize
        bar.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .screenSaver + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = bar
        longPanel = panel
        repositionLongPanel()                                       // 放框附近（下方，没空间则上方）
        panel.orderFrontRegardless()
    }

    /// 双击预览 → 开/关长图检视面板：全宽适配 + 纵向滚动，放大确认拼接质量再决定保存。
    /// 仅暂停/出图后可用（滚动中鼠标一移到控制条上就已自动暂停）。
    private func toggleLongInspector() {
        if longInspectPanel != nil { dismissLongInspector(); return }
        if !longFinished, longScrolling { return }
        Task { @MainActor in
            var img: NSImage?
            if longFinished {
                img = longResultImg
            } else if let st = longStitcher {
                // 等在途的最后一拍拼接落定（暂停生效前可能有一帧在接），再取全分辨率结果
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let cg = await Task.detached(operation: { st.result() }).value {
                    img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            guard let image = img, image.size.width > 0, image.size.height > 0 else { return }
            self.presentLongInspector(image)
        }
    }

    private func presentLongInspector(_ image: NSImage) {
        dismissLongInspector()
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor
        let ptW = image.size.width / scale                       // 成图 size 按像素存，换回点显示 1:1 清晰
        let fitW = min(max(320, ptW), vf.width * 0.6)
        let headerH: CGFloat = 40
        let contentH = image.size.height / scale * (fitW / max(1, ptW)) + headerH
        let h = min(contentH, vf.height * 0.85)
        let host = NSHostingView(rootView: LongShotInspector(
            image: image, fitWidth: fitW,
            onClose: { [weak self] in self?.dismissLongInspector() }))
        host.frame = NSRect(x: 0, y: 0, width: fitW, height: h)
        let panel = NSPanel(contentRect: NSRect(x: vf.midX - fitW / 2, y: vf.midY - h / 2, width: fitW, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .screenSaver + 2                            // 压在控制条/结果条之上
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        panel.orderFrontRegardless()
        longInspectPanel = panel
    }

    private func dismissLongInspector() {
        longInspectPanel?.orderOut(nil)
        longInspectPanel = nil
    }

    /// 控制条定位：框右侧、垂直居中；右侧没空间（框贴近屏幕右缘）则放框左侧
    private func repositionLongPanel() {
        guard let panel = longPanel else { return }
        let size = panel.frame.size, sf = screen.frame, cr = longCaptureRect
        var gx = sf.minX + cr.maxX + 14
        if gx + size.width > sf.maxX - 8 { gx = sf.minX + cr.minX - size.width - 14 }   // 右侧放不下 → 左侧
        gx = max(sf.minX + 8, min(gx, sf.maxX - size.width - 8))
        var gy = sf.minY + cr.midY - size.height / 2
        gy = max(sf.minY + 8, min(gy, sf.maxY - size.height - 8))
        panel.setFrameOrigin(NSPoint(x: gx, y: gy))
    }

    // MARK: - OCR 文字提取（Apple Vision，本地离线，中英文）

    private func runOCR() {
        commitEditing()
        guard ocrPanel == nil, !translating, !recordingLong else { return }   // 防重入/翻译进行中/长截图互斥
        removeHint()   // 清掉可能残留的「翻译失败/没内容」提示气泡——否则它把 OCR 锁死到 2.8s 后自动消失
        guard let sel = selection else { return }
        let scale = screen.backingScaleFactor
        let crop = CGRect(x: sel.minX * scale, y: (bounds.height - sel.maxY) * scale,
                          width: sel.width * scale, height: sel.height * scale)
        guard let cropped = cgImage.cropping(to: crop) else { return }
        // 工具栏保持在场，识别结果面板浮在选区中央
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.recognize(cropped)
            DispatchQueue.main.async { [weak self] in self?.showOCRPanel(text) }
        }
    }

    private static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 自动语言检测：日/韩/俄等非中英文字也能识别（翻译日文截图的前提）；语言表仅作偏好提示
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let obs = request.results ?? []
        // 按阅读顺序排：上方在前（y 大），同一行内左侧在前
        let sorted = obs.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.012 { return a.boundingBox.midY > b.boundingBox.midY }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func showOCRPanel(_ text: String) {
        let panel = OCRResultPanel(
            text: text,
            onCopy: { [weak self] t in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
                self?.close()
            },
            onClose: { [weak self] in self?.dismissOCRPanel() },
            onTranslate: { [weak self] t, done in self?.translateOCRText(t, done) })
        let host = NSHostingView(rootView: panel)
        let size = host.fittingSize
        host.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
        addSubview(host)
        ocrPanel = host
        window?.makeFirstResponder(host)
    }

    private func dismissOCRPanel() {
        ocrPanel?.removeFromSuperview(); ocrPanel = nil
        if let sel = selection { showToolbar(for: sel) }
    }

    /// OCR 面板的「翻译」：按行拆分送翻（空行原样保留、行数对应），引擎与截图翻译同一套
    /// （系统翻译优先、失败降级 AI），译完整体回填编辑框；失败回调 nil 由面板显示提示
    private func translateOCRText(_ text: String, _ done: @escaping (String?) -> Void) {
        guard let (config, lang, prompt) = translateProvider() else { done(nil); return }
        let aiReady = !config.baseURL.isEmpty && !config.apiKey.isEmpty && !config.model.isEmpty
        let useSystem = config.useSystemEngine && SystemTranslator.isSupported
        guard useSystem || aiReady else { done(nil); return }
        let lines = text.components(separatedBy: "\n")
        let idx = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let src = idx.map { lines[$0] }
        guard !src.isEmpty else { done(nil); return }
        Task {
            var out: [String]?
            if useSystem { out = try? await SystemTranslator.translate(src, targetLang: lang) }
            if out == nil, aiReady {
                out = try? await ScreenshotTranslator.translate(src, to: lang, prompt: prompt, config: config)
            }
            await MainActor.run {
                guard let out, out.count == src.count else { done(nil); return }
                var res = lines
                for (k, i) in idx.enumerated() where !out[k].isEmpty { res[i] = out[k] }
                done(res.joined(separator: "\n"))
            }
        }
    }

    // MARK: - 翻译（原位叠加：盖住原文 + 写译文）

    private func runTranslate() {
        commitEditing()
        // 只在翻译进行中拦（防重入）；失败/没内容提示气泡还在也允许重试——showHint("翻译中…") 会替换掉旧气泡
        guard ocrPanel == nil, !translating, !recordingLong, let sel = selection else { return }
        guard let (config, lang, prompt) = translateProvider() else { return }
        let aiReady = !config.baseURL.isEmpty && !config.apiKey.isEmpty && !config.model.isEmpty
        let useSystem = config.useSystemEngine && SystemTranslator.isSupported
        guard useSystem || aiReady else {
            showHint("翻译接口未配置（去设置→超级截图→翻译）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.removeHint(); if let s = self?.selection { self?.showToolbar(for: s) }
            }
            return
        }
        let scale = screen.backingScaleFactor
        let crop = CGRect(x: sel.minX * scale, y: (bounds.height - sel.maxY) * scale,
                          width: sel.width * scale, height: sel.height * scale)
        guard let cropped = cgImage.cropping(to: crop) else { return }
        // 工具栏保持在场；翻译中的动效提示浮在选区中央。翻译按钮即刻进入「按下」高亮态
        showHint("翻译中…", spinning: true)
        translating = true
        showToolbar(for: sel)
        let outSize = sel.size
        translatePartial = nil
        Task {
            let blocks = Self.recognizeBlocks(cropped)
            if blocks.isEmpty { await MainActor.run { self.translateFailed("未识别到文字") }; return }
            let targetIsCJK = ["zh", "ja", "ko"].contains { SystemTranslator.languageCode(for: lang).hasPrefix($0) }
            // 只抠出每块里「非目标语言」的片段送翻（中文页面就是抠英文/标识符），中文原样保留、译文就地填回。
            // 送翻量从「整块中文长句」骤降到「零星英文短词」——AI 秒回不再超时，系统翻译也不再中译中被拒。
            let blockFrags = blocks.map { Self.translatableFragments(in: $0.text, targetIsCJK: targetIsCJK) }
            var uniqueList: [String] = []
            var seen = Set<String>()
            for frags in blockFrags {
                for f in frags where !seen.contains(f.text) { seen.insert(f.text); uniqueList.append(f.text) }
            }
            guard !uniqueList.isEmpty else {
                await MainActor.run { self.translateFailed("没有需要翻译的内容") }
                return
            }
            // 首选系统翻译（本机离线毫秒级）；失败（语言包未装等）静默降级到 AI
            if useSystem {
                do {
                    let trans = try await SystemTranslator.translate(uniqueList, targetLang: lang)
                    await MainActor.run {
                        let img = Self.renderFragments(base: cropped, size: outSize, blocks: blocks,
                                                       blockFrags: blockFrags, uniqueList: uniqueList, partial: trans)
                        self.translateDone(img)
                    }
                    return
                } catch {
                    guard aiReady else {
                        await MainActor.run { self.translateFailed(error.localizedDescription) }
                        return
                    }
                }
            }
            do {
                let trans = try await ScreenshotTranslator.translate(
                    uniqueList, to: lang, prompt: prompt, config: config,
                    onPartial: { [weak self] range, chunk, done, total in
                        // 渐进渲染：哪个片段先译完先就地填回哪个，不等全部译完
                        Task { @MainActor in
                            guard let self, self.hintView != nil else { return }   // 已完成/已关闭则忽略迟到片段
                            var acc = self.translatePartial ?? [String](repeating: "", count: uniqueList.count)
                            if chunk.count == range.count {
                                for (k, i) in range.enumerated() { acc[i] = chunk[k] }
                            }
                            self.translatePartial = acc
                            if total > 1 { self.showHint("翻译中… \(done)/\(total)", spinning: true) }
                            self.translatedOverride = Self.renderFragments(base: cropped, size: outSize, blocks: blocks,
                                                                           blockFrags: blockFrags, uniqueList: uniqueList, partial: acc)
                            self.showingOriginal = false
                            self.needsDisplay = true
                        }
                    })
                await MainActor.run {
                    let img = Self.renderFragments(base: cropped, size: outSize, blocks: blocks,
                                                   blockFrags: blockFrags, uniqueList: uniqueList, partial: trans)
                    self.translateDone(img)
                }
            } catch {
                await MainActor.run { self.translateFailed(error.localizedDescription) }
            }
        }
    }

    /// 产品/品牌/技术名白名单（小写匹配）：全小写写法(deepseek/python)与普通英文词字面无法区分，
    /// 靠白名单兜底保留。正确大小写的产品名(DeepSeek/GitHub/macOS)已被下面的驼峰/全大写规则保留，
    /// 这里主要补全小写与首字母大写写法。遇到漏网的冷门名字往这里加即可。
    nonisolated private static let brandKeep: Set<String> = [
        "deepseek", "openai", "chatgpt", "gpt", "anthropic", "claude", "gemini", "copilot", "llama", "mistral",
        "github", "gitlab", "google", "apple", "microsoft", "amazon", "azure", "aws", "nvidia", "intel", "amd",
        "openrouter", "ollama", "docker", "kubernetes", "redis", "nginx", "linux", "ubuntu", "macos", "ios",
        "ipados", "android", "windows", "chrome", "safari", "firefox", "python", "swift", "swiftui", "java",
        "javascript", "typescript", "kotlin", "rust", "golang", "react", "vue", "angular", "nodejs", "deno",
        "npm", "figma", "notion", "slack", "discord", "telegram", "wechat", "xcode", "vscode", "vercel",
    ]

    /// 拉丁片段是否需要翻译。逐词分两类：保留词＝白名单产品名 / 驼峰标识符 / 下划线 / 全大写缩写；
    /// 普通英文词＝其余（单字母 a、I 忽略）。规则：
    /// - 纯普通英文（无保留词）→ 翻（helper、Read a file）；
    /// - 含保留词时，普通词≥2 视为「自然语言句子里嵌了产品名」→ 整句送翻，产品名交翻译引擎按语义保留
    ///   （如 "Here is your GitHub sudo authentication code"）；普通词≤1 视为代码/标识符 → 整体保留
    ///   （如 "import NaturalLanguage"）。
    nonisolated private static func latinFragNeedsTranslation(_ frag: String) -> Bool {
        let f = frag.trimmingCharacters(in: .whitespaces)
        guard f.count >= 2 else { return false }
        var plain = 0, reserved = 0
        for word in f.split(separator: " ") {
            let w = String(word)
            if w.count < 2 { continue }                                                  // 单字母(a/I)忽略
            if brandKeep.contains(w.lowercased())                                         // 产品/品牌/技术名
                || w.contains("_")                                                       // snake_case
                || w.range(of: "^[A-Z]{2,}$", options: .regularExpression) != nil        // 全大写缩写/常量
                || Array(w).dropFirst().contains(where: { $0.isUppercase }) {            // 驼峰
                reserved += 1
            } else {
                plain += 1
            }
        }
        return reserved == 0 ? plain >= 1 : plain >= 2
    }

    /// 从块文本里抠出「非目标语言」的待翻片段（位置+原文）。目标是 CJK（中/日/韩）→ 抠拉丁片段
    /// （标识符/英文短语，如 "import NaturalLanguage"、"status=200"），产品名/缩写/代码值按上面规则保留；
    /// 目标是拉丁语言 → 抠连续 CJK 片段。只送这些片段、不送整块——避免中文长句拖慢/中译中被拒。
    nonisolated private static func translatableFragments(in text: String, targetIsCJK: Bool) -> [(range: NSRange, text: String)] {
        // 拉丁分支只抠「纯字母词／空格连接的字母短语」（import NaturalLanguage、Read a file、looksTranslatable）；
        // 含数字的代码值/版本号（status=200、v1.6.0）不匹配此模式，天然留在原文——再靠「紧邻的下一字符是数字或 =」
        // 兜掉 status 这种「字母紧贴代码值」的前缀，避免把 status 单独抠去翻成「状态=200」。
        let pattern = targetIsCJK
            ? "[A-Za-z]+(?: [A-Za-z]+)*"
            : "[\\x{4E00}-\\x{9FFF}\\x{3400}-\\x{4DBF}\\x{3040}-\\x{30FF}\\x{AC00}-\\x{D7A3}]+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var result: [(range: NSRange, text: String)] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            if targetIsCJK {                                   // 下一字符是数字或 = → 这是代码值前缀，跳过
                let end = m.range.location + m.range.length
                if end < ns.length {
                    let next = ns.substring(with: NSRange(location: end, length: 1))
                    if next == "=" || next.range(of: "^[0-9]$", options: .regularExpression) != nil { return }
                }
            }
            let frag = ns.substring(with: m.range)
            if !targetIsCJK || latinFragNeedsTranslation(frag) { result.append((range: m.range, text: frag)) }
        }
        return result
    }

    /// 把块内片段按译文就地替换（从后往前，避免前面替换改变后面片段的位置），中文与保留项原样不动
    nonisolated private static func applyFragments(_ text: String,
        _ frags: [(range: NSRange, text: String)], _ map: [String: String]) -> String {
        let ms = NSMutableString(string: text)
        for f in frags.reversed() {
            guard let tr = map[f.text], !tr.isEmpty, tr != f.text else { continue }
            ms.replaceCharacters(in: f.range, with: tr)
        }
        return ms as String
    }

    /// 按当前（部分）译文把各块的英文片段就地替换后整体渲染（走主线程，与 renderTranslated 同隔离）
    private static func renderFragments(base: CGImage, size: NSSize,
        blocks: [(text: String, box: CGRect)], blockFrags: [[(range: NSRange, text: String)]],
        uniqueList: [String], partial: [String]) -> NSImage {
        var map: [String: String] = [:]
        for (k, t) in uniqueList.enumerated() where k < partial.count && !partial[k].isEmpty { map[t] = partial[k] }
        let full = zip(blocks, blockFrags).map { applyFragments($0.0.text, $0.1, map) }
        return renderTranslated(base: base, size: size, blocks: blocks, translations: full)
    }

    private func translateDone(_ img: NSImage) {
        removeHint()
        translating = false
        translatePartial = nil
        translatedOverride = img
        showingOriginal = false
        if let sel = selection { showToolbar(for: sel) }
        needsDisplay = true
    }

    /// 工具栏「翻译/显示原文/显示译文」统一入口：首次调 API，之后只切换缓存、不再请求
    private func translateButtonTapped() {
        if translatedOverride == nil {
            runTranslate()
        } else {
            showingOriginal.toggle()
            if let sel = selection { showToolbar(for: sel) }   // 刷新按钮文字
            needsDisplay = true
        }
    }

    private func translateFailed(_ msg: String) {
        translating = false
        translatePartial = nil
        translatedOverride = nil   // 全部失败：不留半成品译图
        showHint("翻译失败：\(msg)")
        if let sel = selection { showToolbar(for: sel) }   // 翻译按钮即刻熄灭
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            self?.removeHint(); if let s = self?.selection { self?.showToolbar(for: s) }
        }
    }

    private func showHint(_ text: String, spinning: Bool = false) {
        // 同形态提示已在场：只改文字（进度 n/m 刷新时转圈不重启、气泡不闪）
        if let label = hintLabel, hintView != nil, hintSpinning == spinning {
            label.stringValue = text
            label.sizeToFit()
            layoutHint(label)
            return
        }
        removeHint()
        hintSpinning = spinning
        let dark = ToolbarChrome.dark                          // 气泡跟随系统深浅色
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = dark ? .white : NSColor.black.withAlphaComponent(0.85)
        label.sizeToFit()
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.85)
                                            : NSColor.white).cgColor
        host.layer?.cornerRadius = 8
        if spinning {   // 翻译中：小转圈，让人一眼看出「在干活」而不是卡死
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isIndeterminate = true
            spin.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)   // 随底色渲染深/浅
            spin.sizeToFit()
            spin.startAnimation(nil)
            host.addSubview(spin)
        }
        host.addSubview(label)
        addSubview(host)
        hintView = host
        hintLabel = label
        layoutHint(label)
    }

    /// 排版提示气泡：转圈(如有)+文字横排，气泡随文字宽度自适应、定位在选区中央
    private func layoutHint(_ label: NSTextField) {
        guard let host = hintView else { return }
        let spinner = host.subviews.first { $0 is NSProgressIndicator }
        let spinW: CGFloat = spinner.map { $0.frame.width + 8 } ?? 0
        let w = label.frame.width + spinW + 28
        let h = max(label.frame.height, spinner?.frame.height ?? 0) + 18
        let cx = selection?.midX ?? bounds.midX, cy = selection?.midY ?? bounds.midY   // 提示落在选区中央
        host.frame = NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        spinner?.setFrameOrigin(NSPoint(x: 14, y: (h - (spinner?.frame.height ?? 0)) / 2))
        label.setFrameOrigin(NSPoint(x: 14 + spinW, y: (h - label.frame.height) / 2))
    }

    private func removeHint() { hintView?.removeFromSuperview(); hintView = nil; hintLabel = nil }

    private static func recognizeBlocks(_ image: CGImage) -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 自动语言检测：日/韩/俄等非中英文字也能识别（翻译日文截图的前提）；语言表仅作偏好提示
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let obs = request.results ?? []
        return obs.compactMap { o in
            guard let t = o.topCandidates(1).first?.string, !t.isEmpty else { return nil }
            return (t, o.boundingBox)
        }
    }

    private static func renderTranslated(base: CGImage, size: NSSize,
                                         blocks: [(text: String, box: CGRect)], translations: [String]) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSImage(cgImage: base, size: size).draw(in: NSRect(origin: .zero, size: size))   // 原图作底，背景原样保留
        for (i, b) in blocks.enumerated() {
            guard i < translations.count, !translations[i].isEmpty else { continue }
            let rect = NSRect(x: b.box.minX * size.width, y: b.box.minY * size.height,
                              width: b.box.width * size.width, height: b.box.height * size.height)
            let bg = dominantBg(base, b.box)         // 框内众数色＝真实背景，纯色背景下填充块完全融入、不露框
            bg.setFill()
            NSBezierPath(rect: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
            drawFitted(translations[i], in: rect, textColor: textColor(base, b.box, bg: bg))
        }
        img.unlockFocus()
        return img
    }

    private static func drawFitted(_ text: String, in rect: NSRect, textColor: NSColor) {
        var fs = max(12, rect.height)                      // 贴合原文高度
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs), .foregroundColor: textColor]
        let w = (text as NSString).size(withAttributes: attrs).width
        if w > rect.width, w > 0 {
            fs = max(rect.height * 0.62, fs * rect.width / w)   // 太宽才缩，且保底不至于太小
            attrs[.font] = NSFont.systemFont(ofSize: fs)
        }
        let th = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.midY - th / 2), withAttributes: attrs)
    }

    /// 文字框的真实背景色：把框内像素量化做直方图，取出现最多的颜色簇（文字笔画只占少数像素、
    /// 背景占多数，所以众数簇＝背景），再对该簇求真实均值得到精确背景色。
    /// 比采样行间窄缝更稳——不依赖缝里恰好是纯背景，纯色背景下填充块能完全融入、不露框。
    private static func dominantBg(_ image: CGImage, _ box: CGRect) -> NSColor {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let px = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H).integral
        let clip = px.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !clip.isNull, let crop = image.cropping(to: clip) else { return .white }
        let gw = max(1, min(72, Int(clip.width))), gh = max(1, min(36, Int(clip.height)))
        var buf = [UInt8](repeating: 0, count: gw * gh * 4)
        guard let ctx = CGContext(data: &buf, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        // 量化到 16 级/通道做直方图，定位背景颜色簇
        var hist = [Int: Int]()
        for i in stride(from: 0, to: buf.count, by: 4) {
            let key = ((Int(buf[i]) >> 4) << 8) | ((Int(buf[i + 1]) >> 4) << 4) | (Int(buf[i + 2]) >> 4)
            hist[key, default: 0] += 1
        }
        guard let best = hist.max(by: { $0.value < $1.value })?.key else { return .white }
        // 对落在众数簇里的像素求真实均值 → 精确背景色
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, n: CGFloat = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let key = ((Int(buf[i]) >> 4) << 8) | ((Int(buf[i + 1]) >> 4) << 4) | (Int(buf[i + 2]) >> 4)
            if key == best { sr += CGFloat(buf[i]); sg += CGFloat(buf[i + 1]); sb += CGFloat(buf[i + 2]); n += 1 }
        }
        guard n > 0 else { return .white }
        return NSColor(red: sr / n / 255, green: sg / n / 255, blue: sb / n / 255, alpha: 1)
    }

    /// 原文字色：读框内像素，取和背景差异大的（文字）像素的平均色；找不到则退回对比色
    private static func textColor(_ image: CGImage, _ box: CGRect, bg: NSColor) -> NSColor {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let px = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H).integral
        let clip = px.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !clip.isNull, let crop = image.cropping(to: clip) else { return contrast(bg) }
        let gw = max(1, min(48, Int(clip.width))), gh = max(1, min(20, Int(clip.height)))
        var buf = [UInt8](repeating: 0, count: gw * gh * 4)
        guard let ctx = CGContext(data: &buf, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return contrast(bg) }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        let c = bg.usingColorSpace(.deviceRGB) ?? bg
        let br = c.redComponent, bgreen = c.greenComponent, bb = c.blueComponent
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, cnt: CGFloat = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = CGFloat(buf[i]) / 255, g = CGFloat(buf[i + 1]) / 255, b = CGFloat(buf[i + 2]) / 255
            if abs(r - br) + abs(g - bgreen) + abs(b - bb) > 0.35 { sr += r; sg += g; sb += b; cnt += 1 }
        }
        guard cnt > 0 else { return contrast(bg) }
        return NSColor(red: sr / cnt, green: sg / cnt, blue: sb / cnt, alpha: 1)
    }
    private static func contrast(_ bg: NSColor) -> NSColor { bg.luma < 0.5 ? .white : .black }

    private func close() { removeHint(); removeToolbar(); onClose() }
}

/// 标注说明的多行输入框（NSTextView）：原生 textContainerInset 内边距、layoutManager 多行排版，
/// 编辑态留白与换行都精确生效、不吞字；空文字时在文字起点画占位符（位置与正文一致）
final class AnnotationTextView: NSTextView {
    var placeholder = ""
    var placeholderAttrs: [NSAttributedString.Key: Any] = [:]
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let p = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                        y: textContainerInset.height)
        (placeholder as NSString).draw(at: p, withAttributes: placeholderAttrs)
    }
}
