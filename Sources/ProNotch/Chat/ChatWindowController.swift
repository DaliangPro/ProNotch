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
final class ChatWindowController: NSObject, NSWindowDelegate {
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
        panel.level = .floating
        panel.isMovableByWindowBackground = false   // 拖动只认顶部那条把手，别抢内容里的拖拽
        panel.minSize = NSSize(width: 620, height: 380)
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

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
struct ChatWindowChrome: View {
    @EnvironmentObject var store: ChatStore
    @State private var hoverNew = false
    @State private var hoverHistory = false
    @State private var showHistory = false

    /// 历史会话开关。列表不再弹浮窗，而是从右侧推开一条侧边栏（大梁老师 2026-07-31）：
    /// 浮窗会盖住正文、点一下就消失，侧栏能一直开着对照着看
    private var historyButton: some View {
        iconButton("clock.arrow.circlepath", hovering: hoverHistory,
                   tip: showHistory ? "收起历史对话" : "历史对话") {
            withAnimation(.easeOut(duration: 0.18)) { showHistory.toggle() }
        }
        .onHover { hoverHistory = $0 }
        .accessibilityValue(showHistory ? "已展开" : "已收起")
    }

    /// 右侧历史对话侧栏。数据来自 ChatStore.conversations（真有），点一条即切过去
    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("历史对话")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MarkdownTypography.textTertiary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
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
        .background(ChatWindowPalette.surface1)
        // 只在左边描一道线：右边贴着窗沿，再描一条就成了双线
        .overlay(alignment: .leading) {
            Rectangle().fill(ChatWindowPalette.divider).frame(width: 1)
        }
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
            HStack(spacing: 0) {
                ChatView(host: .window)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showHistory { historySidebar.transition(.move(edge: .trailing)) }
            }
                // 下方留白由输入块自己给（22，与左右一致）。这里再加就叠成 36，
                // 底部会比两侧明显宽一圈——大梁老师要的是「左右和下方一致」
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
            // 窗口标识改成一个闪电（大梁老师 2026-07-31）：这扇窗叫「闪问」，
            // 一个图标比四个字更省地方也更认得出。
            // 摆在 ZStack 底层而不是 HStack 中段——左右两侧按钮宽度不等，
            // 用 HStack 的话它会被挤得偏心
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MarkdownTypography.textSecondary)
                .accessibilityLabel("AI 闪问")
            HStack(spacing: 2) {
                // 左上角空出来给系统红绿灯（它由窗口标题栏绘制，不在这棵视图树里）。
                // 三颗灯占到 x≈69（实测按钮原点 9 / 32 / 55，各 14 宽），留 80 才不压边
                Spacer().frame(width: 80)
                Spacer(minLength: 0)
                // 历史会话（任务书 §3.3.2，P2 条件项）：ChatStore 本来就存着会话列表，
                // 数据是真的才做——任务书禁止摆没功能的按钮
                historyButton
                iconButton("plus", hovering: hoverNew, tip: "新对话 ⌘N") {
                    store.newConversation()
                    store.focusInputTick += 1
                }
                .onHover { hoverNew = $0 }
            }
        }
        .padding(.horizontal, 12)
        // 34：红绿灯在标题栏里的中心约在距顶 16pt 处（实测按钮原点 y=9、高 14），
        // 这一行的按钮中心 17pt，两边基本平齐
        .frame(height: 34)
        // 拖拽垫在底层：关闭按钮先拿到点击，其余整条空白交给 AppKit 拖窗
        .background(WindowDragHandle())
    }

    /// 顶栏图标按钮：悬停才显底，静态只有一个淡图标——极简的前提是静态时安静
    private func iconButton(_ icon: String, hovering: Bool, tip: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.quaternary.opacity(hovering ? 1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // 自绘气泡而非 .help：这是非激活面板，系统 tooltip 在这儿不弹（与刘海同一处理）
        .notchTip(tip, edge: .below)
    }
}
