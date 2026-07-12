import SwiftUI

/// 展开后的面板内容：顶行 = 标签栏（左）+ 当前页功能区（右），下方为功能页
struct ExpandedContentView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var launcherStore: LauncherStore
    @EnvironmentObject var clipboardStore: ClipboardStore
    @EnvironmentObject var snippetStore: SnippetStore
    @EnvironmentObject var chatStore: ChatStore
    @EnvironmentObject var quickActions: QuickActionsStore
    @EnvironmentObject var captureStore: CaptureStore
    @EnvironmentObject var agentSessions: AgentSessionsStore

    @State private var draggedTab: NotchViewModel.Tab?
    @State private var draggedAction: QuickActionsStore.ActionKind?

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(spacing: 10) {
            // 刘海两侧的快捷操作区（中间给真实刘海让位）：
            // 左侧 = 一次性动作（截图 / 锁屏）+ 防休眠开关（图标式）+ 设置入口
            // 右侧 = 系统外观切换 + Agent 完成提醒总开关
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    // 顺序（大梁老师定）：设置 → 锁屏 → 截图 → 防休眠 → 净屏
                    // 设置入口：固定最左
                    StripButton(icon: "gearshape",
                                help: "打开 ProNotch 设置") {
                        quickActions.openAppSettings()
                        vm.collapseNow()
                    }
                    .notchTip("打开设置")
                    // 锁屏 / 截图：可拖动排序（与标签同款交互）
                    ForEach(quickActions.actionOrder.filter { $0 != .appSettings },
                            id: \.self) { kind in
                        stripButton(for: kind)
                            .opacity(draggedAction == kind ? 0.35 : 1)
                            .onDrag {
                                draggedAction = kind
                                return NSItemProvider(object: kind.rawValue as NSString)
                            }
                            .onDrop(of: [.text],
                                    delegate: QuickActionDropDelegate(
                                        kind: kind,
                                        dragged: $draggedAction,
                                        store: quickActions))
                    }
                    // 防休眠（状态类开关）：显示器图标（大梁老师选定），恒定字形、开启态青色区分
                    StripToggle(icon: "display",
                                active: quickActions.caffeinateActive,
                                help: quickActions.caffeinateActive
                                    ? "防休眠已开启（点击关闭）"
                                    : "防止闲置熄屏与休眠；合盖休眠是系统强制行为，"
                                      + "合盖不睡需接电源 + 外接屏（系统合盖模式）") {
                        quickActions.toggleCaffeinate()
                    }
                    .notchTip(quickActions.caffeinateActive ? "防休眠 · 已开启" : "防休眠")
                    // 净屏开关：一键隐藏/恢复桌面全部图标
                    StripToggle(icon: "rectangle.dashed",
                                active: quickActions.desktopIconsHidden,
                                help: quickActions.desktopIconsHidden
                                    ? "桌面图标已隐藏（点击恢复显示）"
                                    : "净屏：隐藏桌面全部图标，屏幕彻底干净；已打开的访达窗口会关闭") {
                        quickActions.toggleDesktopIcons()
                    }
                    .notchTip(quickActions.desktopIconsHidden ? "净屏 · 已开启" : "净屏（隐藏桌面图标）")
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                Color.clear.frame(width: vm.notchRect.width + 24)

                HStack(spacing: 6) {
                    Spacer()
                    AppearanceSlider()
                        .notchTip("系统颜色切换")
                    // Agent 完成提醒总开关：橙(Claude)→蓝(Codex)双色描边胶囊
                    AgentReminderToggle()
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: vm.notchRect.height)
            .padding(.horizontal, edgeInset)
            .zIndex(1)   // 抬高：让悬停气泡能盖在下方标签行/内容之上，不被遮挡

            HStack(spacing: 8) {
                // 标签可拖动换位：长按拖到目标位置松手，顺序持久化
                ForEach(vm.tabOrder, id: \.self) { tab in
                    TabButton(tab: tab, isActive: vm.activeTab == tab) {
                        vm.activeTab = tab
                    }
                    .opacity(draggedTab == tab ? 0.35 : 1)
                    .onDrag {
                        draggedTab = tab
                        return NSItemProvider(object: tab.rawValue as NSString)
                    }
                    .onDrop(of: [.text],
                            delegate: TabDropDelegate(tab: tab,
                                                      dragged: $draggedTab,
                                                      vm: vm))
                }
                Spacer()
                accessory
            }
            .padding(.horizontal, edgeInset)

            Group {
                switch vm.activeTab {
                case .launcher:
                    LauncherView()
                case .clipboard:
                    ClipboardView()
                case .chat:
                    ChatView()
                case .capture:
                    CaptureView()
                case .usage:
                    UsageView()
                case .agent:
                    AgentSessionsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        // 内容常驻后 onAppear/onDisappear 只触发一次，面板级事件改挂展开状态：
        // 展开时重扫应用列表（新装 App 才能及时出现），收起时清空搜索词
        .onChange(of: vm.isExpanded) { _, expanded in
            if expanded {
                launcherStore.refreshIfNeeded()
                agentSessions.refresh()   // Agent 会话列表随面板展开刷新(10 秒节流)
            } else {
                launcherStore.searchText = ""
            }
        }
    }

    @ViewBuilder
    private func stripButton(for kind: QuickActionsStore.ActionKind) -> some View {
        switch kind {
        case .screenshot:
            StripButton(icon: "camera.viewfinder",
                        help: "超级截图：框选 + 标注 + 存桌面/复制") {
                vm.collapseNow()
                SuperScreenshotController.shared.capture()
            }
            .notchTip("超级截图")
        case .appSettings:
            // 不可达：设置入口已固定在防休眠右侧，上游 ForEach 过滤了本枚举值；
            // 枚举值本身保留（拖动顺序的持久化数据里含它，删会破坏旧用户已存顺序）
            EmptyView()
        case .lockScreen:
            StripButton(icon: "lock",
                        help: "熄屏锁定") {
                vm.collapseNow()
                quickActions.lockScreen()
            }
            .notchTip("锁屏")
        }
    }

    private var clipboardCountText: String {
        if clipboardStore.showingSnippets {
            return snippetStore.snippets.isEmpty ? "" : "\(snippetStore.snippets.count) 条"
        }
        return clipboardStore.items.isEmpty ? "" : "\(clipboardStore.items.count) 条"
    }

    /// 顶行右侧：随当前标签页切换的功能区
    @ViewBuilder
    private var accessory: some View {
        switch vm.activeTab {
        case .launcher:
            LauncherSearchField()
        case .clipboard:
            // 滑块固定不动：右侧计数与按钮用固定宽度槽位占位，
            // 内容变宽变窄、出现消失都不推挤滑块
            ClipboardSectionToggle()
            Text(clipboardCountText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
                .frame(width: 56, alignment: .trailing)
            Group {
                if clipboardStore.showingSnippets {
                    AccessoryButton(title: "新增") { snippetStore.beginNew() }
                } else if !clipboardStore.items.isEmpty {
                    AccessoryButton(title: "清空") { clipboardStore.clear() }
                }
            }
            .frame(width: 52, alignment: .trailing)
        case .chat:
            if chatStore.isConfigured {
                Button {
                    chatStore.showSettings.toggle()
                } label: {
                    Text(chatStore.model)
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("点击修改 API 设置")
                ConnectivityLight()
            }
            if !chatStore.messages.isEmpty {
                AccessoryButton(title: "新对话") { chatStore.clearConversation() }
            }
        case .capture:
            Text(captureStore.inboxFileName)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            AccessoryButton(title: "打开") {
                captureStore.openInbox()
                vm.collapseNow()
            }
        case .usage:
            EmptyView()   // 刷新按钮在页面内部（右上角）
        case .agent:
            if !agentSessions.sessions.isEmpty {
                Text("\(agentSessions.sessions.count) 个会话")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            AccessoryButton(title: "刷新") { agentSessions.refresh(force: true) }
        }
    }
}

/// API 连通状态灯：绿=连通，红=失败（悬停看原因），黄=检测中；点击重新检测
private struct ConnectivityLight: View {
    @EnvironmentObject var chatStore: ChatStore

    var body: some View {
        Button {
            chatStore.checkConnectivity(force: true)
        } label: {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var color: Color {
        switch chatStore.connectivity {
        case .unknown: return .white.opacity(0.25)
        case .checking: return .yellow
        case .ok: return .green
        case .failed: return .red
        }
    }

    private var helpText: String {
        switch chatStore.connectivity {
        case .unknown: return "未检测（点击检测连通性）"
        case .checking: return "正在检测连通性…"
        case .ok: return "API 连通正常（点击重新检测）"
        case .failed(let reason): return "连接失败：\(reason)（点击重新检测）"
        }
    }
}

/// 顶行功能区文字按钮：与标签按钮同风格，整个胶囊区域可点击、悬停高亮
private struct AccessoryButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 标签拖动换位：拖入目标标签时实时交换位置（带弹簧动画）
private struct TabDropDelegate: DropDelegate {
    let tab: NotchViewModel.Tab
    @Binding var dragged: NotchViewModel.Tab?
    let vm: NotchViewModel

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != tab,
              let from = vm.tabOrder.firstIndex(of: dragged),
              let to = vm.tabOrder.firstIndex(of: tab) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            vm.tabOrder.move(fromOffsets: IndexSet(integer: from),
                             toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// 快捷动作拖动换位：拖入目标图标时实时交换位置（带弹簧动画）
private struct QuickActionDropDelegate: DropDelegate {
    let kind: QuickActionsStore.ActionKind
    @Binding var dragged: QuickActionsStore.ActionKind?
    let store: QuickActionsStore

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != kind,
              let from = store.actionOrder.firstIndex(of: dragged),
              let to = store.actionOrder.firstIndex(of: kind) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            store.actionOrder.move(fromOffsets: IndexSet(integer: from),
                                   toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// 剪贴板页「历史 ⇄ 话术」滑动开关：滑块弹簧滑向当前侧，点击任意位置切换
private struct ClipboardSectionToggle: View {
    @EnvironmentObject var clipboardStore: ClipboardStore

    @State private var hovering = false

    private var snippets: Bool { clipboardStore.showingSnippets }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                clipboardStore.showingSnippets.toggle()
            }
        } label: {
            ZStack(alignment: snippets ? .trailing : .leading) {
                // 滑块
                Capsule()
                    .fill(Color.white.opacity(hovering ? 0.24 : 0.18))
                    .frame(width: 44, height: 20)
                // 两端文字
                HStack(spacing: 0) {
                    Text("历史")
                        .font(.system(size: 11, weight: .light))
                        .foregroundColor(.white.opacity(snippets ? 0.45 : 1))
                        .frame(width: 44, height: 20)
                    Text("话术")
                        .font(.system(size: 11, weight: .light))
                        .foregroundColor(.white.opacity(snippets ? 1 : 0.45))
                        .frame(width: 44, height: 20)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(snippets ? "当前：话术库（点击切到历史）" : "当前：历史（点击切到话术库）")
    }
}

/// 纯文字开关胶囊：开启时整体点亮青色
/// 图标式状态开关（防休眠等）：与 StripButton 同款圆形，激活态青色
private struct StripToggle: View {
    let icon: String
    let active: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(active ? .cyan : .white.opacity(hovering ? 0.9 : 0.5))
                .frame(width: 28, height: 28)
                .background(Circle().fill(
                    active ? Color.cyan.opacity(0.18)
                           : Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 面板右侧「Agent 提醒」总开关：橙(Claude)→蓝(Codex)双色描边胶囊。
/// 点亮 = 开启 Agent 完成光晕；熄灭 = 全局静音（关闭时正亮着的光晕也会随之
/// 熄灭——由 GlowController 监听 glowEnabled 变更统一处理）。
private struct AgentReminderToggle: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var vm: NotchViewModel

    @State private var hovering = false
    @State private var breathing = false

    private var on: Bool { settings.glowEnabled }
    /// 只在「开启 且 面板展开」时呼吸——收起态看不见却常驻，无限动画会持续标脏
    /// 整棵面板视图树、每帧重新布局（曾导致空闲 CPU 30%+）；收起即停
    private var shouldBreathe: Bool { on && vm.isExpanded }

    /// 开启时描边在 0.45↔1 之间呼吸；关闭时恒定（灰描边不呼吸）
    private var strokeOpacity: Double {
        guard on else { return 1 }
        return breathing ? 1 : 0.45
    }

    var body: some View {
        Button {
            settings.glowEnabled.toggle()
        } label: {
            Text("Agent 提醒")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(on ? .white : .white.opacity(hovering ? 0.6 : 0.4))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
                .overlay(
                    Capsule()
                        .strokeBorder(borderStyle, lineWidth: 1.5)
                        .opacity(strokeOpacity)
                        .animation(shouldBreathe
                            ? .easeInOut(duration: max(settings.glowBreathPeriod, 0.6) / 2).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.2), value: breathing)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { breathing = shouldBreathe }
        .onChange(of: shouldBreathe) { _, v in breathing = v }   // 展开/收起、开关切换时启停呼吸
        .help(on ? "Agent 完成提醒：开启（点击全局静音屏幕光晕）"
                 : "Agent 完成提醒：已静音（点击恢复）")
    }

    /// 开：用真实光晕色做左橙右蓝渐变描边；关：中性灰描边
    private var borderStyle: AnyShapeStyle {
        guard on else { return AnyShapeStyle(Color.white.opacity(0.18)) }
        return AnyShapeStyle(LinearGradient(
            colors: [Color(hex: settings.glowClaudeColorHex),
                     Color(hex: settings.glowCodexColorHex)],
            startPoint: .leading, endPoint: .trailing))
    }
}

/// 深浅色滑动开关：太阳/月亮固定两端，高亮滑块弹簧动画滑向当前侧，
/// 点击任意位置切换（首次使用需授权自动化）
private struct AppearanceSlider: View {
    @EnvironmentObject var quickActions: QuickActionsStore

    @State private var hovering = false

    private var isDark: Bool { quickActions.isEffectivelyDark }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                quickActions.setAppearance(isDark ? .light : .dark)
            }
        } label: {
            ZStack(alignment: isDark ? .trailing : .leading) {
                // 滑块
                Capsule()
                    .fill(Color.white.opacity(hovering ? 0.25 : 0.18))
                    .frame(width: 30, height: 22)
                // 两端图标
                HStack(spacing: 0) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(isDark ? 0.45 : 1))
                        .frame(width: 30, height: 22)
                    Image(systemName: "moon")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(isDark ? 1 : 0.45))
                        .frame(width: 30, height: 22)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isDark ? "系统外观：深色（点击切换整个 macOS 为浅色）" : "系统外观：浅色（点击切换整个 macOS 为深色）")
    }
}

/// 悬停中文提示气泡：刘海是后台非激活面板（LSUIElement），原生 .help 的 tooltip
/// 只在所属 App 处于激活态时才弹，这里用不了——故自绘，在控件下方渲染。
private struct NotchTip: ViewModifier {
    let text: String
    @State private var show = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                task?.cancel()
                if hovering {
                    task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)   // 悬停约 0.6s 才弹
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) { show = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { show = false }
                }
            }
            .overlay(alignment: .top) {
                if show {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                        )
                        .offset(y: 32)   // 落到控件下方（不挡按钮本身）
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(999)
                }
            }
    }
}

private extension View {
    /// 悬停约 0.6s 后在控件下方弹出中文气泡说明（纯图标按钮用，告诉用户图标是干嘛的）
    func notchTip(_ text: String) -> some View { modifier(NotchTip(text: text)) }
}

/// 刘海两侧快捷操作按钮：圆形可点击区域、悬停高亮
private struct StripButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.5))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct TabButton: View {
    let tab: NotchViewModel.Tab
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // 只留中文名不放图标:6 个标签后空间紧,纯文字更清爽、可显示区域更大
            Text(tab.title)
                .font(.system(size: 11, weight: .light))
                .foregroundColor(isActive ? .white : .white.opacity(hovering ? 0.85 : 0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(
                    Color.white.opacity(isActive ? 0.18 : (hovering ? 0.08 : 0))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
