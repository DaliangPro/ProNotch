import SwiftUI

private extension View {
    /// 闪问出场元素的通用动效：从下方 offset 处升起淡入，靠 delay 错峰（发牌节奏）
    func chatRise(_ played: Bool, offset: CGFloat, delay: Double) -> some View {
        self.offset(y: played ? 0 : offset)
            .opacity(played ? 1 : 0)
            .animation(.spring(response: 0.38, dampingFraction: 0.66).delay(delay),
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
    /// 默认 .notch：刘海那边的调用点一处不用改
    var host: ChatHost = .notch

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
    /// 独立窗口消息视口的高度：拿来把内容压到底部（见 body 窗口分支的 GeometryReader）
    @State private var viewportHeight: CGFloat = 0

    private let edgeInset: CGFloat = 14

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
                GeometryReader { geo in
                    messageList
                        .onAppear { viewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in viewportHeight = h }
                        // 上下两端渐隐（大梁老师定）：滚动的文字不该被一条硬边切断，
                        // 淡出去才像「还有内容在外面」。26pt 折算成比例，视口多高都一样厚
                        .mask(Self.edgeFade(height: geo.size.height))
                }
                .frame(maxHeight: .infinity)
                // 左右留白外壳不给，得自己给。这个 16 是全窗的基准竖线：
                // 气泡外缘、输入块外缘都对它（大梁老师要「三边一致」，且要再窄一点）
                .padding(.horizontal, 16)
                windowComposer
            } else if store.isConfigured {
                // 左栏会话导航 + 右栏对话窗（大梁老师定的双栏结构）
                HStack(spacing: 0) {
                    // 左框：会话记录
                    ConversationSidebar()
                        .frame(width: CGFloat(sidebarWidth))
                        .frame(maxHeight: .infinity)
                        .modifier(ChatPanelFrame(bordered: host.inNotch))
                        .chatRise(entrancePlayed, offset: 16, delay: 0)
                    sidebarDivider
                    // 右框：对话窗（消息区 + 输入框）。气泡在 messageList 内逐条发牌，
                    // 输入框等最后一张牌落定后再弹（像键盘弹出收尾）
                    VStack(alignment: .leading, spacing: 8) {
                        messageList
                        inputBar
                            .chatRise(entrancePlayed, offset: 24,
                                      delay: dealDelay(store.messages.count) + 0.08)
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
        .pageEntrance($entrancePlayed, active: host.inNotch ? nil : true)
        .onAppear {
            store.checkConnectivity()
            installPasteMonitor()
        }
        .onDisappear {
            if host.inNotch { vm.keyboardHold = false }
            setDividerCursor(false)
            if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor); pasteMonitor = nil }
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
        .chatRise(entrancePlayed, offset: 16, delay: 0)
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

    /// 消息区上下两端的渐隐遮罩。26pt 固定厚度，按视口高度折成比例
    private static func edgeFade(height: CGFloat) -> LinearGradient {
        let fade = height > 120 ? 26 / height : 0
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: fade),
            .init(color: .black, location: 1 - fade),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: host.inNotch ? 6 : 18) {
                    // 开场白只在刘海里出现。独立窗口是「问一句就走」的地方，
                    // 一句硬编码的装饰语占着最显眼的位置，却不进对话也不发 API，纯占位
                    if host.inNotch {
                        MessageBubble(message: Self.greeting, streaming: false, searching: false,
                                      windowStyle: false)
                            .chatRise(entrancePlayed, offset: 14, delay: dealDelay(0))
                    }
                    // enumerated 只为算发牌延迟；id 仍取 message.id，流式更新不重建气泡
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { i, message in
                        MessageBubble(message: message,
                                      streaming: store.isStreaming
                                          && message.id == store.messages.last?.id,
                                      searching: store.isSearching,
                                      windowStyle: !host.inNotch)
                            .chatRise(entrancePlayed, offset: 14, delay: dealDelay(i + 1))
                    }
                    if let error = store.errorText {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 提醒不是报错（如模型不支持关深度思考）：回复照常出，用灰橙色说一句就够
                    if let notice = store.noticeText {
                        Text(notice)
                            .font(.system(size: 10))
                            .foregroundColor(.orange.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, host.inNotch ? 2 : 0)
                // 不足一屏时压到底部；刘海不用，那儿本来就是满的
                .frame(minHeight: host.inNotch ? nil : viewportHeight, alignment: .bottom)
            }
            .onChange(of: store.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.currentID) { _, _ in
                // 切会话后等新列表上屏再落底
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
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
            TextField("", text: $store.draftMessage,
                      prompt: Text("问点什么…").foregroundStyle(.tertiary),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
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
                windowToolChip("联网", on: store.webSearchEnabled,
                               action: { store.webSearchEnabled.toggle() }) {
                    Image(systemName: "globe").font(.system(size: 12))
                }
                windowToolChip("深度思考", on: store.thinkingEnabled,
                               action: { store.thinkingEnabled.toggle() }) {
                    ThinkingBubbleIcon(side: 14)
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
                    .notchTip("停止", edge: .aboveLeading)
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
                    .notchTip("发送（回车）", edge: .aboveLeading)
                }
            }
        }
        // 内边距 12 与气泡的 12 一致：输入框占位符、模型名和气泡里的正文
        // 因此落在同一条竖线上（大梁老师要「文字之间有对齐关系」）
        .padding(.horizontal, 12).padding(.vertical, 9)
        // 比窗口材质更厚一层：层级靠材质厚薄编码，不靠描边（Apple 的做法）
        // 只靠材质分不出层：深色下 regularMaterial 和窗口底几乎同色（实测拍出来糊成一片）。
        // 叠一层浅填充 + 一道细描边，层级要看得出来才叫层级
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            shape.fill(.regularMaterial)
                .overlay(shape.fill(.white.opacity(0.06)))
                .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        }
        // 外缘与消息栏同为 16，左右下三边一条线
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    /// 系统强调色（跟「系统设置 → 外观 → 强调色」走）
    private static var accent: Color { Color(nsColor: .controlAccentColor) }

    private func windowToolChip<Icon: View>(_ title: String, on: Bool,
                                            action: @escaping () -> Void,
                                            @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                Text(title).font(.system(size: 11.5))
            }
            // 开＝系统强调色（大梁老师定：跟他系统设置里那个颜色一致，他的机器是黄色）。
            // 用 NSColor.controlAccentColor 而不是 SwiftUI 的 Color.accentColor：
            // 后者在没有 App 环境时（比如离屏渲染）会退成另一个色，前者始终读系统真值
            .foregroundStyle(on ? AnyShapeStyle(Self.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9).frame(height: 26)
            .background {
                if on {
                    Capsule().fill(Self.accent.opacity(0.18))
                        .overlay(Capsule().strokeBorder(Self.accent.opacity(0.45), lineWidth: 0.5))
                } else {
                    Capsule().fill(.quaternary)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sendDraft() {
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

private struct MessageBubble: View {
    let message: ChatMessage
    let streaming: Bool
    let searching: Bool
    /// 独立窗口的排版：正文 14pt、两侧都套气泡、走系统语义色与材质。
    ///
    /// AI 的回答一度是不套框的整段文字（想着长文读起来松快），
    /// 但大梁老师定下两边都要气泡（2026-07-30）——一眼能分清谁说的比松快更重要
    var windowStyle = false

    var body: some View {
        HStack {
            // 两侧都留空档：气泡才有「贴着一边」的形，不然就是一条通栏
            if message.role == .user { Spacer(minLength: windowStyle ? 64 : 80) }
            Group {
                if message.content.isEmpty && streaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        if searching {
                            Text("正在联网搜索…")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .padding(4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if let count = message.searchResultCount {
                            HStack(spacing: 3) {
                                Image(systemName: "globe")
                                    .font(.system(size: 8))
                                Text("已参考 \(count) 条搜索结果")
                                    .font(.system(size: 9))
                            }
                            // 窗口走单色：一片灰里留着刘海那个青，就是个突兀的彩点
                            .foregroundColor(windowStyle ? .white.opacity(0.42) : .cyan.opacity(0.75))
                            .padding(.bottom, windowStyle ? 3 : 0)
                        }
                        if let data = message.imageData, let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        if message.role == .assistant {
                            // AI 回复按 Markdown 排版；用户消息保持纯文本
                            // 窗口里正文 14 / 段距 12 / 行距 6；刘海保持原来的紧凑
                            MarkdownMessageView(text: message.content,
                                                fontSize: windowStyle ? 14 : 12,
                                                blockSpacing: windowStyle ? 12 : 6,
                                                lineSpacing: windowStyle ? 6 : 0)
                        } else {
                            Text(message.content)
                                // 窗口比刘海宽敞得多，12pt 挤着没道理；语义色在毛玻璃上才有 vibrancy
                                .font(.system(size: windowStyle ? 14 : 12))
                                .foregroundStyle(windowStyle ? AnyShapeStyle(.primary)
                                                             : AnyShapeStyle(Color.white.opacity(0.9)))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            // 12 与输入块的内边距一样：气泡里的字和输入框里的字落在同一条竖线上
            .padding(.horizontal, windowStyle ? 12 : 10)
            .padding(.vertical, windowStyle ? 9 : 6)
            .background {
                if windowStyle {
                    // 两边都是气泡，靠**材质厚薄**分谁说的：
                    // 我的提问用厚材质（跟输入块同一档，都是「我这边」），
                    // AI 的回答用最薄的一档，长文压在上面才不闷。半径 14 与输入块一致
                    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    if message.role == .user {
                        // 同理不用材质：regularMaterial 在半透明窗里渲得比窗底还暗，
                        // 成了整屏唯一一块「比背景深」的东西。tertiary 比 quaternary
                        // 明确亮一档，「我说的」因此更实、AI 那侧更轻
                        shape.fill(.tertiary)
                    } else {
                        // 不用 ultraThinMaterial：材质在已经半透明的窗里会跟着背后桌面走，
                        // 深桌面下渲成近黑、浅桌面下发白，同一块气泡颜色不可控
                        //（离屏实测就是一块黑）。.quaternary 是确定的一档淡提亮
                        shape.fill(.quaternary)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(message.role == .user ? 0.16 : 0.06))
                }
            }
            if message.role == .assistant { Spacer(minLength: windowStyle ? 64 : 80) }
        }
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
        .id(message.id)
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
