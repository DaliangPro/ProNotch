import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit
import SwiftUI
import Vision

/// 超级截图：先用 ScreenCaptureKit 截下光标所在整屏，铺一层压暗覆盖层，
/// 拖拽框选露出原图，松手弹工具栏（框选 / 备注 / 流程 / 存桌面 / 复制）。
@MainActor
final class SuperScreenshotController {
    static let shared = SuperScreenshotController()
    weak var settings: SettingsStore?   // AppDelegate 注入，翻译时惰性读配置
    private var window: ScreenshotOverlayWindow?
    private var busy = false

    func capture() {
        guard !busy, window == nil else { return }   // 防重入：覆盖层已在或正在截
        busy = true
        Task {
            defer { busy = false }
            guard let (image, screen) = await Self.grabActiveDisplay() else { return }
            self.present(image, on: screen)
        }
    }

    private func present(_ image: CGImage, on screen: NSScreen) {
        // 翻译配置 provider：点「翻译」时才调用（此刻才读钥匙串，不在截图时读）
        let provider: () -> (ScreenshotTranslator.Config, String, String)? = { [weak self] in
            guard let s = self?.settings else { return nil }
            let c = s.resolvedTranslateConfig
            return (.init(baseURL: c.baseURL, apiKey: c.apiKey, model: c.model,
                          parallel: s.translateParallel,
                          useSystemEngine: s.translateEngine == "system"),
                    s.translateTargetLang, s.translatePrompt)
        }
        let win = ScreenshotOverlayWindow(image: image, screen: screen, translateProvider: provider) { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        }
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 截下光标所在显示器的整屏（像素级，不含光标）
    private static func grabActiveDisplay() async -> (CGImage, NSScreen)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.displayID else { return nil }
        do {
            let content = try await SCShareableContent.current
            guard let scd = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(scd.width) * screen.backingScaleFactor)
            cfg.height = Int(CGFloat(scd.height) * screen.backingScaleFactor)
            cfg.showsCursor = false
            let filter = SCContentFilter(display: scd, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return (image, screen)
        } catch {
            print("[ProNotch] 超级截图捕获失败: \(error.localizedDescription)")
            return nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension NSColor {
    var luma: CGFloat {
        let c = usingColorSpace(.deviceRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

/// 调 OpenAI 兼容接口批量翻译（JSON 数组进出，保证 N→N 对应）
enum ScreenshotTranslator {
    struct Config {
        var baseURL: String; var apiKey: String; var model: String
        var parallel: Bool = true
        var useSystemEngine: Bool = false   // true=优先系统翻译（失败降级到本 AI 配置）
    }

    /// 分块并行翻译：按字数把条目切成连续块并发请求（上限 5 路）——模型逐 token 串行生成，
    /// 全文一次请求耗时随字数线性涨；并行后总耗时≈最慢一块。哪块先译完先经 onPartial 回传
    /// （渐进渲染用）；疑似未翻译只重试该块；失败块以空串占位（渲染时跳过=保留原文画面）。
    /// 仅当所有块都失败才抛错。
    static func translate(_ texts: [String], to lang: String, prompt: String, config: Config,
                          onPartial: (@Sendable (_ range: Range<Int>, _ chunk: [String], _ done: Int, _ total: Int) -> Void)? = nil) async throws -> [String] {
        // 提示词里的 {lang} 占位替换为目标语言；用户没留 {lang} 时按原样使用
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SettingsStore.defaultTranslatePrompt : prompt
        let system = raw.replacingOccurrences(of: "{lang}", with: lang)
        // 并行开关关闭（接口限流严）或文字少：单请求，无拆分开销
        let ranges = config.parallel ? chunkRanges(texts, budget: 400) : [0..<texts.count]
        guard ranges.count > 1 else {
            let out = try await translateChunk(texts, to: lang, system: system, config: config)
            onPartial?(0..<texts.count, out, 1, 1)
            return out
        }
        var results = [String](repeating: "", count: texts.count)
        var okCount = 0, done = 0
        var firstError: Error?
        await withTaskGroup(of: (Range<Int>, Result<[String], Error>).self) { group in
            var next = 0
            func launchNext() {
                guard next < ranges.count else { return }
                let r = ranges[next]; next += 1
                group.addTask {
                    do { return (r, .success(try await translateChunk(Array(texts[r]), to: lang, system: system, config: config))) }
                    catch { return (r, .failure(error)) }
                }
            }
            for _ in 0..<min(5, ranges.count) { launchNext() }   // 并发上限 5，防接口限流
            for await (r, res) in group {
                launchNext()   // 完成一块补发一块，保持并发水位
                done += 1
                switch res {
                case .success(let out) where out.count == r.count:
                    for (k, i) in r.enumerated() { results[i] = out[k] }
                    okCount += 1
                    onPartial?(r, out, done, ranges.count)
                case .success, .failure:   // 失败或条数错位：该块空占位（渲染跳过=保留原文），只报进度
                    if case .failure(let e) = res, firstError == nil { firstError = e }
                    onPartial?(r, [], done, ranges.count)
                }
            }
        }
        guard okCount > 0 else { throw firstError ?? err("翻译失败") }
        return results
    }

    /// 单块翻译：首轮整块请求 → 逐条核对，把「没回来的 / 原样回传但明显该翻的」单独小批补翻一次。
    /// 旧逻辑「过半未翻才整块重试」兜不住零散漏翻（模型只漏两三条时不达阈值，漏了就漏了）——
    /// 逐条核对后哪怕只漏一条也会补翻；补翻仍原样回传的视为专名/代号，保留不再纠缠。
    private static func translateChunk(_ texts: [String], to lang: String, system: String, config: Config) async throws -> [String] {
        var out = try await request(texts, system: system, temperature: 0.2, config: config)
        // 条数对不上（长输出被截断/丢尾条）：多则裁、少则空串占位，缺的交给下面按条补翻
        if out.count > texts.count { out = Array(out.prefix(texts.count)) }
        while out.count < texts.count { out.append("") }
        let suspects = texts.indices.filter { i in
            let o = out[i].trimmingCharacters(in: .whitespaces)
            return o.isEmpty || (o == texts[i].trimmingCharacters(in: .whitespaces) && looksTranslatable(texts[i]))
        }
        guard !suspects.isEmpty else { return out }
        let harder = system + "\n\nThe previous attempt returned these strings unchanged or dropped them, which is WRONG. "
            + "You MUST translate every non-\(lang) string into \(lang) now. Never echo the input."
        if let fix = try? await request(suspects.map { texts[$0] }, system: harder, temperature: 0.5, config: config),
           fix.count == suspects.count {
            for (k, i) in suspects.enumerated() {
                let f = fix[k].trimmingCharacters(in: .whitespacesAndNewlines)
                if !f.isEmpty { out[i] = f }
            }
        }
        return out
    }

    /// 这串文字「看起来该被翻译」：含拉丁词、字母占比可观，且不是 URL/路径——
    /// 纯数字、时间、代码符号原样回传是对的，不算漏翻
    private static func looksTranslatable(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("www.") || lower.hasPrefix("/") || lower.hasPrefix("~/") { return false }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 3, Double(letters) / Double(t.count) > 0.4 else { return false }
        return t.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
    }

    /// 按累计字数（约 budget 字符）切成连续区间，至少 1 条/块——块内保持阅读顺序上下文
    private static func chunkRanges(_ texts: [String], budget: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0, chars = 0
        for (i, t) in texts.enumerated() {
            if i > start, chars + t.count > budget { ranges.append(start..<i); start = i; chars = 0 }
            chars += t.count
        }
        if start < texts.count { ranges.append(start..<texts.count) }
        return ranges
    }

    /// 单次翻译请求：JSON 数组进出，去掉可能的 ``` 包裹，解析成字符串数组
    private static func request(_ texts: [String], system: String, temperature: Double, config: Config) async throws -> [String] {
        guard let url = completionsURL(config.baseURL) else { throw err("接口地址无效") }
        let inputJSON = String(data: try JSONSerialization.data(withJSONObject: texts), encoding: .utf8) ?? "[]"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": config.model, "temperature": temperature,
            "messages": [["role": "system", "content": system], ["role": "user", "content": inputJSON]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw err("接口返回 \(http.statusCode)") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              var content = (msg["content"] as? String) else { throw err("响应解析失败") }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            content = content.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String] { return arr }
        // 数组前后带解释文字：截取首个 '[' 到最后一个 ']' 再试
        if let l = content.firstIndex(of: "["), let r = content.lastIndex(of: "]"), l < r,
           let arr = try? JSONSerialization.jsonObject(with: Data(String(content[l...r]).utf8)) as? [String] {
            return arr
        }
        // 兜底按行切（截断的 JSON 会走到这）：去掉行首尾的引号和尾逗号，别把 JSON 碎片当译文
        return content.split(separator: "\n", omittingEmptySubsequences: false).map {
            var line = $0.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(",") { line.removeLast() }
            if line.hasPrefix("\""), line.hasSuffix("\""), line.count >= 2 {
                line = String(line.dropFirst().dropLast())
            }
            return line
        }
    }

    private static func completionsURL(_ baseURL: String) -> URL? {
        var raw = baseURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if !raw.hasSuffix("/chat/completions") { raw += raw.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions" }
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
    private static func err(_ m: String) -> NSError { NSError(domain: "translate", code: 0, userInfo: [NSLocalizedDescriptionKey: m]) }
}

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
    /// 标注工具：none=可重新框选，box=框选，pen=画笔，mosaic=马赛克，note=备注，flow=流程
    private enum Tool { case none, box, pen, mosaic, note, flow }
    /// 马赛克模式：brush=像笔一样涂抹，box=框选区域
    private enum MosaicMode { case brush, box }
    /// 画笔/马赛克自由笔画
    private struct Stroke { var points: [NSPoint]; var colorHex: String; var lineWidth: CGFloat }
    private struct MosaicStroke { var points: [NSPoint]; var lineWidth: CGFloat }
    /// 框选：矩形 + 样式（形状/线型/颜色/粗细/高亮，逐框独立）
    private struct Box {
        var rect: NSRect
        var shape: BoxShape = .rect
        var dashed = false
        var highlight = false
        var colorHex = "#FFFFFF"
        var lineWidth: CGFloat = 2.5
    }
    /// 备注：框 + 引导线 + 文字气泡（框/线可调色）
    private struct Marker { var box: NSRect; var textRect: NSRect; var text: String; var colorHex = "#FFFFFF" }
    /// 流程：序号角标 + 引导线 + 文字气泡（角标/线可调色）
    private struct Step { var center: NSPoint; var number: String; var textRect: NSRect; var text: String; var colorHex = "#FFFFFF" }
    /// 当前正在编辑的目标
    private enum Editing { case markerText(Int), stepText(Int), stepNumber(Int) }
    /// 拖动中的说明气泡引用（回车后可拖动文字框）
    private enum BubbleRef { case marker(Int); case step(Int) }
    private struct PendingBubble { let ref: BubbleRef; let grab: NSPoint; let down: NSPoint; var moved: Bool }
    /// 拖动中的流程角标
    private struct PendingBadge { let index: Int; let grab: NSPoint; let down: NSPoint; var moved: Bool }
    /// 备注框几何调整：移动(记抓取偏移) / 缩放(记对角固定点)
    private enum MarkerGrabMode { case move(NSPoint); case resize(fixed: NSPoint) }
    private struct MarkerGrab { let mode: MarkerGrabMode; var moved: Bool }
    /// 当前选中的标注（单击选中，可 ESC 删除）
    private enum AnnotationRef: Equatable { case box(Int); case marker(Int); case step(Int) }
    /// 撤回快照：所有标注
    private struct Snapshot { let boxes: [Box]; let markers: [Marker]; let steps: [Step]; let pen: [Stroke]; let mosaicS: [MosaicStroke]; let mosaicR: [NSRect] }

    private let cgImage: CGImage
    private let nsImage: NSImage
    private let screen: NSScreen
    private let onClose: () -> Void
    private let translateProvider: () -> (ScreenshotTranslator.Config, String, String)?
    private var translatedOverride: NSImage?   // 翻译后盖在选区上的译图（缓存，切换/导出复用）
    private var translatePartial: [String]?    // 渐进翻译累积（空串=该块未回，渲染跳过保留原文）
    private var showingOriginal = false        // 译图在手时，是否临时显示原文
    private var hintView: NSView?              // 「翻译中…」/错误 提示气泡
    private var hintLabel: NSTextField?        // 气泡内文字（原位更新进度，不重建视图）
    private var hintSpinning = false           // 气泡当前是否带转圈

    private var phase: Phase = .selecting
    private var tool: Tool = .none
    private var selection: NSRect?
    private var dragOrigin: NSPoint?
    // 窗口吸附：框选阶段悬停自动高亮光标下的窗口，单击即整窗选中
    private var snapWindows: [NSRect]?      // 吸附候选：截图冻结时刻的普通窗口边框（视图坐标、Z 序前→后）；nil=未加载
    private var hoverWindowRect: NSRect?    // 光标当前所在窗口的吸附框

    private var boxes: [Box] = []
    private var boxHighlight = false        // 框选样式：是否高亮（聚光灯）
    private var boxShape: BoxShape = .rect   // 框选样式：矩形 / 椭圆
    private var boxDashed = false            // 框选样式：实线 / 虚线
    private var boxColorHex = "#FFFFFF"      // 框选样式：颜色（默认白）
    private var boxLineWidth: CGFloat = 2.5  // 框选样式：粗细
    private var optionsHost: NSHostingView<AnyView>?   // 工具子选项面板（框选/画笔/马赛克）

    // 画笔
    private var penStrokes: [Stroke] = []
    private var penColorHex = "#FFFFFF"   // 画笔颜色（默认白）
    private var penLineWidth: CGFloat = 4
    private var noteColorHex = "#FFFFFF"  // 备注新建颜色（默认白）
    private var flowColorHex = "#FFFFFF"  // 流程新建颜色（默认白）
    // 马赛克
    private var mosaicStrokes: [MosaicStroke] = []
    private var mosaicRects: [NSRect] = []
    private var mosaicMode: MosaicMode = .box   // 默认区域框选
    private var mosaicLineWidth: CGFloat = 22
    private var currentStroke: [NSPoint]?    // 正在画的画笔/马赛克涂抹笔画
    private var hoverPoint: NSPoint?         // 马赛克涂抹时的笔刷光标位置
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
    private var selected: AnnotationRef?        // 单击选中的标注，ESC 可删除
    private var undoStack: [Snapshot] = []      // 撤回栈（Cmd+Z）

    private var toolbarHost: NSHostingView<ScreenshotToolbar>?
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        // 框选阶段（未开始拖拽）：悬停吸附光标下的窗口，单击即整窗选中；一旦拖拽走自由框选
        if phase == .selecting, dragOrigin == nil, !recordingLong, !longFinished, ocrPanel == nil, hintView == nil {
            let pt = convert(event.locationInWindow, from: nil)
            let hit = snapWindowRect(under: pt)
            if hit != hoverWindowRect { hoverWindowRect = hit; needsDisplay = true }
            return
        }
        guard tool == .mosaic, mosaicMode == .brush else { if hoverPoint != nil { hoverPoint = nil; needsDisplay = true }; return }
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    // MARK: - 窗口吸附

    /// 光标下最顶层可见窗口的吸附框（视图坐标）；候选列表只取一次——覆盖层显示后画面已冻结，窗口不会再动
    private func snapWindowRect(under pt: NSPoint) -> NSRect? {
        if snapWindows == nil {
            snapWindows = Self.loadSnapWindows(screen: screen, bounds: bounds,
                                               excludeNumbers: Set([window?.windowNumber].compactMap { $0 }))
        }
        return snapWindows?.first { $0.contains(pt) }
    }

    /// 枚举屏上可见窗口 → 视图坐标（Z 序前→后）。不限 layer 0：刘海面板、各 App 浮动面板都能吸附；
    /// 只排除截图覆盖层自身、桌面层（负 layer）、全屏遮罩层（高 layer 且盖满整屏，如光晕层）与过小窗口。
    private static func loadSnapWindows(screen: NSScreen, bounds: NSRect, excludeNumbers: Set<Int>) -> [NSRect] {
        guard let displayID = screen.displayID,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let b = CGDisplayBounds(displayID)   // 本屏 CG 全局框（左上原点）
        var rects: [NSRect] = []
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  (info[kCGWindowNumber as String] as? Int).map({ !excludeNumbers.contains($0) }) ?? true,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let wf = CGRect(dictionaryRepresentation: bd), wf.width >= 40, wf.height >= 40 else { continue }
            // CG 全局（左上原点、y 向下） → 本屏视图坐标（左下原点、y 向上）
            let r = NSRect(x: wf.minX - b.minX, y: bounds.height - (wf.maxY - b.minY),
                           width: wf.width, height: wf.height).intersection(bounds)
            guard r.width >= 40, r.height >= 40 else { continue }
            // 高 layer 且盖满整屏 = 遮罩层（光晕/覆盖层同类），不是可截的窗口；layer 0 的全屏 App 窗口保留
            if layer > 0, r.width >= bounds.width * 0.95, r.height >= bounds.height * 0.95 { continue }
            rects.append(r)
        }
        return rects
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
        var spots: [(rect: NSRect, shape: BoxShape)] = boxes.filter { $0.highlight }.map { ($0.rect, $0.shape) }
        if tool == .box, boxHighlight, let c = currentBox { spots.append((c, boxShape)) }
        if !spots.isEmpty { drawSpotlight(spots, in: sel) }

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: sel); border.lineWidth = 1; border.stroke()

        for b in boxes where !b.highlight { drawBoxStyled(b) }   // 非高亮框按各自样式画
        for (i, m) in markers.enumerated() { drawMarker(m, editing: isEditing(.markerText(i)), active: i == activeMarker) }
        for (i, s) in steps.enumerated() {
            drawStep(s, editingNumber: isEditing(.stepNumber(i)), editingText: isEditing(.stepText(i)))
        }
        drawPenStrokes(dx: 0, dy: 0)   // 画笔：盖在最上层
        if let sel = selected {
            if editingField == nil, activeMarker == nil { drawSelection(sel) }   // 空闲选中＝虚线高亮
            drawDeleteButton(sel)                                                 // 选中即显示删除按钮(×)，点它删整个组件
        }
        if let c = currentBox {
            if tool == .box, !boxHighlight { drawBoxStyled(currentStyleBox(c)) }   // 框选预览（高亮预览走聚光灯）
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
        Box(rect: rect, shape: boxShape, dashed: boxDashed, highlight: boxHighlight, colorHex: boxColorHex, lineWidth: boxLineWidth)
    }

    /// 按框各自样式画：矩形/椭圆、实线/虚线、颜色、粗细
    private func drawBoxStyled(_ box: Box) {
        let path = box.shape == .oval
            ? NSBezierPath(ovalIn: box.rect)
            : NSBezierPath(roundedRect: box.rect, xRadius: 6, yRadius: 6)
        path.lineWidth = box.lineWidth
        if box.dashed { path.setLineDash([box.lineWidth * 2.6, box.lineWidth * 2.3], count: 2, phase: 0) }
        withShadow(blur: 4, alpha: 0.28) {
            NSColor(Color(hex: box.colorHex)).setStroke()
            path.stroke()
        }
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
        case .box(let i):    if boxes.indices.contains(i) { ring(boxes[i].rect) }
        case .marker(let i): if markers.indices.contains(i) { ring(markers[i].box) }
        case .step(let i):   if steps.indices.contains(i) {
            let c = steps[i].center, rr = badgeRadius + 4
            let p = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            p.lineWidth = 1.5; p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
        }
        }
    }

    /// 选中组件右上角的删除按钮(×)矩形；命中它＝删除整个组件
    private func deleteButtonRect(_ ref: AnnotationRef) -> NSRect {
        let s: CGFloat = 19
        var corner = NSPoint.zero
        switch ref {
        case .box(let i):    guard boxes.indices.contains(i) else { return .zero }; corner = NSPoint(x: boxes[i].rect.maxX, y: boxes[i].rect.maxY)
        case .marker(let i): guard markers.indices.contains(i) else { return .zero }; corner = NSPoint(x: markers[i].box.maxX, y: markers[i].box.maxY)
        case .step(let i):   guard steps.indices.contains(i) else { return .zero }; corner = NSPoint(x: steps[i].center.x + badgeRadius, y: steps[i].center.y + badgeRadius)
        }
        return NSRect(x: corner.x - s / 2, y: corner.y - s / 2, width: s, height: s)
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
    private func drawSpotlight(_ spots: [(rect: NSRect, shape: BoxShape)], in sel: NSRect) {
        guard !spots.isEmpty, sel.width > 0, sel.height > 0 else { return }
        let layer = NSImage(size: sel.size)
        layer.lockFocus()
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: sel.size)).fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut   // 把框内暗色擦透明
        NSColor.black.setFill()
        for s in spots {
            let r = s.rect.offsetBy(dx: -sel.minX, dy: -sel.minY)
            (s.shape == .oval ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)).fill()
        }
        layer.unlockFocus()
        layer.draw(in: sel)   // 叠到主上下文：框外半透明黑(暗)、框内透明(露原图)
    }

    /// 生成整屏的马赛克版（缩小再 nearest 放大 = 像素块）；按需求路径裁剪显示
    private func makeMosaicImage() -> NSImage {
        let block: CGFloat = 11
        let w = max(1, Int(bounds.width / block)), h = max(1, Int(bounds.height / block))
        let small = NSImage(size: NSSize(width: w, height: h))
        small.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .none
        nsImage.draw(in: NSRect(x: 0, y: 0, width: w, height: h)); small.unlockFocus()
        let big = NSImage(size: bounds.size)
        big.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .none
        small.draw(in: bounds); big.unlockFocus()
        return big
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
        for ps in penStrokes { strokePen(ps.points, color: ps.colorHex, width: ps.lineWidth, dx: dx, dy: dy) }
        if tool == .pen, let pts = currentStroke { strokePen(pts, color: penColorHex, width: penLineWidth, dx: dx, dy: dy) }
    }
    private func strokePen(_ points: [NSPoint], color: String, width: CGFloat, dx: CGFloat, dy: CGFloat) {
        let c = NSColor(Color(hex: color))
        if points.count == 1 { let r = width / 2, pt = points[0]; c.setFill(); NSBezierPath(ovalIn: NSRect(x: pt.x + dx - r, y: pt.y + dy - r, width: width, height: width)).fill(); return }
        c.setStroke()
        let path = NSBezierPath(); path.move(to: NSPoint(x: points[0].x + dx, y: points[0].y + dy))
        for p in points.dropFirst() { path.line(to: NSPoint(x: p.x + dx, y: p.y + dy)) }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    }

    // MARK: - 鼠标

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
        // 画笔 / 马赛克涂抹：自由起笔（优先于标注交互）
        if phase == .editing, tool == .pen || (tool == .mosaic && mosaicMode == .brush) {
            commitEditing(); selected = nil; record(); currentStroke = [pt]; needsDisplay = true
            return
        }
        // 区域马赛克：拖矩形
        if phase == .editing, tool == .mosaic, mosaicMode == .box {
            commitEditing(); selected = nil; boxOrigin = pt; currentBox = NSRect(origin: pt, size: .zero); needsDisplay = true
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
        } else if phase == .editing, tool == .box || tool == .note {
            commitEditing()
            if tool == .note, let i = markerBoxIndex(at: pt) {
                // 备注单击：同时进入文字编辑 + 几何调整（输入框、四角手柄一起出现）
                activeMarker = i
                startMarkerTextEdit(i)
            } else {
                boxOrigin = pt
                currentBox = NSRect(origin: pt, size: .zero)
            }
        } else {
            phase = .selecting
            removeToolbar()
            commitEditing()
            boxes.removeAll(); markers.removeAll(); steps.removeAll(); penStrokes.removeAll(); mosaicStrokes.removeAll(); mosaicRects.removeAll()
            activeMarker = nil; selected = nil; undoStack.removeAll()
            dragOrigin = pt
            selection = NSRect(origin: pt, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !recordingLong, !longFinished else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if currentStroke != nil { currentStroke?.append(pt); needsDisplay = true; return }   // 自由笔画
        if var grab = markerGrab, let i = activeMarker, markers.indices.contains(i) {
            if !grab.moved { record() }   // 首次移动前记录撤回点
            grab.moved = true; markerGrab = grab
            switch grab.mode {
            case .move(let g):
                markers[i].box.origin = NSPoint(x: pt.x - g.x, y: pt.y - g.y)   // 移动整个框
            case .resize(let fixed):
                markers[i].box = Self.rect(fixed, pt).intersection(selection ?? .zero)   // 拖角缩放，对角固定
            }
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
        if (tool == .box || tool == .note || (tool == .mosaic && mosaicMode == .box)), let o = boxOrigin {
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
        if let pts = currentStroke {   // 画笔 / 马赛克涂抹收尾
            currentStroke = nil
            if !pts.isEmpty {
                if tool == .pen { penStrokes.append(Stroke(points: pts, colorHex: penColorHex, lineWidth: penLineWidth)) }
                else { mosaicStrokes.append(MosaicStroke(points: pts, lineWidth: mosaicLineWidth)) }
            }
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
                hoverWindowRect = nil
                phase = .editing; showToolbar(for: hw)
            } else { selection = nil }
        } else if phase == .editing, tool == .mosaic, mosaicMode == .box, let b = currentBox {
            currentBox = nil; boxOrigin = nil
            if b.width >= 6, b.height >= 6 { record(); mosaicRects.append(b) }   // 区域马赛克
        } else if phase == .editing, tool == .box || tool == .note, let b = currentBox {
            let origin = boxOrigin
            currentBox = nil; boxOrigin = nil
            if b.width >= 6, b.height >= 6 {
                if tool == .box { record(); boxes.append(currentStyleBox(b)) }
                else { addMarker(box: b) }
            } else if tool == .box, event.clickCount >= 2, let o = origin, let i = boxes.lastIndex(where: { $0.rect.contains(o) }) {
                record(); boxes[i].highlight.toggle()   // 双击已有框 → 切换高亮；单击只选中(可删除)，避免误触
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

    /// 命中任意标注（备注气泡/框、流程气泡/角标、框选）→ 用于「单击选中、ESC 删除」
    private func hitAnnotation(at pt: NSPoint) -> AnnotationRef? {
        if let i = markers.lastIndex(where: { !$0.text.isEmpty && $0.textRect.contains(pt) }) { return .marker(i) }
        if let i = markers.lastIndex(where: { $0.box.contains(pt) }) { return .marker(i) }
        if let i = steps.lastIndex(where: { !$0.text.isEmpty && $0.textRect.contains(pt) }) { return .step(i) }
        if let i = steps.lastIndex(where: { hypot($0.center.x - pt.x, $0.center.y - pt.y) <= badgeRadius + 2 }) { return .step(i) }
        if let i = boxes.lastIndex(where: { $0.rect.contains(pt) }) { return .box(i) }
        return nil
    }

    /// 删除当前选中的标注
    private func deleteSelected() {
        switch selected {
        case .box(let i):    if boxes.indices.contains(i) { boxes.remove(at: i) }
        case .marker(let i): if markers.indices.contains(i) { markers.remove(at: i) }
        case .step(let i):   if steps.indices.contains(i) { steps.remove(at: i) }
        case .none: break
        }
        selected = nil; activeMarker = nil
    }

    /// 撤回：记录当前标注快照 / 回退到上一步
    private func record() {
        undoStack.append(Snapshot(boxes: boxes, markers: markers, steps: steps, pen: penStrokes, mosaicS: mosaicStrokes, mosaicR: mosaicRects))
        if undoStack.count > 80 { undoStack.removeFirst() }
    }
    private func undo() {
        let f = editingField; editingField = nil; editing = nil   // 丢弃正在编辑的输入框（不计入历史）
        f?.removeFromSuperview()
        guard let s = undoStack.popLast() else { return }
        boxes = s.boxes; markers = s.markers; steps = s.steps
        penStrokes = s.pen; mosaicStrokes = s.mosaicS; mosaicRects = s.mosaicR
        selected = nil; activeMarker = nil; markerGrab = nil; pendingBubble = nil; pendingBadge = nil; currentStroke = nil
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
    private func makeField(_ frame: NSRect, value: String, placeholder: String, numeric: Bool) -> AnnotationTextView {
        var size = numeric ? frame.size : bubbleSize(value, maxWidth: bubbleMaxWidth)
        let tv = AnnotationTextView(frame: NSRect(origin: frame.origin, size: size))   // 左下角锚点
        tv.font = numeric ? numFont : textFont
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
        tv.placeholderAttrs = [.font: numeric ? numFont : textFont, .foregroundColor: NSColor.white.withAlphaComponent(0.4)]
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
        if case .markerText = e { origin.y = tv.frame.maxY - size.height }   // 备注：左上角固定(向下长)；流程：左下角固定(向上长)
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

    private func removeToolbar() { toolbarHost?.removeFromSuperview(); toolbarHost = nil; removeToolOptions() }

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
        switch tool {
        case .box:
            return AnyView(BoxOptionsBar(
                shape: boxShape, dashed: boxDashed, highlight: boxHighlight, colorHex: boxColorHex, lineWidth: boxLineWidth,
                onShape: { [weak self] in self?.boxShape = $0; self?.refreshToolbars() },
                onDashed: { [weak self] in self?.boxDashed = $0; self?.refreshToolbars() },
                onHighlight: { [weak self] in self?.toggleBoxHighlight() },
                onColor: { [weak self] in self?.boxColorHex = $0; self?.refreshToolbars() },
                onWidth: { [weak self] in self?.boxLineWidth = $0; self?.refreshToolbars() }))
        case .pen:
            return AnyView(PenOptionsBar(
                colorHex: penColorHex, lineWidth: penLineWidth,
                onColor: { [weak self] in self?.penColorHex = $0; self?.refreshToolbars() },
                onWidth: { [weak self] in self?.penLineWidth = $0; self?.refreshToolbars() }))
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
        return ScreenshotToolbar(
            boxActive: tool == .box, penActive: tool == .pen, mosaicActive: tool == .mosaic,
            noteActive: tool == .note, flowActive: tool == .flow,
            translateTitle: tTitle,
            onBox: { [weak self] in self?.toggleTool(.box) },
            onPen: { [weak self] in self?.toggleTool(.pen) },
            onMosaic: { [weak self] in self?.toggleTool(.mosaic) },
            onNote: { [weak self] in self?.toggleTool(.note) },
            onFlow: { [weak self] in self?.toggleTool(.flow) },
            onUndo: { [weak self] in self?.undo() },
            onOCR: { [weak self] in self?.runOCR() },
            onLongShot: { [weak self] in self?.startLongShot() },
            onTranslate: { [weak self] in self?.translateButtonTapped() },
            onSave: { [weak self] in self?.saveToDesktop() },
            onCopy: { [weak self] in self?.copyToClipboard() },
            onCancel: { [weak self] in self?.close() })
    }

    private func toggleTool(_ t: Tool) {
        commitEditing()
        activeMarker = nil; markerGrab = nil
        tool = (tool == t) ? .none : t
        if let sel = selection { showToolbar(for: sel) }
        needsDisplay = true
    }

    /// 框选「高亮」子开关：只决定接下来新画框默认是否高亮；已有框各自单击切换，互不影响
    private func toggleBoxHighlight() {
        boxHighlight.toggle()
        if let sel = selection { showToolbar(for: sel) }   // 刷新勾选状态
        needsDisplay = true
    }

    // MARK: - 合成 / 输出

    private func compose() -> NSImage? {
        commitEditing()
        guard let sel = selection else { return nil }
        let scale = screen.backingScaleFactor
        let crop = CGRect(x: sel.minX * scale, y: (bounds.height - sel.maxY) * scale,
                          width: sel.width * scale, height: sel.height * scale)
        guard let cropped = cgImage.cropping(to: crop) else { return nil }
        let outSize = NSSize(width: sel.width, height: sel.height)
        let result = NSImage(size: outSize)
        result.lockFocus()
        let base = (translatedOverride != nil && !showingOriginal) ? translatedOverride! : NSImage(cgImage: cropped, size: outSize)
        base.draw(in: NSRect(origin: .zero, size: outSize))
        let dx = -sel.minX, dy = -sel.minY
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
                (b.shape == .oval ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)).fill()
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
        result.unlockFocus()
        return result
    }

    private func copyToClipboard() {
        guard let img = compose() else { close(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        close()
    }

    private func saveToDesktop() {
        guard let img = compose(),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { close(); return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/截图 \(fmt.string(from: Date())).png")
        try? png.write(to: url)
        close()
    }

    // MARK: - 长截图（程序自动匀速滚动 + 逐帧拼接）

    /// 进入长截图：固定选区为视口，先选方向，再程序自动匀速滚动并逐帧拼接，滚到端自动停。
    private func startLongShot() {
        commitEditing()
        guard ocrPanel == nil, hintView == nil, !recordingLong else { return }   // OCR/翻译中或已在录制：忽略
        guard let sel = selection, sel.width > 24, sel.height > 80 else { return }
        guard Self.ensureAccessibility() else { return }   // 未授权：已弹系统授权框，本次不进入
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

    private static func framesStable(_ a: CGImage, _ b: CGImage) -> Bool {
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
    private static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }

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
        if let cg = longResultCG, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/长截图 \(fmt.string(from: Date())).png")
            try? png.write(to: url)
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
        guard ocrPanel == nil, hintView == nil, !recordingLong else { return }   // 防重入/与翻译、长截图互斥
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
        let obs = (request.results as? [VNRecognizedTextObservation]) ?? []
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
            onClose: { [weak self] in self?.dismissOCRPanel() })
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

    // MARK: - 翻译（原位叠加：盖住原文 + 写译文）

    private func runTranslate() {
        commitEditing()
        guard ocrPanel == nil, hintView == nil, !recordingLong, let sel = selection else { return }
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
        // 工具栏保持在场；翻译中的动效提示浮在选区中央
        showHint("翻译中…", spinning: true)
        let outSize = sel.size
        translatePartial = nil
        Task {
            let blocks = Self.recognizeBlocks(cropped)
            if blocks.isEmpty { await MainActor.run { self.translateFailed("未识别到文字") }; return }
            let texts = blocks.map { $0.text }
            // 首选系统翻译（本机离线，整批毫秒级）；失败（语言包未装/语种不支持）静默降级到 AI
            if useSystem {
                do {
                    let translations = try await SystemTranslator.translate(texts, targetLang: lang)
                    let img = Self.renderTranslated(base: cropped, size: outSize, blocks: blocks, translations: translations)
                    await MainActor.run { self.translateDone(img) }
                    return
                } catch {
                    guard aiReady else {
                        await MainActor.run { self.translateFailed(error.localizedDescription) }
                        return
                    }
                    print("[ProNotch] 系统翻译失败，降级 AI: \(error.localizedDescription)")
                }
            }
            do {
                let translations = try await ScreenshotTranslator.translate(
                    texts, to: lang, prompt: prompt, config: config,
                    onPartial: { [weak self] range, chunk, done, total in
                        // 渐进渲染：哪块先译完先贴回原图哪块，不等全部译完
                        Task { @MainActor in
                            guard let self, self.hintView != nil else { return }   // 已完成/已关闭则忽略迟到块
                            var acc = self.translatePartial ?? [String](repeating: "", count: blocks.count)
                            if chunk.count == range.count {
                                for (k, i) in range.enumerated() { acc[i] = chunk[k] }
                            }
                            self.translatePartial = acc
                            if total > 1 { self.showHint("翻译中… \(done)/\(total)", spinning: true) }
                            self.translatedOverride = Self.renderTranslated(base: cropped, size: outSize, blocks: blocks, translations: acc)
                            self.showingOriginal = false
                            self.needsDisplay = true
                        }
                    })
                let img = Self.renderTranslated(base: cropped, size: outSize, blocks: blocks, translations: translations)
                await MainActor.run { self.translateDone(img) }
            } catch {
                await MainActor.run { self.translateFailed(error.localizedDescription) }
            }
        }
    }

    private func translateDone(_ img: NSImage) {
        removeHint()
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
        translatePartial = nil
        translatedOverride = nil   // 全部失败：不留半成品译图
        showHint("翻译失败：\(msg)")
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
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        host.layer?.cornerRadius = 8
        if spinning {   // 翻译中：白色小转圈，让人一眼看出「在干活」而不是卡死
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isIndeterminate = true
            spin.appearance = NSAppearance(named: .darkAqua)   // 深底上渲染成浅色
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
        let obs = (request.results as? [VNRecognizedTextObservation]) ?? []
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

/// 框选子选项面板：形状(矩形/椭圆) / 线型(实线/虚线) / 高亮 / 颜色 / 粗细
struct BoxOptionsBar: View {
    let shape: BoxShape
    let dashed: Bool
    let highlight: Bool
    let colorHex: String
    let lineWidth: CGFloat
    let onShape: (BoxShape) -> Void
    let onDashed: (Bool) -> Void
    let onHighlight: () -> Void
    let onColor: (String) -> Void
    let onWidth: (CGFloat) -> Void

    static let palette = ["#FF453A", "#FF9F0A", "#FFD60A", "#34C759", "#0A84FF", "#FFFFFF"]
    static let widths: [CGFloat] = [2, 3.5, 5]

    var body: some View {
        HStack(spacing: 5) {
            icon("rectangle", active: shape == .rect) { onShape(.rect) }
            icon("circle", active: shape == .oval) { onShape(.oval) }
            sep
            lineBtn(false)
            lineBtn(true)
            sep
            icon("lightbulb", active: highlight, action: onHighlight)
            sep
            ForEach(Self.palette, id: \.self) { swatch($0) }
            sep
            ForEach(Self.widths, id: \.self) { widthBtn($0) }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }

    private var sep: some View { Divider().frame(height: 19).overlay(Color.white.opacity(0.15)) }

    private func icon(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 15))
                .foregroundColor(active ? .cyan : .white.opacity(0.85))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Color.cyan.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func lineBtn(_ d: Bool) -> some View {
        Button { onDashed(d) } label: {
            Group {
                if d { HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Capsule().frame(width: 5, height: 2.4) } } }
                else { Capsule().frame(width: 19, height: 2.4) }
            }
            .foregroundColor(dashed == d ? .cyan : .white.opacity(0.85))
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(dashed == d ? Color.cyan.opacity(0.18) : .clear))
            .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func swatch(_ hex: String) -> some View {
        Button { onColor(hex) } label: {
            Circle().fill(Color(hex: hex))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.white.opacity(colorHex == hex ? 0.95 : 0.25), lineWidth: colorHex == hex ? 2 : 0.5))
                .contentShape(Circle())
        }.buttonStyle(.plain)
    }

    private func widthBtn(_ w: CGFloat) -> some View {
        Button { onWidth(w) } label: {
            Capsule().fill(lineWidth == w ? Color.cyan : Color.white.opacity(0.85))
                .frame(width: 16, height: w)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lineWidth == w ? Color.cyan.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

/// 画笔子选项：颜色 + 粗细
struct PenOptionsBar: View {
    let colorHex: String
    let lineWidth: CGFloat
    let onColor: (String) -> Void
    let onWidth: (CGFloat) -> Void
    static let widths: [CGFloat] = [2.5, 4, 6.5]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(BoxOptionsBar.palette, id: \.self) { hex in
                Button { onColor(hex) } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white.opacity(colorHex == hex ? 0.95 : 0.25), lineWidth: colorHex == hex ? 2 : 0.5))
                        .contentShape(Circle())
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 19).overlay(Color.white.opacity(0.15))
            ForEach(Self.widths, id: \.self) { w in
                Button { onWidth(w) } label: {
                    Circle().fill(lineWidth == w ? Color.cyan : Color.white.opacity(0.85))
                        .frame(width: w + 3, height: w + 3).frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lineWidth == w ? Color.cyan.opacity(0.18) : .clear)).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)).fixedSize()
    }
}

/// 纯调色板子选项（备注 / 流程共用）
struct ColorOptionsBar: View {
    let colorHex: String
    let onColor: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(BoxOptionsBar.palette, id: \.self) { hex in
                Button { onColor(hex) } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 19, height: 19)
                        .overlay(Circle().strokeBorder(Color.white.opacity(colorHex == hex ? 0.95 : 0.25), lineWidth: colorHex == hex ? 2 : 0.5))
                        .contentShape(Circle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)).fixedSize()
    }
}

/// 马赛克子选项：涂抹/区域 模式 + 涂抹粗细
struct MosaicOptionsBar: View {
    let isBox: Bool
    let lineWidth: CGFloat
    let onMode: (Bool) -> Void
    let onWidth: (CGFloat) -> Void
    static let widths: [CGFloat] = [14, 22, 34]
    var body: some View {
        HStack(spacing: 5) {
            modeBtn("rectangle.dashed", active: isBox) { onMode(true) }       // 区域（默认、在前）
            modeBtn("paintbrush.pointed", active: !isBox) { onMode(false) }   // 涂抹
            if !isBox {
                Divider().frame(height: 19).overlay(Color.white.opacity(0.15))
                ForEach(Self.widths, id: \.self) { w in
                    Button { onWidth(w) } label: {
                        Circle().fill(lineWidth == w ? Color.cyan : Color.white.opacity(0.85))
                            .frame(width: w / 3 + 5, height: w / 3 + 5).frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lineWidth == w ? Color.cyan.opacity(0.18) : .clear)).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)).fixedSize()
    }
    private func modeBtn(_ icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15))
                .foregroundColor(active ? .cyan : .white.opacity(0.85))
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Color.cyan.opacity(0.18) : .clear)).contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

/// 马赛克图标：圆角方块内的双明度棋盘格（照大梁老师认可的示意图复刻，细密小格更像真实马赛克）
/// side = 视觉边长，调它即可与工具栏其它 SF Symbol 图标对齐
private struct ScreenshotMosaicGlyph: View {
    var color: Color
    var side: CGFloat = 20
    private let n = 5                       // 5×5 细棋盘
    var body: some View {
        let cell = side / CGFloat(n)
        VStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<n, id: \.self) { c in
                        Rectangle()
                            .fill(color.opacity((r + c).isMultiple(of: 2) ? 1.0 : 0.4))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
    }
}

/// 翻译图标：文(左上) + A(右下) + 右上/左下两个取景角标（照大梁老师的设计矢量复刻）
private struct ScreenshotTranslateGlyph: View {
    var color: Color = .white
    private let line = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
    var body: some View {
        ZStack {
            Text("文").font(.system(size: 8.5, weight: .medium)).foregroundColor(color).position(x: 5, y: 5)
            Text("A").font(.system(size: 8.5, weight: .bold)).foregroundColor(color).position(x: 11.5, y: 11.5)
            Path { p in   // 右上取景角标 ⌐
                p.move(to: CGPoint(x: 10, y: 2.5)); p.addLine(to: CGPoint(x: 14, y: 2.5)); p.addLine(to: CGPoint(x: 14, y: 6.5))
            }.stroke(color, style: line)
            Path { p in   // 左下取景角标 L
                p.move(to: CGPoint(x: 2.5, y: 10)); p.addLine(to: CGPoint(x: 2.5, y: 14)); p.addLine(to: CGPoint(x: 6.5, y: 14))
            }.stroke(color, style: line)
        }
        .frame(width: 16.5, height: 16.5)
    }
}

/// 工具栏图标按钮统一容器：静止略暗，hover 时图标 + 背景一起变亮；active 显示青色高亮
private struct ToolbarIconButton<Content: View>: View {
    var active: Bool = false
    let help: String
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content   // 传入 hover 状态，让图标自身随之变亮
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            content(hover)
                .frame(width: 35, height: 31)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.cyan.opacity(hover ? 0.30 : 0.18)
                                 : Color.white.opacity(hover ? 0.13 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .overlay(alignment: .top) {   // 中文说明气泡：浮在该图标正下方（水平居中于本按钮）
            if hover {
                Text(help)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .offset(y: 46)   // 从按钮顶边下推到工具栏下方约 8pt
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: hover)
    }
}

/// 截图工具栏：框选 / 备注 / 流程 / 保存到桌面 / 取消 / 复制（确定）
struct ScreenshotToolbar: View {
    let boxActive: Bool
    let penActive: Bool
    let mosaicActive: Bool
    let noteActive: Bool
    let flowActive: Bool
    let translateTitle: String
    let onBox: () -> Void
    let onPen: () -> Void
    let onMosaic: () -> Void
    let onNote: () -> Void
    let onFlow: () -> Void
    let onUndo: () -> Void
    let onOCR: () -> Void
    let onLongShot: () -> Void
    let onTranslate: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            // 标注：框选 / 备注 / 流程 / 画笔 / 马赛克
            button("框选标注", "rectangle", active: boxActive, action: onBox)
            button("文字备注", "bubble.left", active: noteActive, action: onNote)
            button("步骤序号标注", "list.number", active: flowActive, action: onFlow)
            button("自由画笔", "pencil.tip", active: penActive, action: onPen)
            mosaicButton(active: mosaicActive)
            Divider().frame(height: 20).overlay(Color.white.opacity(0.15)).padding(.horizontal, 1)
            // 撤回：独立成组
            button("撤销上一步", "arrow.uturn.backward", action: onUndo)
            Divider().frame(height: 20).overlay(Color.white.opacity(0.15)).padding(.horizontal, 1)
            // 智能：翻译 / 提取文字
            if translateTitle == "翻译" { translateButton }   // 自绘「文 A」字形
            else { button(translateTitle, "arrow.2.squarepath", action: onTranslate) }
            button("提取文字（OCR）", "text.viewfinder", action: onOCR)
            button("长截图", "rectangle.split.1x2", action: onLongShot)
            Divider().frame(height: 20).overlay(Color.white.opacity(0.15)).padding(.horizontal, 1)
            // 完成：取消 / 保存 / 复制(确定)
            button("取消", "xmark", action: onCancel)
            button("保存到桌面", "arrow.down.to.line", action: onSave)
            button("复制到剪贴板", "checkmark", tint: .green, action: onCopy)
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }

    /// 翻译按钮：照大梁老师的设计矢量复刻——文(左上)+A(右下)+右上/左下取景角标
    private var translateButton: some View {
        ToolbarIconButton(help: "原位翻译", action: onTranslate) { hover in
            ScreenshotTranslateGlyph(color: .white.opacity(hover ? 1.0 : 0.85)).scaleEffect(1.18)
        }
    }

    /// 马赛克按钮：3×3 棋盘格自绘字形（替换系统 mosaic 符号）
    private func mosaicButton(active: Bool) -> some View {
        ToolbarIconButton(active: active, help: "马赛克遮挡", action: onMosaic) { hover in
            ScreenshotMosaicGlyph(color: active ? .cyan : .white.opacity(hover ? 1.0 : 0.85))
        }
    }

    private func button(_ title: String, _ icon: String, active: Bool = false,
                        tint: Color = .white, action: @escaping () -> Void) -> some View {
        ToolbarIconButton(active: active, help: title, action: action) { hover in
            Image(systemName: icon).font(.system(size: 16.5))
                .foregroundColor(active ? .cyan : tint.opacity(hover ? 1.0 : 0.85))
        }
    }
}

/// OCR 识别结果面板：可编辑修正后复制（A 方案）
struct OCRResultPanel: View {
    @State var text: String
    let onCopy: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("识别结果（可编辑修正）")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.9))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(.white.opacity(0.5))
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .frame(width: 400, height: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
            HStack {
                Text(text.isEmpty ? "未识别到文字" : "\(text.split(separator: "\n").count) 行")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Button(action: { onCopy(text) }) {
                    Text("复制").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 432)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
