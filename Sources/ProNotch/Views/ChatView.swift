import SwiftUI

private extension View {
    /// 闪问出场元素的通用动效：从下方 offset 处升起淡入，靠 delay 错峰（发牌节奏）。
    /// 系统开了「减弱动态效果」就只留淡入，位移取消（任务书 §16.8 / §17.3）
    func chatRise(_ played: Bool, offset: CGFloat, delay: Double,
                  reduceMotion: Bool = false) -> some View {
        self.offset(y: (played || reduceMotion) ? 0 : offset)
            .opacity(played ? 1 : 0)
            .animation(reduceMotion
                       ? .easeOut(duration: 0.14).delay(delay)
                       : .spring(response: 0.38, dampingFraction: 0.66).delay(delay),
                       value: played)
    }
}

/// 会话栏 / 对话窗的统一外框：圆角 + 极淡填充 + 细描边，给左右两块明确边界
private struct ChatPanelFrame: ViewModifier {
    /// 独立窗口传 false：那边走「无框留白」。侧栏一个框、消息区一个框、输入框再一个框，
    /// 三层套嵌在独立窗口里像网页 div 拼的——这正是大梁老师说「不优雅」的地方（2026-07-29）
    var bordered = true
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(bordered ? 0.025 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(bordered ? 0.1 : 0), lineWidth: 1))
    }
}

/// 闪问长在哪儿。
///
/// 刘海页与独立窗口对四件事的答案完全不同：出场动画由谁驱动、粘贴监听何时生效、
/// 要不要按住「别收起刘海」、以及点「打开设置」之后收谁。
/// 这些差异靠 `NotchViewModel` 是表达不出来的——独立窗口里 `isExpanded`
/// 说的是刘海的状态，跟这个窗口毫无关系
enum ChatHost {
    /// 刘海展开态里的一页
    case notch
    /// 快捷键唤出的独立浮窗
    case window

    var inNotch: Bool { self == .notch }
}

/// AI 闪问：未配置时引导去设置；配置后左栏会话导航、右栏消息列表 + 输入框，流式输出
struct ChatView: View {
    /// 默认 .notch：刘海那边的调用点一处不用改（init 见 shownLimit 一节）
    var host: ChatHost

    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var quickActions: QuickActionsStore
    @EnvironmentObject var settings: SettingsStore

    @FocusState private var inputFocused: Bool
    @State private var pasteMonitor: Any?
    /// 出场动画开关：侧栏先起，消息气泡逐条发牌浮入，输入框最后弹（大梁老师选定的方案）
    @State private var entrancePlayed = false
    /// 侧栏宽度可拖调节（大梁老师定），持久化；拖中间分隔线改
    @AppStorage("chatSidebarWidth") private var sidebarWidth = 190.0
    @State private var dividerHover = false
    @State private var dragBaseWidth: Double?
    @State private var dividerCursorOn = false
    /// 消息视口的高度：窗口里拿来把内容压到底部，两处都拿来判断「是不是已经到底了」
    @State private var viewportHeight: CGFloat = 0
    /// 是否跟着新内容自动滚到底。
    ///
    /// 大梁老师 2026-07-31：AI 一边吐字页面一边往下滚，想翻上去看前面的内容根本按不住。
    /// 规则改成「粘底」：你一动滚轮就停止跟随，自己滚回底部（或发新消息）再自动恢复。
    /// 判据是**用户真的滚了**，不是「内容长出视口」——后者在流式输出时每一帧都成立，
    /// 拿它当判据等于永远不跟随
    @State private var followBottom = true
    /// 视口是否已接近底部（任务书 §12.1：距底 ≤ 80）。驱动「回到底部」按钮的显隐
    @State private var atBottom = true
    /// 一次最多渲染的消息数与「显示更早」每次追加的量（窗口与刘海都限——两处共享同一份对话）。
    ///
    /// 刘海只给 12（大梁老师 2026-07-31「还是卡」后从 40 砍下来的）：
    /// 哨兵实测切页 160~209ms、页面挂着的期间每一轮 60~128ms——
    /// 刘海视口本来只显得下三五条，挂 40 条等于让刘海里任何风吹草动
    /// （悬停、动画、周期刷新）都拖着整列重排。窗口维持 40
    static func defaultShownLimit(inNotch: Bool) -> Int { inNotch ? 12 : 40 }
    static func earlierChunk(inNotch: Bool) -> Int { inNotch ? 30 : 100 }
    @State private var shownLimit: Int

    init(host: ChatHost = .notch) {
        self.host = host
        _shownLimit = State(initialValue: Self.defaultShownLimit(inNotch: host.inNotch))
    }

    /// 留一份滚动代理给「回到底部」按钮用——它在 ScrollViewReader 的闭包外面
    @State private var scrollProxy: ScrollViewProxy?
    @State private var scrollMonitor: Any?

    /// 消息滚动区的坐标空间名；底部哨兵靠它算自己离视口顶部多远
    private static let scrollSpace = "chatMessageScroll"

    /// 系统开的「减弱动态效果」。开着就只留透明度变化，位移一律取消（任务书 §16.8）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 窗口宿主专用：内容列宽度冻结（拖缩期间，见 ChatWindowController.contentFrozen）
    @Environment(\.chatContentFrozen) private var contentFrozen
    /// 冻结那一刻的内容列宽；nil = 不冻。frame(width: nil) 是空操作，恰好当开关用
    @State private var frozenContentWidth: CGFloat?
    /// 冻结期间量到的最新值寄存处（引用类型、无 @Published：写它不触发任何视图更新）。
    /// 冻结的本意是拖缩期间一帧布局都别多跑，实测值照写就前功尽弃；
    /// 但也不能丢——解冻后 GeometryReader 的 onChange 不会为「没变的旧值」再来一次，
    /// 不寄存就永远错过最后那笔
    @State private var frozenMeasures = FrozenMeasureBox()

    private let edgeInset: CGFloat = 14

    /// 整窗宽度，用来决定内容列的左右留白档位（任务书 §6.3：>900 用 24，否则 16）
    @State private var windowWidth: CGFloat = 0
    /// 输入块的左右留白。**视觉边界以它为准**
    private var sideInset: CGFloat { windowWidth > 900 ? 24 : 16 }
    /// 输入框实测高度。内容底部要垫这么高才不会被它压住
    @State private var composerHeight: CGFloat = 0
    /// 正文的左右留白，**比输入块大一档**（大梁老师 2026-07-31）：
    /// 正文区因此比输入框窄，缩在它里面——一眼看到的那条边界线就只有输入框那一条。
    /// 我第一版理解反了做成了「正文更宽」，正文反而戳出输入框之外，边界成了两条
    private var textInset: CGFloat { sideInset + 16 }

    /// 量出来的布局值（视口高、输入块高、窗宽）统一从这里落盘：
    /// **取整、变了才写、下一圈 runloop 再写**。
    ///
    /// 为什么必须异步（2026-07-31，两次卡死的教训）：这些 GeometryReader 回调
    /// 都是在布局事务**里**被调的。同步写状态＝给当前这轮布局又添一笔新账，
    /// SwiftUI 会在同一次 flushTransactions 里接着算——账追着账，主线程就出不来了。
    /// 挪到下一圈之后，最坏情况也只是下一帧再修正一次，事件循环永远有喘息的空。
    /// 取整则是把亚像素抖动（108.4 ↔ 108.6 这种）直接压平，多数写入根本不发生
    private func deferAssign(_ target: Binding<CGFloat>, _ measured: CGFloat,
                             slot: ReferenceWritableKeyPath<FrozenMeasureBox, CGFloat?>? = nil) {
        // 冻结中：寄存不落盘（落盘＝触发一轮布局，冻结就白冻了）；解冻时统一 flush
        if contentFrozen, let slot {
            frozenMeasures[keyPath: slot] = measured
            return
        }
        let rounded = measured.rounded()
        guard abs(rounded - target.wrappedValue) >= 1 else { return }
        DispatchQueue.main.async {
            // 排队期间可能又量到了新值：落盘前再核对一次，别拿旧值盖新值
            if abs(rounded - target.wrappedValue) >= 1 { target.wrappedValue = rounded }
        }
    }

    /// 冻结期间量到的值的寄存处；见 frozenMeasures 的注释
    final class FrozenMeasureBox {
        var viewport: CGFloat?
        var composer: CGFloat?
        var window: CGFloat?
    }

    /// 每段对话固定的系统开场白（纯 UI 引导语，不进 store、不发给 API）
    private static let greeting = ChatMessage(role: .assistant, content: "想和我聊点什么？")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isConfigured, !host.inNotch {
                // 独立窗口：单栏。大梁老师定——这扇窗专管「问一句」，
                // 历史对话在刘海的闪问页里看，不必在这儿再摆一列
                // maxHeight 必须给：不给的话消息区只占内容高度，输入框紧跟其后，
                // 下面整片空着——大梁老师看到的「下面莫名其妙的大留白」就是这个
                // 消息**底部对齐**：贴着输入框往上堆，内容少时靠下。
                // 之前顶部对齐，四成窗口是死空白，一眼就是「没做完」。
                // 压底要知道视口多高，所以套 GeometryReader 量一下
                // 内容列：宽度 min(100%, 920) 且**水平居中**（任务书 §6.3 / §15.2）。
                // 原来是铺满整窗，窗口一拉宽正文就跟着摊开，左右留白也不对称
                // 输入框**浮在消息区之上**，消息区一直铺到窗底（大梁老师定，2026-07-31）：
                // 文字往下滚时，消失的那条线就是输入框的上沿，中间没有空档。
                //
                // 之前是 VStack 兄弟排布，消息区在输入框上方 8pt 就结束了，
                // 文字在离输入框还有一截的地方就没了——他连提两次的正是这一点，
                // 我却一直在改左右留白。
                //
                // 代价是内容会滑到输入框底下，所以内容底部必须垫出输入框那么高
                //（任务书 §6.3 的动态 bottom inset），否则最后一条永远被压住看不全
                ZStack(alignment: .bottom) {
                    // 这里**不再写 viewportHeight**。
                    //
                    // 它原来有两个写入者：这儿一个、messageList 里的 ScrollView 上还有一个。
                    // 两者量的几乎是同一块区域，只要差一丁点就互相改写——A 写完触发布局，
                    // 布局让 B 写，B 写完又触发布局让 A 写。这正是 SwiftUI 布局回环的
                    // 典型形状，拖动/拉缩时会把主线程拖垮（大梁老师 2026-07-31 报「卡死」）。
                    // 现在只留 ScrollView 上那一个写入者。
                    //
                    // 渐隐也顺手从 mask 换成覆盖渐变，理由见 fadeEdges
                    messageList
                        .fadeEdges(top: 14, bottom: 14, bottomInset: composerHeight,
                                   color: ChatWindowPalette.background)
                        .frame(maxHeight: .infinity)
                    // 正文两侧比输入框多留 16：正文缩在输入框以内，左右边界也只留输入框那一条
                    .padding(.horizontal, textInset)
                    windowComposer
                        // 整条底栏必须是**不透明**的，而且要铺到窗底。
                        //
                        // 只给输入框本身上底色是不够的：它外面还有左右与底部的外边距，
                        // 那圈边距是透明的，文字滚到那儿照样看得见——大梁老师看到的
                        // 「文字直接穿过去」就是这个（2026-07-31）。
                        // 背景加在**所有 padding 之后**，才连边距一起盖住
                        .background(ChatWindowPalette.background)
                        // 实测底栏高度喂给上面的内容内边距，行数一变就跟着变
                        .background(GeometryReader { g in
                            // 量出来的值一律：取整（压掉亚像素抖动）＋异步写（不给当前布局添账）
                            Color.clear
                                .onAppear { deferAssign($composerHeight, g.size.height, slot: \.composer) }
                                .onChange(of: g.size.height) { _, h in
                                    deferAssign($composerHeight, h, slot: \.composer)
                                }
                        })
                }
                .frame(maxWidth: 920)
                // 冻结期间钉住列宽：宽度变化只表现为平移和边缘裁切（帧帧便宜），
                // 正文完全不断行；放开的那一帧一次断行到位
                .frame(width: frozenContentWidth)
                // 第二个 frame 才是「居中」：上一个只限宽，不限位置
                .frame(maxWidth: .infinity)
                // 量整窗宽度决定留白档位。用 background 量，不参与布局
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { deferAssign($windowWidth, g.size.width, slot: \.window) }
                        .onChange(of: g.size.width) { _, w in deferAssign($windowWidth, w, slot: \.window) }
                })
                .onChange(of: contentFrozen) { _, frozen in
                    // 冻结那刻抓当前列宽钉住；放开置回 nil（宽度还没量到就不钉，防 width: 0）
                    frozenContentWidth = (frozen && windowWidth > 0) ? windowWidth : nil
                    if !frozen {
                        // 冻结期间寄存的实测值，现在一次落盘
                        if let v = frozenMeasures.viewport { deferAssign($viewportHeight, v) }
                        if let v = frozenMeasures.composer { deferAssign($composerHeight, v) }
                        if let v = frozenMeasures.window { deferAssign($windowWidth, v) }
                        frozenMeasures.viewport = nil
                        frozenMeasures.composer = nil
                        frozenMeasures.window = nil
                    }
                }
            } else if store.isConfigured {
                // 左栏会话导航 + 右栏对话窗（大梁老师定的双栏结构）
                HStack(spacing: 0) {
                    // 左框：会话记录
                    ConversationSidebar()
                        .frame(width: CGFloat(sidebarWidth))
                        .frame(maxHeight: .infinity)
                        .modifier(ChatPanelFrame(bordered: host.inNotch))
                        .chatRise(entrancePlayed, offset: 16, delay: 0, reduceMotion: reduceMotion)
                    sidebarDivider
                    // 右框：对话窗（消息区 + 输入框）。气泡在 messageList 内逐条发牌，
                    // 输入框等最后一张牌落定后再弹（像键盘弹出收尾）
                    VStack(alignment: .leading, spacing: 8) {
                        messageList
                        inputBar
                            .chatRise(entrancePlayed, offset: 24,
                                      delay: dealDelay(store.messages.count) + 0.08,
                                      reduceMotion: reduceMotion)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, host.inNotch ? 10 : 16)
                    .padding(.vertical, 8)
                    .modifier(ChatPanelFrame(bordered: host.inNotch))
                }
                .frame(maxHeight: .infinity)
            } else {
                // 未配置：引导去应用「设置 → AI 闪问」填接口（刘海内不再放设置表单）
                chatUnconfiguredGuide
            }
        }
        // 左右留白对齐全局基准线（见 ExpandedContentView.pageHInset）
        .padding(.horizontal, host.inNotch ? ExpandedContentView.pageHInset : 0)
        // 独立窗口传 true：那边 isExpanded 是刘海的状态，等它等不到，整页会停在透明
        // 刘海：切页进来内容即现，发牌只在展开那一下播（大梁老师 2026-07-31）；
        // 独立窗口保持首开播出场
        .pageEntrance($entrancePlayed, active: host.inNotch ? nil : true,
                      replayOnRemount: !host.inNotch)
        .onAppear {
            store.checkConnectivity()
            installPasteMonitor()
            installScrollMonitor()
        }
        .onDisappear {
            if host.inNotch { vm.keyboardHold = false }
            setDividerCursor(false)
            if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor); pasteMonitor = nil }
            if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor); scrollMonitor = nil }
        }
        // 悬停分隔线时被收起：onHover(false) 不会再来，补一次收光标防残留
        .onChange(of: vm.isExpanded) { _, expanded in
            if host.inNotch, !expanded {
                setDividerCursor(false)
                dividerHover = false
                dragBaseWidth = nil
            }
        }
    }

    /// 未配置态：刘海内不再放设置表单，改为引导跳应用「设置 → AI 闪问」页
    private var chatUnconfiguredGuide: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 24)).foregroundColor(.white.opacity(0.3))
            Text(store.providers.count > 1 ? "这套配置还没填 Key" : "还没配置 AI 接口")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.65))
            Text(store.providers.count > 1
                 ? "点右上角切到已配好的那套，或去「设置 → AI 闪问」补全这套"
                 : "在「设置 → AI 闪问」填入 API 地址、Key 和模型即可开聊")
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                settings.pendingSection = SettingsView.Section.chat.rawValue
                quickActions.openAppSettings()
                // 让路给弹出的设置窗：刘海是收起，独立窗口是关掉自己
                if host.inNotch { vm.collapseNow() } else { ChatWindowController.shared.hide() }
            } label: {
                Text("去设置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, edgeInset)
        .chatRise(entrancePlayed, offset: 16, delay: 0, reduceMotion: reduceMotion)
    }

    /// 可拖拽的侧栏分隔线：1pt 视觉线 + 7pt 热区，悬停变左右箭头光标，拖动调宽 150–300
    private var sidebarDivider: some View {
        Rectangle()
            // 两侧已有边框，静态时分隔线隐形，仅悬停/拖拽淡显作提示
            .fill(Color.white.opacity(dividerHover || dragBaseWidth != nil ? 0.28
                                                                          : (host.inNotch ? 0 : 0.05)))
            .frame(width: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onHover { inside in
                dividerHover = inside
                if inside {
                    setDividerCursor(true)
                } else if dragBaseWidth == nil {
                    // 拖拽中滑出热区不收光标，onEnded 再补
                    setDividerCursor(false)
                }
            }
            // 必须用 .global 坐标系：分隔线本身随 sidebarWidth 移动，local translation 参照系
            // 会跟着漂移形成反馈震荡（上一版「不跟手」的根因）。全局坐标下位移量稳定
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if dragBaseWidth == nil { dragBaseWidth = sidebarWidth }
                    sidebarWidth = min(300, max(150, (dragBaseWidth ?? 190) + v.translation.width))
                }
                .onEnded { _ in
                    dragBaseWidth = nil
                    if !dividerHover { setDividerCursor(false) }
                })
    }

    /// 把「手上有活没干完」的判定结果同步给刘海（判据与理由见 ChatStore.shouldHoldNotch）
    private func syncKeyboardHold() {
        // 独立窗口不会自动收起，这把锁在那边没有意义；碰它反而会误锁刘海
        guard host.inNotch else { return }
        vm.keyboardHold = ChatStore.shouldHoldNotch(inputFocused: inputFocused,
                                                    draft: store.draftMessage,
                                                    streaming: store.isStreaming)
    }

    /// 左右箭头光标开关：push/pop 必须成对，走这一个口
    private func setDividerCursor(_ on: Bool) {
        guard on != dividerCursorOn else { return }
        dividerCursorOn = on
        if on { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }

    /// ⌘V 粘贴图片为附件：菜单 Paste 的 key equivalent 会先于 SwiftUI onKeyPress 吃掉 ⌘V，
    /// 用本地事件监听在分发前拦截。剪贴板是图片（截图/网页图/图片文件通用）→ 挂为附件；
    /// 是文字 → 放行走系统粘贴。仅在面板展开且停留在闪问页时生效
    /// 滚轮监听：用户手动滚一下就停止自动跟随。
    ///
    /// 只认「用户真的滚了」这一个信号。若改用「内容超出视口」之类的几何判据，
    /// 流式输出时每帧都成立，等于永远不跟随
    /// 输入法是否正在组合（有未上屏的候选词）。
    /// 取当前 key 窗口的字段编辑器问 `hasMarkedText`——这是 macOS 唯一可靠的判据
    static func isComposing() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let vm = self.vm
        let follow = $followBottom
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                let active = host.inNotch ? (vm.isExpanded && vm.activeTab == .chat)
                                          : ChatWindowController.shared.isKeyWindow
                if active, event.scrollingDeltaY != 0 { follow.wrappedValue = false }
            }
            return event
        }
    }

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        let vm = self.vm
        let store = self.store
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let attached = MainActor.assumeIsolated {   // 事件监听在主线程回调
                guard host.inNotch ? (vm.isExpanded && vm.activeTab == .chat)
                                   : ChatWindowController.shared.isKeyWindow,
                      store.isConfigured,
                      let image = NSImage(pasteboard: .general) else { return false }
                store.attachScreenshot(image)
                AppLog.chat.info("已从剪贴板粘贴图片为闪问附件")
                return true
            }
            return attached ? nil : event
        }
    }

    /// 只错峰视口附近的最后几条：滚动停在底部，更早的消息在视口外，
    /// 与侧栏同批直接就位；错峰太多条只会拖长收尾
    private static let dealWindow = 4

    /// 发牌延迟：chronoIndex 为时序序号（0 = 开场白），窗口内每条隔 0.06s 依次浮入
    private func dealDelay(_ chronoIndex: Int) -> Double {
        let total = store.messages.count + 1   // 含开场白
        let windowStart = max(0, total - Self.dealWindow)
        return 0.05 + 0.06 * Double(max(0, chronoIndex - windowStart))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // 消息之间的间距也从正文推（窗口 14×1.7≈24）：一问一答之间要能一眼分开。
                //
                // **VStack，不是 LazyVStack**（2026-07-31 第三次卡死后定）。
                // 三次卡死采样的共同常量都是 LazySubviewPlacements 反复重算：
                // 往上滚要现建上面的行，真实高度与估计值不同→内容总高变→
                // 贴底对齐让全体位置平移→可见区映射到另一批行→再建/拆→高度再变……
                // 懒加载摆位在「变高内容 + 贴底对齐」下没有不动点，主线程整段锁死。
                // 全量渲染几十条消息是毫秒级的事（scrollTo 落底本来就会把整列建全），
                // 换来的是这台机器从窗口里彻底消失——想改回 Lazy，先拿出
                // 「贴底 + 上滚」不再触发 LazySubviewPlacements 循环的实测证据
                VStack(spacing: MarkdownTypography(body: host.inNotch ? 12 : 14,
                                                   compact: host.inNotch).messageSpacing) {
                    // 开场白只在刘海里出现。独立窗口是「问一句就走」的地方，
                    // 一句硬编码的装饰语占着最显眼的位置，却不进对话也不发 API，纯占位
                    if host.inNotch {
                        MessageBubble(message: Self.greeting, streaming: false, searching: false,
                                      windowStyle: false)
                            .chatRise(entrancePlayed, offset: 14, delay: dealDelay(0), reduceMotion: reduceMotion)
                    }
                    // 超长对话只渲染最近一段（大梁老师 2026-07-31「还是卡顿」后定）：
                    // 消息列表已是全量渲染（Lazy 会卡死，不能回去），几百条的老对话
                    // 每次断行就是几百条的账。屏幕上常看的只有最近几十条，
                    // 更早的收在顶部一个按钮后面，点一下再多放一段。
                    // **刘海同样限**：头一版只限了窗口，以为「刘海列表本来就短」——
                    // 错了，两处共享同一份对话，切到闪问页就是把几百条一口气建全，
                    // 正是他说「切到这一页非常卡」的原因（2026-07-31）
                    let hiddenCount = max(0, store.messages.count - shownLimit)
                    if hiddenCount > 0 {
                        Button {
                            shownLimit += Self.earlierChunk(inNotch: host.inNotch)
                        } label: {
                            Text("显示更早的 \(min(hiddenCount, Self.earlierChunk(inNotch: host.inNotch))) 条")
                                .font(.system(size: host.inNotch ? 10 : 11, weight: .medium))
                                .foregroundStyle(MarkdownTypography.textSecondary)
                                .padding(.horizontal, host.inNotch ? 9 : 12)
                                .padding(.vertical, host.inNotch ? 4 : 6)
                                .background(Capsule().fill(host.inNotch
                                    ? Color.white.opacity(0.08) : ChatWindowPalette.surface1))
                                .overlay(Capsule().strokeBorder(host.inNotch
                                    ? Color.white.opacity(0.12) : ChatWindowPalette.border,
                                    lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, host.inNotch ? 2 : 6)
                        .accessibilityLabel("显示更早的消息")
                    }
                    // enumerated 只为算发牌延迟；id 仍取 message.id，流式更新不重建气泡
                    ForEach(Array(store.messages.dropFirst(hiddenCount).enumerated()),
                            id: \.element.id) { i, message in
                        MessageBubble(message: message,
                                      streaming: store.isStreaming
                                          && message.id == store.messages.last?.id,
                                      searching: store.isSearching,
                                      windowStyle: !host.inNotch,
                                      // 只有最后一条能重来：重生成会丢掉这条与它上面那问，
                                      // 中间某条重来会把后面的对话一起截断（任务书 §8.4 没要求那样）
                                      onRegenerate: (!host.inNotch && !store.isStreaming
                                          && message.id == store.messages.last?.id)
                                          ? { store.regenerateLast() } : nil)
                            .chatRise(entrancePlayed, offset: 14, delay: dealDelay(i + 1), reduceMotion: reduceMotion)
                    }
                    if let error = store.errorText {
                        // 失败必须在界面上可见、且能重试；用户原文保留在会话里不清空
                        //（任务书 §14.6）
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(error)
                                .font(.system(size: host.inNotch ? 10 : 12))
                                .foregroundColor(.red.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                            if !host.inNotch, !store.isStreaming {
                                Button { store.retryLast() } label: {
                                    Text("重试")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                        .background(Capsule().fill(Color.white.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 提醒不是报错（如模型不支持关深度思考）：回复照常出，用灰橙色说一句就够
                    if let notice = store.noticeText {
                        Text(notice)
                            .font(.system(size: 10))
                            .foregroundColor(.orange.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 垫出输入框那么高：内容滑到底时最后一行正好停在输入框上沿，
                    // 而不是被压在它下面（任务书 §6.3 / §12.3）
                    Color.clear.frame(height: host.inNotch ? 1 : max(composerHeight, 1))
                        .id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(
                                key: BottomAnchorKey.self,
                                value: g.frame(in: .named(Self.scrollSpace)).maxY)
                        })
                }
                .padding(.trailing, host.inNotch ? 2 : 0)
                // 不足一屏时压到底部；刘海不用，那儿本来就是满的
                .frame(minHeight: host.inNotch ? nil : viewportHeight, alignment: .bottom)
            }
            .coordinateSpace(name: Self.scrollSpace)
            // 用 background 量高度：不参与布局，不会改变原有的伸缩行为
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { deferAssign($viewportHeight, g.size.height, slot: \.viewport) }
                    .onChange(of: g.size.height) { _, h in
                        deferAssign($viewportHeight, h, slot: \.viewport)
                    }
            })
            .onPreferenceChange(BottomAnchorKey.self) { y in
                // 冻结期间不理会：值在拖缩中乱跳，写进去只会白触发按钮显隐动画。
                // 解冻的那次宽度落盘会重排一轮，preference 自会带着新值再来
                guard !contentFrozen else { return }
                // 底部哨兵离视口底还有多远。任务书 §12.1 的「接近底部」阈值是 80
                guard viewportHeight > 0 else { return }
                let distance = y - viewportHeight
                let nearBottom = distance <= 80
                // 回到底部即恢复跟随（留 24pt 容差，比「接近」更严，免得刚滚一点就又被拽下去）
                let shouldFollow = distance <= 24
                // **挪到下一圈 runloop 再写**。这个回调是在布局事务里被调的，
                // 此刻同步写状态＝给当前这轮布局又添一笔新账，账追着账，
                // flushTransactions 就出不来了——两次卡死采样都是这个形状（2026-07-31）。
                // 异步之后最坏也就是下一帧再修正，主线程永远能回到事件循环
                DispatchQueue.main.async {
                    if atBottom != nearBottom { atBottom = nearBottom }
                    if shouldFollow, !followBottom { followBottom = true }
                }
            }
            // 「回到底部」：离底 80pt 以上才出现（任务书 §12.2）。
            // 压在消息区右下角而不是居中——居中会正好盖住最后一行正文。
            //
            // **常驻 + 只变透明度**，绝不用 if 插拔，动画也只挂在按钮自己身上。
            // 原来是 `if !atBottom { ... }` 外加整棵滚动子树上一个
            // `.animation(value: atBottom)`——这是 2026-07-31 第二次卡死的振荡器：
            // atBottom 由布局量出来（离底距离），一翻转就让整个消息区起动画，
            // 动画中间帧又让距离在 80 阈值上来回穿越，atBottom 再翻转、动画重启……
            // 采样里 ViewListTransition/LazyTransition/InterpolatedDisplayList
            // 反复更新就是它。透明度是纯绘制属性，动不了布局，环从根上断掉
            .overlay(alignment: .bottom) {
                if !host.inNotch {
                    Button {
                        followBottom = true
                        if reduceMotion {
                            scrollProxy?.scrollTo("bottom", anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.16)) {
                                scrollProxy?.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(ChatWindowPalette.surface1))
                            .overlay(Circle().strokeBorder(ChatWindowPalette.border, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .notchTip("回到底部", edge: .aboveLeading)
                    .accessibilityLabel("回到底部")
                    .accessibilityHidden(atBottom)
                    .padding(.bottom, 8)
                    .opacity(atBottom ? 0 : 1)
                    .allowsHitTesting(!atBottom)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: atBottom)
                }
            }
            .onChange(of: store.messages.last?.content) { _, _ in
                guard followBottom else { return }
                // 异步：这个 onChange 在数据事务里被调，同步 scrollTo 会当场触发整列重排；
                // 挪到下一圈还能把连续到达的 token 合并成一次滚动
                DispatchQueue.main.async { scrollProxy?.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.currentID) { _, _ in
                // 切会话后等新列表上屏再落底；渲染限额同时复位（别把上个会话的扩容带过来）
                shownLimit = Self.defaultShownLimit(inNotch: host.inNotch)
                followBottom = true
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                followBottom = true
                scrollProxy = proxy
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {   // 输入框长高时按钮贴底（IM 习惯）
            Button {
                store.webSearchEnabled.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundColor(store.webSearchEnabled ? .cyan : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            // 用自绘气泡而非 .help：刘海是非激活面板，系统 tooltip 在这儿根本不弹
            .notchTip(store.webSearchEnabled
                ? "联网搜索已开启：先搜索再回答（点击关闭）"
                : "联网搜索已关闭：只用模型自身知识（点击开启）", edge: .aboveLeading)
            // 深度思考随手开关：DeepSeek v4 这类混合模型默认先想一轮，闲聊问答用不上，
            // 关掉明显更快。跟地球图标同一排——都是「这一问怎么答」的即时选择
            Button {
                store.thinkingEnabled.toggle()
            } label: {
                ThinkingBubbleIcon()
                    .foregroundColor(store.thinkingEnabled ? .cyan : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .notchTip(store.thinkingEnabled
                ? "深度思考已开启：模型先推理再作答，更准也更慢（点击关闭）"
                : "深度思考已关闭：直接作答，更快（点击开启）", edge: .aboveLeading)
            // 默认单行、随内容增长到最多 6 行：粘贴带换行的内容也能看全。
            // 回车发送，⌘回车换行（IM 习惯；系统自带的 ⌥回车也保留）
            if let data = store.draftAttachment, let img = NSImage(data: data) {
                // 待发送的截图附件：缩略图 + 移除；随下一条消息发给视觉模型
                HStack(spacing: 6) {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("已附截图").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                    Button { store.draftAttachment = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                    }.buttonStyle(.plain)
                }
            }
            TextField("", text: $store.draftMessage,
                      prompt: Text("输入问题，回车发送 · ⌘回车换行")
                          .foregroundColor(.white.opacity(0.3)),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .onKeyPress(.return, phases: .down) { press in
                    // ⌘回车 = 在光标处插入换行（走字段编辑器，与 ⌥回车同一原生路径）
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                    }
                    return .ignored
                }
                // 三个信号任一变化都重算「该不该挡住自动收起」（判据见 syncKeyboardHold）
                .onChange(of: inputFocused) { _, _ in syncKeyboardHold() }
                .onChange(of: store.draftMessage) { _, _ in syncKeyboardHold() }
                .onChange(of: store.isStreaming) { _, _ in syncKeyboardHold() }
                .onChange(of: store.focusInputTick) { _, _ in inputFocused = true }
            if store.isStreaming {
                Button {
                    store.stopStreaming()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("停止")
            } else {
                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(store.draftMessage.isEmpty
                            ? .white.opacity(0.25) : .white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(store.draftMessage.isEmpty)
                .help("发送")
            }
        }
        .padding(.horizontal, host.inNotch ? 10 : 14)
        .padding(.vertical, host.inNotch ? 6 : 9)
        // 刘海里是贴着面板的方角输入框；独立窗口改成悬浮胶囊 + 阴影，与背景脱开——
        // 无框布局里如果它也没有边界，就看不出「这儿能打字」
        .background {
            if host.inNotch {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
            } else {
                Capsule().fill(Color(white: 0.115))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            }
        }
    }

    /// 独立窗口的输入区：一个块，**模型选择器就在里面**。
    ///
    /// 大梁老师的原话：「他选模型的那个位置，为什么不能跟输入框在一起呢」。
    /// 之前我把它摆在输入框外面下方，隔了一层；现在收进块内下行，
    /// 和联网、思考、附件、发送排成一家人（DeepSeek 网页版、ChatGPT 都是这个做法）。
    ///
    /// 配色一律走系统语义色而不是刘海那套 `white.opacity(...)` 叠层——
    /// 这扇窗的底是毛玻璃，透着桌面，只有语义色自带的 vibrancy 才保证文字始终清楚
    private var windowComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 「截图问 AI」挂进来的待发附件。上面那句注释里早写了「附件」，
            // 实现却一直只有刘海那份 `inputBar` 有——独立窗口这边漏了整段，
            // 于是截图挂上了、也确实会随下一条消息发出去，但输入区一点提示都没有，
            // 看着像功能没生效（大梁老师 2026-08-08：「为什么它不会把截图自动放进输入框」）。
            // 而截图问 AI 打开的**正是**这扇窗，等于这条路上必然踩空
            if let data = store.draftAttachment, let img = NSImage(data: data) {
                windowAttachmentChip(img)
            }
            TextField("", text: $store.draftMessage,
                      prompt: Text("问点什么…").foregroundStyle(.tertiary),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                // 单行时也留出 32 的高度：输入区太扁，光标像贴在边上（大梁老师 2026-07-31）
                .frame(minHeight: 32, alignment: .topLeading)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .onKeyPress(.return, phases: .down) { press in
                    // 换行：⌘回车与 ⇧回车都认（大梁老师 2026-07-31 定「两个都支持」）。
                    // 系统自带的 ⌥回车也仍然有效
                    guard press.modifiers.contains(.command)
                            || press.modifiers.contains(.shift) else { return .ignored }
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: store.focusInputTick) { _, _ in inputFocused = true }
                .padding(.top, 2)
            HStack(spacing: 7) {
                ModelSwitcher(dropUp: true)
                // 图标与刘海用同一套（大梁老师定）：地球 + 那张思考气泡原件，
                // 同一个功能在两处不该长两个样
                // 中文加回来，并且深度思考在前、联网在后（大梁老师 2026-07-31 两次调整：
                // 先去字只留图标，再改回带字并互换位置）
                windowToolChip("深度思考", on: store.thinkingEnabled,
                               action: { store.thinkingEnabled.toggle() }) {
                    ThinkingBubbleIcon(side: 15)
                }
                windowToolChip("联网", on: store.webSearchEnabled,
                               action: { store.webSearchEnabled.toggle() }) {
                    Image(systemName: "globe").font(.system(size: 13))
                }
                Spacer(minLength: 4)
                if store.isStreaming {
                    Button { store.stopStreaming() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 27, height: 27)
                            .background(Circle().fill(.secondary))
                    }
                    .buttonStyle(.plain)
                    .notchTip("停止生成 Esc", edge: .aboveLeading)
                    .accessibilityLabel("停止生成")
                } else {
                    Button { sendDraft() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(store.draftMessage.isEmpty ? AnyShapeStyle(.secondary)
                                                                        : AnyShapeStyle(Color.black))
                            .frame(width: 27, height: 27)
                            .background(Circle().fill(store.draftMessage.isEmpty
                                                      ? AnyShapeStyle(.quaternary)
                                                      : AnyShapeStyle(.white)))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.draftMessage.isEmpty)
                    .notchTip("发送 Enter", edge: .aboveLeading)
                    .accessibilityLabel("发送")
                }
            }
            // 左侧外探 8：胶囊离输入框内壁 4pt，左下角与外圆角同心，
            // 模型名文字仍落在 12 的竖线上（胶囊自带 8 内边距，4 + 8 = 12）。
            // 右侧只外探 2：发送键离内壁 10pt——原来也是 4，大梁老师 2026-08-01
            // 反馈「离边有点近，留白不够舒适」；右下角的同心让位给呼吸感
            .padding(.leading, -8)
            .padding(.trailing, -2)
        }
        // 内边距 12 与气泡的 12 一致：输入框占位符、模型名和气泡里的正文
        // 因此落在同一条竖线上（大梁老师要「文字之间有对齐关系」）。
        // 下边只留 4：控件行整体下移、底部留白收窄（大梁老师 2026-07-31），
        // 这个 4 不是随手定的，见下面圆角同心的算法
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
        // 比窗口材质更厚一层：层级靠材质厚薄编码，不靠描边（Apple 的做法）
        // 只靠材质分不出层：深色下 regularMaterial 和窗口底几乎同色（实测拍出来糊成一片）。
        // 叠一层浅填充 + 一道细描边，层级要看得出来才叫层级
        .background {
            // 用确定色而不是材质：材质会跟着背后的东西走，换一档底色就翻车。
            //
            // **半径 17 是算出来的，不是挑的**：模型胶囊高 26 ⇒ 圆角 13，
            // 它离输入框内壁 4pt（外层 12 − 控件行外探 8），要让两条弧线看着平行，
            // 两个圆心必须重合 ⇒ 外圆角 = 13 + 4 = 17。
            // 底部留白同样取 4，左下角才真的同心（大梁老师：「曲度视觉平行」）
            let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
            shape.fill(ChatWindowPalette.surface1)
                // 聚焦时四周一圈淡光晕，颜色跟系统强调色走（大梁老师 2026-07-31）。
                // 两层影子叠：近的一层实一点勾出轮廓，远的一层散开当光。
                // 用 shadow 而不是加粗描边——描边是「框」，影子才是「光」
                .shadow(color: inputFocused ? Self.accent.opacity(0.26) : .clear,
                        radius: 4)
                .shadow(color: inputFocused ? Self.accent.opacity(0.16) : .clear,
                        radius: 13)
                .overlay(shape.strokeBorder(inputFocused ? Self.accent.opacity(0.32)
                                                         : ChatWindowPalette.border,
                                            lineWidth: inputFocused ? 0.8 : 0.5))
        }
        .animation(.easeOut(duration: 0.18), value: inputFocused)
        // 外缘与消息栏同一档（§6.3），左右下三边一条线
        .padding(.horizontal, sideInset).padding(.bottom, 16)
    }

    /// 系统强调色（跟「系统设置 → 外观 → 强调色」走）
    private static var accent: Color { Color(nsColor: .controlAccentColor) }

    private func windowToolChip<Icon: View>(_ title: String, on: Bool,
                                            action: @escaping () -> Void,
                                            @ViewBuilder icon: @escaping () -> Icon) -> some View {
        WindowToolChip(title: title, on: on, accent: Self.accent, action: action, icon: icon)
    }

    /// 待发截图的附件条：缩略图 + 说明 + 移除。
    ///
    /// 摆在输入框**上方**而不是收进底下那行控件：截图看不清就等于没附，
    /// 而控件行里塞得下的高度（26）根本看不出图里是什么。
    /// 嵌在输入框里就用 surface2——比输入框底 surface1 再亮一档，是「块中块」的层级
    private func windowAttachmentChip(_ img: NSImage) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 54, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(ChatWindowPalette.border, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text("已附截图").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text("随下一条消息一起发给模型").font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            // 不放 Spacer：卡片收缩到内容宽度，× 紧跟文字。
            // 铺满整宽的话它就成了一条横带子，× 被推到窗口最右边，
            // 离「已附截图」十万八千里，看不出是在删这个东西
            Button { store.draftAttachment = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .notchTip("移除截图", edge: .aboveLeading)
            .accessibilityLabel("移除截图")
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(ChatWindowPalette.surface2))
        .padding(.top, 2)
    }

    private func sendDraft() {
        // **输入法正在选词时不许发送**（任务书 §10.1.6）。
        //
        // 中文输入时按回车是「确认候选词」，不是「发消息」。SwiftUI 的 onSubmit
        // 分不清这两者，于是打一半的拼音一按回车就被当成问题发出去了。
        // macOS 上的判据是字段编辑器有没有 marked text（未上屏的组合中文字）
        guard !Self.isComposing() else { return }
        // 自己发了新消息＝注意力回到最新一条，恢复自动跟随
        followBottom = true
        let text = store.draftMessage
        store.draftMessage = ""
        store.send(text)
    }
}

/// 左栏会话导航：新对话入口 + 按最近更新排序的会话列表；当前项高亮、悬停出删除
private struct ConversationSidebar: View {
    @EnvironmentObject var store: ChatStore

    var body: some View {
        VStack(spacing: 4) {
            NewConversationButton { store.newConversation() }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.sortedConversations) { conv in
                        ConversationRow(
                            conv: conv,
                            isCurrent: conv.id == store.currentID,
                            isStreaming: store.isStreaming && conv.id == store.streamingConvID,
                            select: { store.selectConversation(conv.id) },
                            delete: { store.deleteConversation(conv.id) })
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct NewConversationButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("新对话")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.13 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 侧栏一行会话：标题 + 相对时间；点击切换，悬停出删除，流式回复中显示菊花
private struct ConversationRow: View {
    let conv: ChatConversation
    let isCurrent: Bool
    let isStreaming: Bool
    let select: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(conv.title.isEmpty ? "新对话" : conv.title)
                    .font(.system(size: 11, weight: isCurrent ? .medium : .regular))
                    .foregroundColor(.white.opacity(isCurrent ? 0.92 : 0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isStreaming {
                    ProgressView().controlSize(.mini)
                } else if hovering {
                    Button(action: delete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("删除该对话")
                }
            }
            Text(Self.timeText(conv.updatedAt))
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(isCurrent ? 0.12 : (hovering ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    private static func timeText(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 90 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}

private extension View {
    /// 上下两端的薄渐隐。
    ///
    /// **用覆盖渐变而不是 mask**：mask 要把整棵消息树先离屏合成一遍再按遮罩取样，
    /// 拖动窗口/拉缩时每帧都来一次，是卡顿的大头。
    /// 窗口底色是不透明的纯色，所以「底色 → 透明」的两条渐变盖上去，
    /// 视觉上和 mask 一模一样，代价只是画两个矩形。
    ///
    /// `bottomInset` 是输入框高度：消息区铺到窗底、下半截压在输入框底下，
    /// 下沿的渐隐必须落在输入框**上沿**才看得见
    func fadeEdges(top: CGFloat, bottom: CGFloat,
                   bottomInset: CGFloat, color: Color) -> some View {
        overlay(alignment: .top) {
            LinearGradient(colors: [color, color.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: top)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [color.opacity(0), color],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: bottom)
                .padding(.bottom, bottomInset)
                .allowsHitTesting(false)
        }
    }
}

/// 输入框底行的一个控件（联网 / 深度思考）。
///
/// 与模型胶囊共用同一套容器语言：同高 28、同圆角、**静态一律无底色**，
/// 状态只用前景色表达，开启时才补一层极淡的同色底。
///
/// 独立成 struct 是因为要自己记悬停态——原来写成方法拿不到 @State，
/// 只能靠彩底加描边来表达开启，那圈描边正是大梁老师说的「光感效果不好」
private struct WindowToolChip<Icon: View>: View {
    let title: String
    let on: Bool
    let accent: Color
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // 图标 + 中文（大梁老师 2026-07-31 又要回来了）。
            // 与模型胶囊同高 28、同圆角、静态无底色——三个控件仍是同一套容器语言
            HStack(spacing: 5) {
                icon()
                Text(title).font(.system(size: 11.5))
            }
            .foregroundStyle(on ? AnyShapeStyle(accent)
                                : AnyShapeStyle(MarkdownTypography.textSecondary))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                Capsule().fill(on ? accent.opacity(0.12)
                                  : Color.white.opacity(hovering ? 0.07 : 0))
            }
            // 热区 32 高（任务书 §10.2.5 / §16.5），视觉仍是 28
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .notchTip(on ? "\(title)已开启（点击关闭）" : "\(title)已关闭（点击开启）",
                  edge: .aboveLeading)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "已开启" : "已关闭")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// 底部哨兵在滚动视口坐标系里的下沿位置。
/// 它 ≤ 视口高度 ＝ 已经滚到底，可以恢复自动跟随
private struct BottomAnchorKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let streaming: Bool
    let searching: Bool
    /// 独立窗口的排版：正文 14pt、两侧都套气泡、走系统语义色与材质。
    ///
    /// AI 的回答一度是不套框的整段文字（想着长文读起来松快），
    /// 但大梁老师定下两边都要气泡（2026-07-30）——一眼能分清谁说的比松快更重要
    var windowStyle = false

    @State private var sourcesExpanded = false
    @State private var showAllSources = false
    @State private var copied = false
    @State private var hovering = false
    /// 「重新生成」由外面接：Store 的动作不该埋在气泡里
    var onRegenerate: (() -> Void)?

    /// 独立窗口里的 AI 回答：不套气泡，直接落在画布上（任务书 §8.1）。
    /// 刘海仍保留淡框——那儿是窄带，没有背景就分不出一条条消息
    private var flatOnCanvas: Bool { windowStyle && message.role == .assistant }

    /// 这条消息用哪套排版度量。刘海走紧凑档，独立窗口走舒适档
    private var type: MarkdownTypography {
        MarkdownTypography(body: windowStyle ? 14 : 12, compact: !windowStyle)
    }

    var body: some View {
        HStack {
            // 两侧都留空档：气泡才有「贴着一边」的形，不然就是一条通栏
            // 用户气泡最大宽度 min(68%, 640)（任务书 §6.5）——靠左侧空档挤出来
            if message.role == .user { Spacer(minLength: windowStyle ? 64 : 80) }
            Group {
                if message.content.isEmpty && streaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(searching ? "正在联网搜索…" : "正在生成…")
                            .font(.system(size: windowStyle ? 12.5 : 11))
                            .foregroundColor(.white.opacity(windowStyle ? 0.64 : 0.5))
                    }
                    .padding(4)
                    // 读屏只播报这一句「开始」，不逐字跟读流式正文（任务书 §16.7）
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(searching ? "正在联网搜索" : "正在生成回答")
                } else {
                    VStack(alignment: .leading, spacing: windowStyle ? 8 : 4) {
                        if windowStyle, message.role == .assistant {
                            metaLine
                        } else if let count = message.searchResultCount {
                            // 刘海仍是原来那条紧凑提示
                            HStack(spacing: 3) {
                                Image(systemName: "globe")
                                    .font(.system(size: 8))
                                Text("已参考 \(count) 条搜索结果")
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.cyan.opacity(0.75))
                        }
                        if let data = message.imageData, let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        if message.role == .assistant {
                            // AI 回复按 Markdown 排版；用户消息保持纯文本
                            // 窗口里正文 14 / 段距 12 / 行距 6；刘海保持原来的紧凑
                            MarkdownMessageView(text: message.content, type: type)
                            if windowStyle, sourcesExpanded, let sources = message.sources,
                               !sources.isEmpty {
                                sourcePanel(sources)
                            }
                            if windowStyle, !streaming, !message.content.isEmpty {
                                actionRow
                            }
                        } else {
                            // 自己问的那句也要能划词复制（大梁老师 2026-08-07）——
                            // 改一改再问一遍是常事，不能只让人重打一遍。
                            // 窗口比刘海宽敞得多，12pt 挤着没道理
                            SelectableText(MarkdownLite.plainNS(
                                message.content, size: type.body,
                                weight: type.bodyWeight,
                                color: windowStyle ? Color(nsColor: .labelColor)
                                                   : .white.opacity(0.9),
                                lineSpacing: type.lineSpacing))
                        }
                    }
                }
            }
            // AI 回答**直接落在背景画布上**，没有内边距也没有底色（任务书 §8.1，
            // 大梁老师 2026-07-31 拍板照办）：长回答套在一整块深灰里，正文层级被那块
            // 背景压掉，卡片宽度还随内容变、阅读边界不稳。
            // 只有代码块 / 表格 / 引用 / 来源这类才用局部卡片。
            // 用户消息仍是右侧气泡——一眼认出哪句是自己问的（任务书 §3.1.4）
            .padding(.horizontal, flatOnCanvas ? 0 : (windowStyle ? 14 : type.bubbleH))
            .padding(.vertical, flatOnCanvas ? 0 : (windowStyle ? 10 : type.bubbleV))
            .background {
                if flatOnCanvas {
                    Color.clear
                } else if windowStyle {
                    // 我的提问：圆角 14（任务书 §5.2），底色用 surface-2
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ChatWindowPalette.surface2)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(message.role == .user ? 0.16 : 0.06))
                }
            }
            if message.role == .assistant, !flatOnCanvas { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
        .onHover { hovering = $0 }
        .id(message.id)
    }

    /// 元信息行（任务书 §8.2）：`DeepSeek V4 Pro · 联网 · 深度思考 · 8 个来源`。
    ///
    /// 只显示**这条消息自己的快照**，老消息没有快照就整段不显示——
    /// 绝不拿当前全局设置去反推（§8.2.4）。默认低对比，鼠标进入这条消息才提亮
    @ViewBuilder
    private var metaLine: some View {
        let parts = message.metaParts
        if !parts.isEmpty {
            HStack(spacing: 6) {
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium))
                if let sources = message.sources, !sources.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.17)) { sourcesExpanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(sourcesExpanded ? "收起来源" : "查看来源")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(sourcesExpanded ? 90 : 0))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(minHeight: 32)          // 热区 ≥32（§16.5）
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("联网来源，共 \(sources.count) 个")
                    .accessibilityValue(sourcesExpanded ? "已展开" : "已收起")
                }
            }
            .foregroundStyle(hovering ? MarkdownTypography.textSecondary
                                      : MarkdownTypography.textTertiary)
        }
    }

    /// 来源面板（任务书 §9.2）：序号 + 标题 + 域名 + 外部打开。
    /// 超过 5 条先给 5 条，剩下的点「查看全部」
    private func sourcePanel(_ sources: [ChatSource]) -> some View {
        let shown = showAllSources ? sources : Array(sources.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, source in
                Button {
                    // 走既有的安全打开逻辑，不自己拼 URL
                    if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MarkdownTypography.textTertiary)
                            .frame(width: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            // 域名 + 发布时间。发布时间只有搜索引擎真给了才有，
                            // 没有就整段不显示（任务书 §9.2：不许编）
                            let sub = [source.domain, source.published ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · ")
                            if !sub.isEmpty {
                                Text(sub)
                                    .font(.system(size: 11))
                                    .foregroundStyle(MarkdownTypography.textTertiary)
                            }
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MarkdownTypography.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(index + 1) 个来源：\(source.title)，来自 \(source.domain)")
                if index < shown.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                }
            }
            if sources.count > 5, !showAllSources {
                Button { showAllSources = true } label: {
                    Text("查看全部 \(sources.count) 个")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MarkdownTypography.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(ChatWindowPalette.surfaceInset))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(ChatWindowPalette.border, lineWidth: 1))
        .frame(maxWidth: 760, alignment: .leading)
    }

    /// 消息操作（任务书 §8.4）：复制 + 重新生成。悬停才显形，不抢正文
    private var actionRow: some View {
        HStack(spacing: 4) {
            actionButton(copied ? "checkmark" : "doc.on.doc",
                         tip: copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                copied = true
                // 1200ms 后复原（任务书 §8.4.3）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            if let onRegenerate {
                actionButton("arrow.clockwise", tip: "重新生成", action: onRegenerate)
            }
        }
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func actionButton(_ icon: String, tip: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(MarkdownTypography.textSecondary)
                .frame(width: 26, height: 26)          // 热区 ≥ 26，够点
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchTip(tip, edge: .aboveLeading)
        .accessibilityLabel(tip)
    }
}


/// 深度思考图标：大梁老师提供的思考气泡原图（bundle 资源），
/// 模板渲染跟随前景色（开＝青、关＝灰）
private struct ThinkingBubbleIcon: View {
    /// 画布边长。刘海是 16——本原件内容只占画布 86% 高，16 才与旁边 13pt 的地球
    /// 实际等大（换原件要重算，别照抄）。窗口胶囊里地球是 12pt，按同比例取 14
    var side: CGFloat = 16

    var body: some View {
        if let img = NSImage(named: "TabIconThinking") {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
        } else {
            // swift run 裸二进制无 bundle 资源时兜底
            Image(systemName: "brain").font(.system(size: 13))
        }
    }
}
