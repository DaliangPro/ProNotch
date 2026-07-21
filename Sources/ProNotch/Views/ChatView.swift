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
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

/// AI 闪问：未配置时引导去设置；配置后左栏会话导航、右栏消息列表 + 输入框，流式输出
struct ChatView: View {
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

    private let edgeInset: CGFloat = 14

    /// 每段对话固定的系统开场白（纯 UI 引导语，不进 store、不发给 API）
    private static let greeting = ChatMessage(role: .assistant, content: "想和我聊点什么？")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isConfigured {
                // 左栏会话导航 + 右栏对话窗（大梁老师定的双栏结构）
                HStack(spacing: 0) {
                    // 左框：会话记录
                    ConversationSidebar()
                        .frame(width: CGFloat(sidebarWidth))
                        .frame(maxHeight: .infinity)
                        .modifier(ChatPanelFrame())
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .modifier(ChatPanelFrame())
                }
                .frame(maxHeight: .infinity)
            } else {
                // 未配置：引导去应用「设置 → AI 闪问」填接口（刘海内不再放设置表单）
                chatUnconfiguredGuide
            }
        }
        // 左右留白对齐全局基准线（见 ExpandedContentView.pageHInset）
        .padding(.horizontal, ExpandedContentView.pageHInset)
        .pageEntrance($entrancePlayed)
        .onAppear {
            store.checkConnectivity()
            installPasteMonitor()
        }
        .onDisappear {
            vm.keyboardHold = false
            setDividerCursor(false)
            if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor); pasteMonitor = nil }
        }
        // 悬停分隔线时被收起：onHover(false) 不会再来，补一次收光标防残留
        .onChange(of: vm.isExpanded) { _, expanded in
            if !expanded {
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
                vm.collapseNow()
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
            .fill(Color.white.opacity(dividerHover || dragBaseWidth != nil ? 0.28 : 0))
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
                guard vm.isExpanded, vm.activeTab == .chat,
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
                LazyVStack(spacing: 6) {
                    // 每段对话的开场白由系统发出：固定在最顶，先于历史消息
                    MessageBubble(message: Self.greeting, streaming: false, searching: false)
                        .chatRise(entrancePlayed, offset: 14, delay: dealDelay(0))
                    // enumerated 只为算发牌延迟；id 仍取 message.id，流式更新不重建气泡
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { i, message in
                        MessageBubble(message: message,
                                      streaming: store.isStreaming
                                          && message.id == store.messages.last?.id,
                                      searching: store.isSearching)
                            .chatRise(entrancePlayed, offset: 14, delay: dealDelay(i + 1))
                    }
                    if let error = store.errorText {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, 2)
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
            .help(store.webSearchEnabled
                ? "联网搜索已开启：先搜索再回答（点击关闭）"
                : "联网搜索已关闭（点击开启）")
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
                .onChange(of: inputFocused) { _, v in vm.keyboardHold = v }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
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

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }
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
                            .foregroundColor(.cyan.opacity(0.75))
                        }
                        if let data = message.imageData, let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        if message.role == .assistant {
                            // AI 回复按 Markdown 排版；用户消息保持纯文本
                            MarkdownMessageView(text: message.content)
                        } else {
                            Text(message.content)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.9))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(message.role == .user ? 0.16 : 0.06)))
            if message.role == .assistant { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
        .id(message.id)
    }
}

