import AppKit
import SwiftUI

/// 能成为 key 的无边框面板（无边框 NSPanel 默认收不到键盘，输入框就成了摆设）。
///
/// ESC 不在这里接：`cancelOperation` 得靠响应链走到窗口，而中间隔着
/// `NSHostingView` 与聚焦的 SwiftUI 输入框——实测按了没反应。改由控制器挂本地
/// 按键监听（与剪贴板切换器同一套做法）
private final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// AI 闪问的独立浮窗：快捷键唤出，不再展开刘海。
///
/// 由来（大梁老师 2026-07-29）：闪问原先寄生在刘海展开态里，快捷键一按整条刘海张开。
/// 但闪问是「问一句、读一段」的事，答案还可能很长——它需要一块能自己摆位置、
/// 能一直摊在那儿的地方。
///
/// 形态是他拍板的：无边框圆角浮层、可拖可缩、记住位置和大小、
/// **失焦不关**（否则你想切去浏览器核对一眼来源，窗口就没了）、ESC 或右上角关。
///
/// 刘海里的闪问页保留，两处共用同一个 `ChatStore`——同一份对话开两个窗口，
/// `@Published` 让两边实时同步。同时开着也不会坏，只是重复。
@MainActor
final class ChatWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ChatWindowController()

    /// 供 `ChatView` 的粘贴监听判断「该不该由我处理这次 ⌘V」：
    /// 刘海页看的是「展开且停在闪问页」，独立窗口看的就是这扇窗在不在最前
    var isKeyWindow: Bool { panel?.isKeyWindow == true }

    var isVisible: Bool { panel?.isVisible == true }

    private var env: AppEnvironment?
    /// 借刘海那份 view model：`ChatView` 的环境里必须有它（少一个 EnvironmentObject
    /// 会直接崩），而按宿主分流后，独立窗口其实一处也不会去动刘海的状态
    private weak var notchViewModel: NotchViewModel?
    private var panel: ChatPanel?
    /// ESC 监听。只在窗口开着时挂，关掉即摘——常挂着会白白过一遍全 App 的按键
    private var escMonitor: Any?

    /// 首次打开的尺寸。此后由 `setFrameAutosaveName` 记住用户自己调的
    private let defaultSize = NSSize(width: 860, height: 560)

    /// 宽度上限：正文列最宽 920、散文再限 760，超过之后继续拉宽只多出两边留白。
    /// 920 内容列 + 220 侧栏 + 两边留白 ≈ 1180
    static let maxWindowWidth: CGFloat = 1180

    /// 最小尺寸的单一事实源：makePanel 的 minSize 与 windowWillResize 的下限都取这里。
    /// 620 是输入块 + 三个胶囊不换行的下限，380 是「输入块 + 三四行回答」的下限
    static let minWindowSize = NSSize(width: 620, height: 380)

    /// 钉在桌面（窗口置顶）。开＝浮在所有 App 之上，关＝像普通窗口一样被压到后面。
    /// 默认开：这扇窗本来就是「切去浏览器核对一眼还看得见」才有用
    /// 内容列宽度是否处于「冻结」中。
    ///
    /// 由来（大梁老师 2026-07-31）：卡死修完后（消息列表已全量渲染），
    /// 拖边缘缩放与开合侧栏「非常卡顿」——宽度每变一帧，几十条消息的正文
    /// 就全部重新断行一帧，一帧几十毫秒。断行才是成本，位移不是。
    /// 所以：**变宽过程中把内容列钉在原宽**（纯位移+裁切，帧帧都便宜），
    /// 结束后放开，一次断行到位。ChatView 读它来决定钉不钉
    @Published var contentFrozen = false

    @Published var pinned = true {
        didSet { panel?.level = pinned ? .floating : .normal }
    }

    /// AppDelegate 启动时注入
    func configure(env: AppEnvironment, notchViewModel: NotchViewModel?) {
        self.env = env
        self.notchViewModel = notchViewModel
    }

    // MARK: - 显隐

    /// 快捷键：开着就关，关着就开
    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard let env else {
            AppLog.chat.error("闪问窗口未注入数据层，无法打开")
            return
        }
        let panel = self.panel ?? makePanel(env: env)
        self.panel = panel
        // autosave 里可能存着上限生效之前拉出来的超宽尺寸，开窗时夹回来。
        // 写在 makePanel 里没用——那时 autosave 还没恢复
        if panel.frame.width > Self.maxWindowWidth {
            panel.setContentSize(NSSize(width: Self.maxWindowWidth,
                                        height: panel.frame.height))
        }
        if !panel.isVisible { placeIfNeeded(panel) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // 上屏即聚焦输入框，快捷键呼出后可以直接打字
        env.chat.focusInputTick += 1
        installEscMonitor()
        // 刻意不在这里记 isKeyWindow：成为 key 是下一轮事件循环才落定的，
        // 此刻读出来恒为 false，写进日志只会误导排查的人（我自己就被误导过一轮）
        AppLog.chat.info("闪问独立窗口已打开")
    }

    func hide() {
        panel?.orderOut(nil)
        removeEscMonitor()
    }

    /// 键盘监听：**ESC 打断输出，⌘W 关窗**。
    ///
    /// 分工是大梁老师定的（2026-07-31）：ESC 原来直接关窗，AI 正在吐字时按一下窗口就没了，
    /// 想打断输出反而没有手段。ESC 在 macOS 里的语义是「中止当前这件事」，
    /// 关窗则该走系统惯例（⌘W 或左上角红灯）。
    /// 所以现在 ESC 只在**正在输出时**生效（停止输出），空闲时放行不再关窗。
    ///
    /// 不走 `NSPanel.cancelOperation` / `performClose:`：那条路要靠响应链从聚焦的
    /// SwiftUI 输入框一直传到窗口，中间隔着 NSHostingView，实测按了没反应。
    /// 本地监听直截了当，且只在这扇窗是 key 时才吃掉按键——
    /// 否则会把别处（刘海、截图选区）的 ESC 一起抢走
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            // ⌘W：按 macOS 惯例关窗（＝红灯，收起不销毁）
            if event.keyCode == 13, event.modifierFlags.contains(.command) {
                self.hide()
                return nil
            }
            // ⌘M：最小化。系统那份 ⌘M 挂在菜单栏「窗口」菜单上，而 ProNotch 是
            // LSUIElement 后台 App 根本没有菜单栏，于是这个键没人接（大梁老师 2026-07-31）。
            // 面板本身是能最小化的（实测 miniaturize 后 isMiniaturized 为真），只差有人调它
            if event.keyCode == 46, event.modifierFlags.contains(.command) {
                self.panel?.miniaturize(nil)
                return nil
            }
            // ⌘N：新对话并聚焦输入框（任务书 §11）
            if event.keyCode == 45, event.modifierFlags.contains(.command) {
                self.env?.chat.newConversation()
                self.env?.chat.focusInputTick += 1
                return nil
            }
            // ⌘K：呼出模型选择（任务书 §11）
            if event.keyCode == 40, event.modifierFlags.contains(.command) {
                self.env?.chat.openModelPickerTick += 1
                return nil
            }
            // ESC：正在输出就打断；没在输出则放行，不再顺手关窗
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .isSubset(of: [.function, .numericPad]) {
                guard self.env?.chat.isStreaming == true else { return event }
                self.env?.chat.stopStreaming()
                AppLog.chat.info("ESC 打断了闪问输出")
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    // MARK: - 构造

    private func makePanel(env: AppEnvironment) -> ChatPanel {
        // .resizable 与 .borderless 并存：没有标题栏，但四边仍可拖拽改尺寸。
        //
        // .nonactivatingPanel 是**必须**的，我一开始想反了：以为它会让面板收不到键盘，
        // 于是去掉它、靠 NSApp.activate 抢焦点。实测（2026-07-29）ProNotch 是
        // LSUIElement 后台 App，activate 根本没生效——最前台仍是别人，
        // 于是窗口浮出来了却打不进字、ESC 也收不到。
        // 正解是刘海面板早就在用的那一套：非激活面板可以在**不激活 App** 的前提下
        // 成为 key window 直接接收键盘（Spotlight 就是这个机制）
        //
        // 关闭按钮用**系统红绿灯**（大梁老师定，2026-07-30）：自绘的 xmark 不是 macOS 的
        // 窗口语言。要红绿灯就必须有标题栏，于是从 .borderless 换成
        // .titled + .fullSizeContentView——标题栏透明、内容照样铺满整窗，
        // 三颗灯浮在内容之上（Xcode、Safari 都是这个组合）。
        // 实测（2026-07-30）：NSPanel 加上 .miniaturizable 后三颗灯全在且全可用，
        // .nonactivatingPanel 也不受影响，仍能不激活 App 就成为 key
        let panel = ChatPanel(contentRect: NSRect(origin: .zero, size: defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        // 藏掉系统红绿灯（大梁老师 2026-07-31 要换成「钉在桌面」）。
        // **不退回 .borderless**：那样会连带丢掉系统圆角、resize 边和标准拖拽，
        // 只把三颗按钮藏起来最省事，窗口行为一点不变
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.titleVisibility = .hidden
        // 内容会滚到标题栏底下，.automatic 这时会自己画一条分隔线——
        // 正是大梁老师说「不要上面那条线」的同一条，直接关掉
        panel.titlebarSeparatorStyle = .none
        panel.title = "AI 闪问"          // 不显示，但辅助功能与窗口菜单要用
        panel.isFloatingPanel = true
        // 默认 true＝只在「需要时」才成为 key。闪问一上屏就该能打字，所以关掉
        panel.becomesKeyOnlyIfNeeded = false
        // 切去别的 App 时不许自动藏——失焦不关是这扇窗的既定行为
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear      // 圆角由系统窗口形状决定，内容不再自己画
        panel.hasShadow = true
        // 浮在别的 App 之上：失焦不关的前提是它还看得见，
        // 否则一切去浏览器就被压在后面，等于关了
        panel.level = pinned ? .floating : .normal
        panel.isMovableByWindowBackground = false   // 拖动只认顶部那条把手，别抢内容里的拖拽
        panel.minSize = Self.minWindowSize
        // 宽度封顶（大梁老师 2026-07-31）：正文列最宽 920、散文再限 760，
        // 超过这个数继续拉宽只会多出两边留白，没有任何信息量。
        // 920 内容列 + 220 侧栏 + 两边留白 ≈ 1180，取整 1180
        // `maxSize` 只负责让右下角出现「不能再宽」的光标反馈，**夹不住尺寸**——
        // 实测设了 1180 之后 setContentSize(1600) 照样出 1600（上一版就只设了它，
        // 大梁老师反馈「并没有做限制」）。真正的闸门在 windowWillResize
        panel.maxSize = NSSize(width: Self.maxWindowWidth,
                               height: CGFloat.greatestFiniteMagnitude)
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.delegate = self
        // 位置与大小自动记住，不用自己存
        panel.setFrameAutosaveName(Self.autosaveName)

        let root = ChatWindowChrome()
        .injecting(env)
        // ChatView 的环境要求有 NotchViewModel；宿主分流后它在这边一处也不会被动到
        .environmentObject(notchViewModel ?? NotchViewModel(notchRect: .zero))

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        // 关掉 NSHostingView 对窗口尺寸的接管。
        //
        // 它默认按内容的理想尺寸去撑窗口——实测把 860×560 撑成了 1088×735，
        // 于是「窗口多大」由 SwiftUI 布局说了算，用户拖出来的尺寸和 autosave
        // 记下的值都会被它覆盖。这里必须让窗口自己说话
        hosting.sizingOptions = []
        panel.contentView = hosting
        // contentView 装上之后再定一次尺寸：autosave 有记录就用记录的，
        // 没有就用默认值，两种情况都不许被内容改写
        panel.setContentSize(panel.frame.size == .zero ? defaultSize : panel.frame.size)
        return panel
    }

    /// 没有记住的位置时（首次打开）摆到主屏偏上居中——比正中略高，
    /// 视线落点和 Spotlight 一致
    private func placeIfNeeded(_ panel: ChatPanel) {
        guard panel.frame.origin == .zero, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08))
    }

    // MARK: - 位置与尺寸记忆

    /// 拖完 / 缩完即落盘。`setFrameAutosaveName` 只在部分时机自动存，
    /// 这两个回调补齐——不然「记住位置」时灵时不灵
    /// 红灯点下去＝收起，不销毁。
    ///
    /// 系统 close 按钮默认走 `close()`：窗口被销毁，下次呼出要重建整棵视图树，
    /// autosave 的位置也可能来不及落盘。这扇窗要的是「藏起来」，和 ESC 同一个行为
    /// 宽度上限的真正闸门。
    ///
    /// 拖拽过程中每一帧都会问一次，返回什么就是什么——比 `maxSize` 可靠
    /// （后者实测只给光标反馈，不夹尺寸）。高度不限，长答案要能拉满屏
    /// 实时拖缩：AppKit 有明确的起止回调，冻结直接映射到这一段。
    /// （曾有个「侧栏开合冻一小段」的定时器变体，侧栏改悬浮层后没了用武之地，已删）
    func windowWillStartLiveResize(_ notification: Notification) {
        contentFrozen = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        contentFrozen = false
    }

    /// 尺寸限制的真正闸门——**上限和下限都得在这儿**。
    ///
    /// 拖拽过程中每一帧都会问一次，返回什么就是什么。而且**一旦实现了这个委托，
    /// 系统就不再替你执行 minSize**：头一版只夹了上限、下限放行，620 形同虚设——
    /// 大梁老师当场拖穿（2026-07-31「620 停不住」）。
    /// 高度上限不设，长答案要能拉满屏；高度下限同理归这儿管
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: min(max(frameSize.width, Self.minWindowSize.width), Self.maxWindowWidth),
               height: max(frameSize.height, Self.minWindowSize.height))
    }

    /// 宽度限制的兜底闸（大梁老师 2026-07-31 反馈「最窄和最宽限制好像没了」）。
    ///
    /// `windowWillResize` 只管**拖拽**这一条路。双击窗口边缘的智能放大、
    /// 辅助功能改尺寸、程序 setFrame 都绕开它——落地超界就在这里当场夹回。
    /// 正常路径下它永远是空操作（宽度合法直接返回），不会跟拖拽打架
    /// 单拎出来是为了可测：windowDidResize 依赖真实 panel，纯夹取逻辑不该跟着不可测
    static func clampedWidth(_ width: CGFloat, minWidth: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWindowWidth)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) {
        // 兜底闸：`windowWillResize` 只管拖拽这一条路，双击边缘的智能放大、
        // 辅助功能改尺寸、程序 setFrame 都绕开它——落地超界就在这里当场夹回，
        // 然后才落盘。正常路径下夹取是空操作，不会跟拖拽打架
        if let panel, (notification.object as? NSWindow) === panel {
            let width = panel.frame.width
            let clamped = Self.clampedWidth(width, minWidth: Self.minWindowSize.width)
            if abs(clamped - width) > 0.5 {
                AppLog.window.info("闪问窗宽度越界收回: \(Int(width)) → \(Int(clamped))（来路非常规拖拽）")
                var frame = panel.frame
                frame.size.width = clamped
                panel.setFrame(frame, display: true)
            }
        }
        saveFrame()
    }

    private func saveFrame() {
        panel?.saveFrame(usingName: Self.autosaveName)
    }

    fileprivate static let autosaveName = "ProNotchChatWindow"
}

/// 拖拽交给 AppKit 自己跑循环的把手。
///
/// 原先是 SwiftUI 的 DragGesture + `.global` 坐标系逐帧 `setFrameOrigin`——
/// 而窗口本身正在移动，全局坐标的原点跟着漂，位移量自己跟自己打架，
/// 表现就是大梁老师说的「拖动非常卡」（2026-07-29）。
/// `performDrag` 把整个拖拽循环交给系统：跟手、零抖动，也不用自己记基准点
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// 浮窗的外框：顶部一条控制条，下面是闪问本体。
///
/// 非 private：离屏渲染要直接拍**这个真实的生产视图**给大梁老师看。
/// 之前给他看的是我手画的仿制稿，图看着行、装上就崩，来回好几轮全耗在这个落差上
private struct ChatContentFrozenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 闪问窗口内容列宽度是否冻结中（见 ChatWindowController.contentFrozen）
    var chatContentFrozen: Bool {
        get { self[ChatContentFrozenKey.self] }
        set { self[ChatContentFrozenKey.self] = newValue }
    }
}

struct ChatWindowChrome: View {
    @EnvironmentObject var store: ChatStore
    @ObservedObject var controller = ChatWindowController.shared
    @State private var hoverNew = false
    @State private var hoverPin = false
    @State private var hoverHistory = false
    @State private var showHistory = false

    /// 历史会话开关。列表不再弹浮窗，而是从右侧推开一条侧边栏（大梁老师 2026-07-31）：
    /// 浮窗会盖住正文、点一下就消失，侧栏能一直开着对照着看
    private var historyButton: some View {
        iconButton("clock.arrow.circlepath", hovering: hoverHistory,
                   tip: showHistory ? "收起历史对话" : "历史对话") {
            // 侧栏是悬浮层（见 body），开合完全不碰正文布局，
            // withAnimation 只驱动它自己的滑入滑出
            withAnimation(.easeOut(duration: 0.16)) { showHistory.toggle() }
        }
        .onHover { hoverHistory = $0 }
        .accessibilityValue(showHistory ? "已展开" : "已收起")
    }

    /// 右侧历史对话侧栏。数据来自 ChatStore.conversations（真有），点一条即切过去
    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部让开：底色铺到窗顶，但标题与左边顶栏那一行对齐
            Text("历史对话")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MarkdownTypography.textTertiary)
                .padding(.horizontal, 14).padding(.top, 52).padding(.bottom, 6)
            if store.conversations.isEmpty {
                Text("还没有历史对话")
                    .font(.system(size: 12))
                    .foregroundStyle(MarkdownTypography.textTertiary)
                    .padding(.horizontal, 14)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.conversations) { conversation in
                            historyRow(conversation)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(ChatWindowPalette.surface1)
        // 只在左边描一道线：右边贴着窗沿，再描一条就成了双线
        .overlay(alignment: .leading) {
            Rectangle().fill(ChatWindowPalette.divider).frame(width: 1)
        }
        // 悬浮在正文之上，左缘一道投影交代层级
        .shadow(color: .black.opacity(0.30), radius: 14, x: -5)
        // 动画由 historyButton 的 withAnimation 驱动（只动这次插拔，不碰别的）；
        // 这里刻意不挂 .animation(value:)——挂在大子树上的隐式动画吃过大亏
        //（atBottom 振荡卡死，2026-07-31），教训是动画永远只圈住要动的那一小片
        .transition(.move(edge: .trailing))
    }

    private func historyRow(_ conversation: ChatConversation) -> some View {
        let current = conversation.id == store.currentID
        return Button {
            store.selectConversation(conversation.id)
        } label: {
            HStack(spacing: 6) {
                Text(conversation.title.isEmpty ? "未命名对话" : conversation.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(current ? .white : .white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(current ? ChatWindowPalette.surface2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换到对话：\(conversation.title.isEmpty ? "未命名对话" : conversation.title)")
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ChatView(host: .window)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.chatContentFrozen, controller.contentFrozen)
        }
        // 侧栏改**悬浮层**，不再推挤内容（大梁老师 2026-07-31「还是卡顿」后定）。
        // 推挤式的账躲不掉：正文列宽一变就得整列重新断行，冻结手段只能把这笔账
        // 从「动画中间」挪到「动画结束」，那一下的顿挫还在。悬浮层盖在内容上，
        // 正文宽度全程不变——零断行，开合帧帧都便宜，也没有收尾的跳变。
        // 从窗顶铺到窗底（他此前定的「侧栏应到顶」不变）
        .overlay(alignment: .trailing) {
            if showHistory { historySidebar }
        }
        // 「新对话 / 历史」钉在**整扇窗**的右上角，不随侧栏左移（大梁老师 2026-07-31）。
        // 它们跟标题不是一回事：标题标的是「你在读哪一栏」，所以跟内容区走；
        // 这两个是窗口级的开关，尤其历史——按下去长出来的东西就在它正下方，
        // 跟着内容左移反而离自己管的那条侧栏越来越远
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                iconButton("plus", hovering: hoverNew, tip: "新对话 ⌘N") {
                    store.newConversation()
                    store.focusInputTick += 1
                }
                .onHover { hoverNew = $0 }
                historyButton
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
        }
        // 必须顶掉安全区：.fullSizeContentView 下 SwiftUI 会按标题栏高度给内容加一段
        // 顶部安全区内缩，于是这条顶栏整体被压到红绿灯下面——「新对话」比三颗灯低一截，
        // 上面还空出一条（离屏拍出来才发现，2026-07-30）
        .ignoresSafeArea(edges: .top)
        // 不透明底（大梁老师 2026-07-31 定）。此前是 NSVisualEffectView 毛玻璃，
        // 透出背后桌面——看着好看，但窗内每一块的实际颜色都跟着桌面走，
        // 气泡、下拉、输入块得一个个改成确定性填充才稳得住。改成不透明之后这些都成了定值。
        // 纯黑又太硬，最终定在偏灰的一档（见 ChatWindowPalette）
        .background(ChatWindowPalette.background.ignoresSafeArea())
        // 这里原来有一道 1pt 亮边（想给玻璃做点厚度感）。大梁老师要去掉，
        // 而且它本身还错位：overlay 按安全区顶端摆，落在距窗顶 32pt 的标题栏下沿，
        // 看着就是横穿窗口的一条线（实测 2026-07-30）
        // 圆角与外描边交给系统：换成 .titled 之后窗口自带圆角并裁切内容，
        // 自己再画一个 16 只会跟系统圆角差一圈（各代 macOS 的半径还不一样）
    }

    /// 顶栏：左边模型名与连通状态，右边新对话与关闭，中间那条细横杠是拖拽区。
    ///
    /// 模型选择器与状态灯原先只长在刘海顶栏上（`ExpandedContentView`），
    /// 独立窗口第一版因此**看不到用的是哪个模型、也换不了**——这是我上一版的缺口，
    /// 借同一对组件补上，不另造一套
    /// 顶部只剩一个关闭按钮，整条是拖拽区。
    ///
    /// 走到这一版的经过（大梁老师 2026-07-29 连提三次）：
    /// 先是给「窗口级控件」开了一整行全宽顶栏，可它们只有几个小图标——
    /// 要么空出一大片，要么全挤在一边，他说「上面 DeepSeek 单独占了一行，留白很大」。
    /// 退回来看全局才发现：真正需要顶部空间的是**两列各自的内容**——
    /// 左列要「新对话」，右列的模型名则该贴着输入框（「谁来答」与「说什么」同域）。
    /// 于是全宽顶栏取消，这里只留关闭；每列上沿都被自己的东西填满，不再有空 band。
    ///
    /// 不画拖拽把手（他定的）：macOS 的标题栏本来也没有提示，光标形状就够了
    private var titleBar: some View {
        ZStack {
            // 产品名居中于**内容区**，不是整扇窗（大梁老师 2026-07-31 两轮才定）：
            // 上一版挪到整窗浮层，侧栏一开内容整体左移、标题却钉在原地不动，
            // 反而更怪。它属于左边这一栏，就该跟着这一栏走。
            //
            // 摆在 ZStack 底层而不是 HStack 中段——左右两侧按钮宽度不等，
            // 用 HStack 的话它会被挤得偏心
            Text("ProNotch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MarkdownTypography.textSecondary)
                .allowsHitTesting(false)      // 别挡住底下那条拖拽区
            HStack(spacing: 4) {
                // 左上角原来空 80 给系统红绿灯，现在换成「钉在桌面」开关
                // 图形固定，只有颜色变（大梁老师 2026-07-31：不要那道斜杠）
                iconButton("pin.fill",
                           hovering: hoverPin,
                           tip: controller.pinned ? "已钉在桌面（点击取消）" : "钉在桌面",
                           active: controller.pinned) {
                    controller.pinned.toggle()
                }
                .onHover { hoverPin = $0 }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        // 44：红绿灯藏掉之后不必再迁就它们的 16pt 中心线，顶栏可以放开
        //（大梁老师 2026-07-31 要「整体放大、顶栏可自适应加宽」）
        .frame(height: 44)
        // 拖拽垫在底层：关闭按钮先拿到点击，其余整条空白交给 AppKit 拖窗
        .background(WindowDragHandle())
    }

    /// 顶栏图标按钮：悬停才显底，静态只有一个淡图标——极简的前提是静态时安静。
    /// `active` 用于「钉在桌面」这种有开关态的键：亮起来用系统强调色，与底部控件同一语言
    private func iconButton(_ icon: String, hovering: Bool, tip: String,
                            active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color(nsColor: .controlAccentColor))
                                        : (hovering ? AnyShapeStyle(Color.white.opacity(0.92))
                                                    : AnyShapeStyle(MarkdownTypography.textSecondary)))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active
                                          ? Color(nsColor: .controlAccentColor).opacity(0.12)
                                          : Color.white.opacity(hovering ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // 自绘气泡而非 .help：这是非激活面板，系统 tooltip 在这儿不弹（与刘海同一处理）
        .notchTip(tip, edge: .below)
    }
}
