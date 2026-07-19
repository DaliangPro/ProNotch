import SwiftUI

/// 展开后的面板内容：顶行 = 标签栏（左）+ 当前页功能区（右），下方为功能页
struct ExpandedContentView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var launcherStore: LauncherStore
    @EnvironmentObject var chatStore: ChatStore
    @EnvironmentObject var quickActions: QuickActionsStore
    @EnvironmentObject var agentSessions: AgentSessionsStore
    @EnvironmentObject var usageStore: UsageStore
    @EnvironmentObject var memoryStore: MemoryStore
    @EnvironmentObject var weatherStore: WeatherStore

    @State private var draggedTab: NotchViewModel.Tab?

    /// 选中胶囊的共享几何：切标签时从旧按钮滑到新按钮，而非两处各自跳变
    @Namespace private var tabIndicatorNS
    /// 实际渲染的页。所有切换入口（点击/横滑/程序化）都改 activeTab，
    /// 由 onChange 统一包 withAnimation 更新它——胶囊滑动、页面过渡一处驱动
    @State private var displayedTab: NotchViewModel.Tab?
    /// 页面过渡位移：正 = 往 tabOrder 右侧切，新页从右滑入、旧页往左滑出。
    /// 位移刻意轻（28pt）——切页的主角是各页自己的内容出场动画
    @State private var slideDX: CGFloat = 28

    private var shownTab: NotchViewModel.Tab { displayedTab ?? vm.activeTab }

    /// 各功能页内容的左右视觉留白：在面板外层 20pt 之上再补此值，
    /// 使页内容左缘对齐启动台网格图标视觉左缘（43，大梁老师定的全局基准线），
    /// 右缘同步收进、左右对称（960−43=917）
    static let pageHInset: CGFloat = 23
    /// 顶行/标签行的行内边距（离屏渲染实测校准）：负 padding 胶囊按钮的可见胶囊
    /// 比布局框每边多凸 3pt，leading 26 恰好让首颗胶囊左缘压在 43 基准线上；
    /// 行尾是普通胶囊（搜索框/Agent 提醒），trailing 23 让其右缘压在 917 对称线上
    private let rowLeading: CGFloat = 26
    private let rowTrailing: CGFloat = 23

    var body: some View {
        VStack(spacing: 10) {
            // 刘海两侧的快捷操作区（中间给真实刘海让位）：
            // 左侧 = 一次性动作（截图 / 锁屏）+ 防休眠开关（图标式）+ 设置入口
            // 右侧 = 系统外观切换 + Agent 完成提醒总开关
            HStack(spacing: 0) {
                HStack(spacing: 14) {   // 间距与标签行一致，三颗列位对齐下方前三个标签
                    // 顺序：设置 → 防休眠 → 净屏
                    // 设置入口：固定最左
                    StripButton(icon: "gearshape",
                                help: "打开 ProNotch 设置") {
                        quickActions.openAppSettings()
                        vm.collapseNow()
                    }
                    .notchTip("打开设置")
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
            .padding(.leading, rowLeading)
            .padding(.trailing, rowTrailing)
            .zIndex(1)   // 抬高：让悬停气泡能盖在下方标签行/内容之上，不被遮挡

            HStack(spacing: 14) {
                // 标签可拖动换位：长按拖到目标位置松手，顺序持久化
                ForEach(vm.tabOrder, id: \.self) { tab in
                    TabButton(tab: tab, isActive: shownTab == tab, ns: tabIndicatorNS) {
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
            .padding(.leading, rowLeading)
            .padding(.trailing, rowTrailing)
            .zIndex(0.5)   // 抬高：标签图标的悬停气泡往下弹 32pt 落进内容区，不抬会被内容页盖住

            // ZStack 让过渡期间新旧两页共存：新页顺切换方向滑入淡入，旧页同向滑出淡出
            ZStack {
                Group {
                    switch shownTab {
                    case .launcher:
                        LauncherView()
                    case .chat:
                        ChatView()
                    case .usage:
                        UsageView()
                    case .agent:
                        AgentSessionsView()
                    case .widgets:
                        WidgetsView()
                    }
                }
                .id(shownTab)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: slideDX)),
                    removal: .opacity.combined(with: .offset(x: -slideDX))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        // 左边缘正中浮一枚锁（大梁老师定）：不入 43 基准线、避开四角裁剪圆角，
        // 鼠标移上去点一下即锁定，锁上后移开也不自动收起
        .overlay(alignment: .leading) {
            if vm.isExpanded {
                // 面板可视左缘在 x=12（NotchShape 顶角外张，左竖边从 minX+topRadius 起），
                // 16 = 12 + 4pt 气口，胶囊不会被裁剪形状切掉左边
                PinToggle()
                    .padding(.leading, 16)
            }
        }
        .onChange(of: vm.activeTab) { old, new in
            let oi = vm.tabOrder.firstIndex(of: old) ?? 0
            let ni = vm.tabOrder.firstIndex(of: new) ?? 0
            slideDX = ni >= oi ? 28 : -28
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                displayedTab = new
            }
        }
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

    /// 顶行右侧：随当前标签页切换的功能区（跟 shownTab 与页面同步换、同事务淡入）
    @ViewBuilder
    private var accessory: some View {
        switch shownTab {
        case .launcher:
            LauncherSearchField()
        case .chat:
            // 「新对话」入口移进了左侧会话栏；设置入口收进切换器下拉底部。
            // 多套配置时切换器常驻（哪怕当前套没 Key），好让用户直接切到配好的那套
            if chatStore.isConfigured || chatStore.providers.count > 1 {
                ModelSwitcher()
            }
            if chatStore.isConfigured {
                ConnectivityLight()
            }
        case .usage:
            AccessoryButton(title: "刷新") { usageStore.refresh(force: true) }
        case .agent:
            if !agentSessions.sessions.isEmpty {
                Text("\(agentSessions.sessions.count) 个会话")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            AccessoryButton(title: "刷新") { agentSessions.refresh(force: true) }
        case .widgets:
            AccessoryButton(title: "刷新") {
                memoryStore.refresh()
                weatherStore.refresh(force: true)
            }
        }
    }
}

/// 右上角模型切换器（大梁老师定）：点击展开面板内自绘下拉，选中立即生效并持久化；
/// 列表不走系统菜单——无边框面板里系统弹窗定位会飘（与设置表单的下拉同一处理）
private struct ModelSwitcher: View {
    @EnvironmentObject var chatStore: ChatStore
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quickActions: QuickActionsStore
    @State private var showList = false
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { showList.toggle() }
            // 首次点开还没有列表就现拉一次（结果持久化，之后秒开）；当前套没 Key 就别白拉
            if chatStore.isConfigured, chatStore.availableModels.isEmpty { chatStore.fetchModels() }
        } label: {
            HStack(spacing: 4) {
                Text(chatStore.model.isEmpty ? "选择模型" : chatStore.model)
                    .font(.system(size: 11, weight: .light))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .rotationEffect(.degrees(showList ? 180 : 0))
            }
            .foregroundColor(.white.opacity(hovering || showList ? 0.8 : 0.45))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(hovering || showList ? 0.1 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("切换配置 / 模型")
        // 下拉悬浮在按钮右下方，盖住内容页不参与布局（标签行 zIndex 已抬高）
        .overlay(alignment: .topTrailing) {
            if showList { dropdown.offset(y: 27) }
        }
        // 内容常驻不销毁：面板收起时手动合上，避免下次展开还挂着下拉
        .onChange(of: vm.isExpanded) { _, expanded in
            if !expanded { showList = false }
        }
    }

    private var dropdown: some View {
        let rowHeight: CGFloat = 24
        let items = chatStore.switcherModels
        let fetchingRow = chatStore.fetchingModels && chatStore.availableModels.isEmpty
        let rows = CGFloat(items.count) + (fetchingRow ? 1 : 0)
        let listHeight = min(max(rows, 1) * rowHeight + 6, 130)
        return VStack(spacing: 0) {
            // 多套配置：顶部先切「配置套」（切过去自动载入那套的 Key 与模型）
            if chatStore.providers.count > 1 {
                providerSwitchSection
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty, !fetchingRow {
                        Text("暂无模型，点下方「API 设置」添加")
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 10)
                            .frame(height: rowHeight)
                    }
                    ForEach(items, id: \.self) { name in
                        SwitcherRow(name: name, isSelected: name == chatStore.model) {
                            chatStore.selectModel(name)
                            withAnimation(.easeIn(duration: 0.1)) { showList = false }
                        }
                    }
                    if fetchingRow {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在获取模型…")
                        }
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .frame(height: rowHeight)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(height: listHeight)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            SwitcherFooter {
                // 打开应用「设置」窗口并直接定位到「AI 闪问」页（不在刘海内展开表单）
                settings.pendingSection = SettingsView.Section.chat.rawValue
                quickActions.openAppSettings()
                vm.collapseNow()   // 收起刘海，别挡住弹出的设置窗口
                showList = false
            }
        }
        .frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(red: 0.11, green: 0.11, blue: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    /// 下拉顶部的配置套切换区：每套一行，点选切过去（异步载入那套 Key）；当前套打勾
    private var providerSwitchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("配置")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .padding(.horizontal, 10)
                .padding(.top, 6).padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(chatStore.providers) { p in
                ProviderSwitchRow(name: p.name.isEmpty ? "未命名" : p.name,
                                  isSelected: p.id == chatStore.currentProviderID) {
                    chatStore.activateProvider(p.id)
                    withAnimation(.easeIn(duration: 0.1)) { showList = false }
                }
            }
        }
        .padding(.bottom, 3)
    }
}

/// 配置套切换行：立方体图标区分于模型行，当前套打勾
private struct ProviderSwitchRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "cube")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(hovering ? 0.12 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SwitcherRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(hovering ? 0.12 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 下拉底部的「API 设置…」入口（原来点模型名进设置，挪到这里）
private struct SwitcherFooter: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "gearshape")
                    .font(.system(size: 9))
                Text("API 设置…")
                    .font(.system(size: 10.5))
            }
            .foregroundColor(.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(hovering ? 0.12 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                // 与下方标签行同一套度量（大梁老师定：顶条三颗与四标签同宽同位同大）：
                // 胶囊 42×31 + 热区 50×37 + 布局占位 36×25，配合左簇间距 14 列位对齐
                .frame(width: 42, height: 31)
                .background(Capsule().fill(
                    active ? Color.cyan.opacity(0.18)
                           : Color.white.opacity(hovering ? 0.12 : 0)))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -7)
        .padding(.vertical, -6)
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

/// 面板锁定开关：浮在弹出面板左边缘正中的锁。鼠标移上去点一下即锁定，
/// 锁上后移开鼠标面板也不自动收起；再点解锁。青色激活与防休眠/净屏同语言。
/// 默认只露一枚裸图标（无底）；锁定态持续亮青底；文字（锁定/已锁定）仅悬停时展开
private struct PinToggle: View {
    @EnvironmentObject var vm: NotchViewModel
    @State private var hovering = false

    private var expanded: Bool { hovering }

    var body: some View {
        Button {
            vm.isPinned.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: vm.isPinned ? "lock.fill" : "lock.open")
                    .font(.system(size: 14, weight: .semibold))
                if expanded {
                    Text(vm.isPinned ? "已锁定" : "锁定")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundColor(vm.isPinned ? .cyan : .white.opacity(hovering ? 0.95 : 0.6))
            .padding(.horizontal, expanded ? 13 : 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(
                vm.isPinned ? Color.cyan.opacity(0.2)
                            : Color.white.opacity(hovering ? 0.2 : 0)))   // 默认无底，悬停才现
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(vm.isPinned ? "面板已锁定，不会自动收起（点击解锁）"
                          : "锁定面板：锁上后移开鼠标也不收起")
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
                // 度量与 StripToggle/TabButton 同款，见 StripToggle 注释
                .frame(width: 42, height: 31)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -7)
        .padding(.vertical, -6)
        .help(help)
    }
}

private struct TabButton: View {
    let tab: NotchViewModel.Tab
    let isActive: Bool
    let ns: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // 纯图标（大梁老师选定）：与两侧快捷按钮同款视觉语言，
            // 等宽胶囊整齐划一，中文名走悬停气泡
            iconView
                .foregroundColor(isActive ? .white : .white.opacity(hovering ? 0.85 : 0.55))
                // 胶囊可见框 42×31（大梁老师预览拍板 A 方案）：图标字形不变，
                // 只有悬停/选中的灰胶囊变大，胶囊间隙 14 → 8
                .frame(width: 42, height: 31)
                .background {
                    // 选中胶囊全组共用一个几何体（matchedGeometry）：切标签时滑过去
                    if isActive {
                        Capsule().fill(Color.white.opacity(0.18))
                            .matchedGeometryEffect(id: "activeTabCapsule", in: ns)
                    } else if hovering {
                        Capsule().fill(Color.white.opacity(0.08))
                    }
                }
                // 热区再外扩到 50×37：横向正好吃满剩余间隙的一半，
                // 相邻热区无缝相接不重叠
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 负 padding 把布局占位缩回 36×25：标签中心距、行高、与右侧功能区的
        // 对齐全都不动，变大的胶囊与热区都往四周缝隙里溢出
        .padding(.horizontal, -7)
        .padding(.vertical, -6)
        .notchTip(tab.title)
    }

    /// 启动台/闪问是大梁老师指定的自绘图形（SF Symbols 无此样式），其余走系统 symbol
    @ViewBuilder
    private var iconView: some View {
        switch tab {
        case .launcher:
            AppStoreIcon()
        case .chat:
            AIBadgeIcon()
        default:
            // 字号 17 由阶梯图肉眼校准：与 17pt 自绘框视觉等大。
            // 不能用 resizable 拉伸——会破坏字形线宽比例，线条比自绘粗一截
            Image(systemName: tab.icon)
                .font(.system(size: 17))
        }
    }
}

/// 启动台图标：大梁老师提供的 App Store 圆形原图（bundle 资源），
/// 模板渲染跟随前景色，A 镂空处原图即透明
private struct AppStoreIcon: View {
    var body: some View {
        if let img = NSImage(named: "TabIconLauncher") {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                // 圆比方显小（光学错觉），直径 18 补偿后与 17 方框视觉等大；占位仍 17
                .frame(width: 18, height: 18)
                .frame(width: 17, height: 17)
        } else {
            // swift run 裸二进制无 bundle 资源时兜底
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 17))
        }
    }
}

/// 闪问图标：圆角方框内「AI」，右下角四角星压在框线上（框线在星处断开让位）
private struct AIBadgeIcon: View {
    private let size: CGFloat = 17
    /// 星心相对图标中心的偏移（落在框右下角上）
    private let starOffset: CGFloat = 5.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.6, style: .continuous)
                .strokeBorder(lineWidth: 2.0)
                .mask {
                    // 挖洞：放大一号的星形区域擦掉框线，星与框之间留出空隙
                    ZStack {
                        Rectangle()
                        SparkleShape()
                            .frame(width: 12, height: 12)
                            .offset(x: starOffset, y: starOffset)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            Text("AI")
                .font(.system(size: 7.5, weight: .bold))
                .offset(x: -0.5, y: -0.5)
            SparkleShape()
                .frame(width: 8, height: 8)
                .offset(x: starOffset, y: starOffset)
        }
        .frame(width: size, height: size)
    }
}

/// 四角星（菱形凹边），fill 用
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let tips = [CGPoint(x: rect.midX, y: rect.minY),   // 上
                    CGPoint(x: rect.maxX, y: rect.midY),   // 右
                    CGPoint(x: rect.midX, y: rect.maxY),   // 下
                    CGPoint(x: rect.minX, y: rect.midY)]   // 左
        p.move(to: tips[0])
        for i in 0..<4 {
            let next = tips[(i + 1) % 4]
            let mid = CGPoint(x: (tips[i].x + next.x) / 2, y: (tips[i].y + next.y) / 2)
            // 控制点从边中点向星心收，收得越多星越瘦；0.55 取饱满适中
            let control = CGPoint(x: mid.x + (c.x - mid.x) * 0.55,
                                  y: mid.y + (c.y - mid.y) * 0.55)
            p.addQuadCurve(to: next, control: control)
        }
        p.closeSubpath()
        return p
    }
}
