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
    @State private var tabDragOffset: CGSize = .zero

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
            // 左侧 = 设置入口 + 三枚状态开关（防休眠 / 净屏 / 锁定），同款胶囊同款青色激活
            // 右侧 = 系统外观切换 + Agent 完成提醒总开关
            HStack(spacing: 0) {
                HStack(spacing: 14) {   // 间距与标签行一致，四颗列位对齐下方前四个标签
                    // 顺序：设置 → 防休眠 → 净屏 → 锁定
                    // 设置入口：固定最左；实心齿轮（大梁老师从候选 A 选定）
                    StripButton(icon: "gearshape.fill",
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
                    // 锁定面板（大梁老师 2026-07-26 定）：原先是浮在面板左边缘的一枚锁，
                    // 悬停会展开「锁定」中文标签；现收进这一排，与净屏同款 StripToggle——
                    // 无内嵌文字、点一下即切，中文说明只走悬停气泡。
                    // 字形恒定不随开关变（不再 lock.open ↔ lock.fill 互换），
                    // 只靠青色区分开关态，与左边防休眠 / 净屏两颗同一套语言。
                    // 说明文字恒为「锁定刘海」（大梁老师定），不随开关态改口径
                    StripToggle(icon: "lock",
                                active: vm.isPinned,
                                help: "锁定刘海") {
                        vm.isPinned.toggle()
                    }
                    .notchTip("锁定刘海")
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
                // 标签拖动换位：与启动台置顶图标同款自绘手势重排（大梁老师点名去虚影），
                // 顺序持久化由 tabOrder didSet 承接
                ForEach(vm.visibleTabs, id: \.self) { tab in
                    DraggableTabCell(tab: tab, isActive: shownTab == tab, ns: tabIndicatorNS,
                                     dragging: $draggedTab, dragOffset: $tabDragOffset)
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
        .onChange(of: vm.activeTab) { old, new in
            let oi = vm.visibleTabs.firstIndex(of: old) ?? 0
            let ni = vm.visibleTabs.firstIndex(of: new) ?? 0
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
            AccessoryButton(icon: "arrow.clockwise", tip: "刷新") { usageStore.refresh(force: true) }
        case .agent:
            if !agentSessions.sessions.isEmpty {
                Text("\(agentSessions.sessions.count) 个会话")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            AccessoryButton(icon: "arrow.clockwise", tip: "刷新") { agentSessions.refresh(force: true) }
        case .widgets:
            AccessoryButton(icon: "arrow.clockwise", tip: "刷新") {
                memoryStore.refresh()
                weatherStore.refresh(force: true)
            }
        }
    }
}

/// 右上角模型切换器（大梁老师定）：点击展开面板内自绘下拉，选中立即生效并持久化；
/// 列表不走系统菜单——无边框面板里系统弹窗定位会飘（与设置表单的下拉同一处理）。
/// 非 private：闪问独立窗口的顶栏也要用它（否则那边看不到、也换不了模型）
struct ModelSwitcher: View {
    /// 下拉往上弹。闪问独立窗口把这个胶囊放在输入框下方（大梁老师定），
    /// 往下弹会整片溢出窗口底边被裁掉——那正是他反馈「菜单看不清字」的成因，
    /// 只不过上一版溢出的是左边缘。刘海那边仍是往下弹，行为不变
    var dropUp = false

    @EnvironmentObject var chatStore: ChatStore
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var quickActions: QuickActionsStore
    @State private var showList = false
    @State private var hovering = false
    /// 胶囊自身的宽度。展开的面板要和它**一样宽**，看着才是「这颗胶囊长高了」，
    /// 而不是旁边浮出一块面板（大梁老师 2026-07-30）
    @State private var chipWidth: CGFloat = 0

    /// 展开后这一整块（面板 + 当作底座的按钮）的底色。
    /// 试过 SwiftUI 材质和系统菜单材质，在半透明窗里都渲成近黑、和窗内其他块差一大截；
    /// 0.31 是量出来的：约 (79,79,79)，正落在窗底 66 与 AI 气泡 82 之间
    static let panelFill = Color(white: 0.31)

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { showList.toggle() }
            // 首次点开还没有列表就现拉一次（结果持久化，之后秒开）；当前套没 Key 就别白拉
            if chatStore.isConfigured, chatStore.availableModels.isEmpty { chatStore.fetchModels() }
        } label: {
            HStack(spacing: 4) {
                // 展示人类可读名（任务书 §10.2.1）；slug 仍是数据层的唯一标识
                Text(chatStore.model.isEmpty ? "选择模型" : ModelDisplayName.of(chatStore.model))
                    .font(.system(size: dropUp ? 11.5 : 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // **不要**在这儿写 frame(maxWidth:)。SwiftUI 的 maxWidth 会撑满可用宽度：
                    // 短模型名占满 170pt，右边的箭头被顶到最远处，中间空一大块
                    //（先是「文字左边有留白」，加了 alignment 又变成「文字和箭头之间有留白」，
                    // 两次都是同一个误用）。lineLimit + 中间截断已经够收住超长名字
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .rotationEffect(.degrees(showList ? 180 : 0))
            }
            // 与联网 / 深度思考同一套：静态次级色，悬停或展开才提亮
            .foregroundColor(dropUp
                             ? (hovering || showList ? .white.opacity(0.95) : .white.opacity(0.64))
                             : .white.opacity(hovering || showList ? 0.9 : 0.55))
            // 独立窗口里它和「联网」「深度思考」并排，得跟那两个胶囊等身：
            // 26 高 / 11.5 字 / 8 内边距。原来照搬刘海的 31 高 12.5 字，
            // 站在它们旁边就是大一圈（大梁老师：「胶囊太大太宽」，2026-07-30）
            .padding(.horizontal, dropUp ? 8 : 10)
            // 刘海里定高 31：与同排标签胶囊(42×31)上下沿齐平（大梁老师定的统一度量）
            .frame(height: dropUp ? 28 : 31)
            // 展开时按钮**就是面板的底**：同色、只圆下面两角，上沿平着接住面板。
            // 这样模型名从头到尾只有一份，不会因为「面板里再画一份」而交叉淡化出抖动
            //（大梁老师 2026-07-30 实机反馈）
            .background {
                if dropUp, showList {
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14,
                                           bottomTrailingRadius: 14, topTrailingRadius: 0,
                                           style: .continuous)
                        .fill(Self.panelFill)
                } else {
                    // 静态无底色，悬停才有一层极淡的白——与另两个控件完全一致
                    Capsule().fill(Color.white.opacity(hovering ? 0.07 : 0))
                }
            }
            .background(GeometryReader { g in
                Color.clear.onAppear { chipWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in chipWidth = w }
            })
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 刘海里布局占位缩回 25（与标签行/搜索框同款负 padding）：行高与右缘对齐线不动。
        // 窗口里胶囊本来就只有 26，再缩就和邻居对不齐了
        .padding(.vertical, dropUp ? 0 : -3)
        // 曾经在这儿写过 .padding(.leading, -8) 来抵掉胶囊自带的内边距，
        // 好让模型名与上方占位符对齐。现在改由**整条控件行**外探 8pt 实现
        //（见 windowComposer），这里再抵一次就成了 16，胶囊会戳出输入框
        .help(chatStore.model.isEmpty ? "切换配置 / 模型" : "切换配置 / 模型（当前 \(chatStore.model)）")
        // 下拉悬浮在按钮右下方，盖住内容页不参与布局（标签行 zIndex 已抬高）；
        // 34 = 布局高 25 + 胶囊下凸 3 + 气口 6
        // 往下弹时按右缘对齐（刘海里这个胶囊在顶栏右侧，往左展开正好）；
        // 往上弹时按左缘对齐（独立窗口里它在左下角，往右展开才有地方）
        // 往上弹时 offset 归零：整块面板的**底边压在胶囊上**，面板最下面那行就是
        // 按钮自己（模型名 + 向上的箭头），于是看着是「顺着这个按钮往上长出来的」，
        // 而不是旁边浮起来一块（大梁老师 2026-07-30）。
        // 往下弹（刘海）沿用原来的 34 悬浮
        .overlay(alignment: dropUp ? .bottomLeading : .topTrailing) {
            // x 偏 -8：上面那句 .padding(.leading, -8) 让布局框比内容窄 8pt，
            // overlay 贴的是**布局框**的左缘，不补这 8 展开后模型名会整体右移 8pt——
            // 一动就露馅，看着就不是同一个东西了
            // 往上弹：抬过按钮自身高度(26)，底边正好压在按钮上沿，接成一整块。
            // x 偏 -8 是补上面那句 .padding(.leading, -8) 缩掉的布局宽度
            if showList { dropdown.offset(x: dropUp ? -8 : 0, y: dropUp ? -26 : 34) }
        }
        // ⌘K 呼出（任务书 §11）。只有独立窗口那份响应——刘海里的那份也监听的话，
        // 一次 ⌘K 会同时弹两个下拉
        .onChange(of: chatStore.openModelPickerTick) { _, _ in
            guard dropUp else { return }
            withAnimation(.easeOut(duration: 0.12)) { showList = true }
            if chatStore.isConfigured, chatStore.availableModels.isEmpty { chatStore.fetchModels() }
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
                        SwitcherRow(name: ModelDisplayName.of(name),
                                    isSelected: name == chatStore.model,
                                    compact: dropUp) {
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
        // 严格取胶囊实测宽度（量不到才退 160），圆角取胶囊的 13＝26÷2，
        // 底端接缝才严丝合缝。写死下限会让面板比胶囊宽出一截，右边缘顶到「联网」上
        .frame(width: dropUp ? (chipWidth > 1 ? chipWidth : 160) : 220)
        // 刘海里是不透明近黑（要和屏幕顶端的黑连成一片）；独立窗口那是一块毛玻璃，
        // 再摆一块近黑硬色板就格格不入（大梁老师 2026-07-30）。
        // 窗口改用与输入块同一套：regularMaterial + 一层浅填充 + 细描边 + 半径 14
        .background {
            if dropUp {
                // 这块浮层试过两条路都不行：SwiftUI 的 .regularMaterial 渲成近黑，
                // NSVisualEffectView 的 .menu 也一样黑——离屏取样 (34,34,34)，
                // 而窗底 66、输入块 58、AI 气泡 82、我的气泡 108，就它一个特别黑，
                // 这正是大梁老师说的「格格不入」（2026-07-30）。
                // 改成一块确定性的同族灰：0.31 渲出来 (79,79,79)，正落在窗底 66 与
                // AI 气泡 82 之间，既像浮起来的一层又不跳。必须完全不透——
                // 试过半透的配方，背后的「问点什么…」直接透过来压在菜单文字上
                // 只圆上面两角，下沿平着落在按钮上——两块拼成一个连续形状。
                // 不描边：描边会在拼接处画出一道横线，一体感就没了
                UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 13,
                                       style: .continuous)
                    .fill(Self.panelFill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
        }
        // 往上弹时投影也要朝上：y 仍为 +4 的话，阴影正好落在下面那个「底座按钮」上，
        // 拼接处压出一道暗带，一体感就断了
        .shadow(color: .black.opacity(0.5), radius: 10, y: dropUp ? -4 : 4)
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
    /// 独立窗口里这块面板要和胶囊等宽（融合的前提），横向就那么点地方——
    /// 内边距、间距、勾选一起收窄，否则模型名会被截成「deepseek-v4-…」
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 4 : 8) {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: compact ? 8 : 9))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
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

/// API 连通状态灯：绿=连通，红=失败（悬停看原因），黄=检测中；点击重新检测。
/// 非 private：闪问独立窗口顶栏共用
struct ConnectivityLight: View {
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

/// 顶行功能区图标按钮（大梁老师定：「刷新」不放中文放图标）：
/// 42×31 胶囊与标签胶囊完全同框，中文说明走悬停气泡
private struct AccessoryButton: View {
    let icon: String
    let tip: String
    let action: () -> Void

    @State private var hovering = false

    /// 15.5 而非标签图标的 17：同样字号下各 symbol 的墨迹大小并不相等。
    /// 离屏实测（点）——arrow.clockwise@17 是 15.0×18.0，箭头尖冒出字框，
    /// 比同排的 gauge.with.needle 17×17、apple.terminal 20×16、square.grid.2x2 16×16
    /// 都高一截，一排图标里就它显眼。降到 15.5 后墨迹 13.5×16.25，落回三者均高 16.3，
    /// 视觉齐平（2026-07-26 大梁老师报「刷新按钮比左侧图标大」）
    private let iconSize: CGFloat = 15.5

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.55))
                .frame(width: 42, height: 31)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 布局占位缩回 25（与标签行/搜索框同款负 padding）：行高不动
        .padding(.vertical, -3)
        .notchTip(tip)
    }
}

/// 标签拖动换位：照搬启动台置顶图标的手势自绘重排（DraggablePinnedCell 同款）。
/// 一个 DragGesture 兼任「点击切页」与「拖动换位」——移动超 6px 才算拖动；
/// 拖过半格即实时 move + 弹簧让位，松手弹簧归零平滑落位。
/// 全程不经系统拖放，无半透明预览虚影（大梁老师点名去掉）。
private struct DraggableTabCell: View {
    @EnvironmentObject var vm: NotchViewModel
    let tab: NotchViewModel.Tab
    let isActive: Bool
    let ns: Namespace.ID
    @Binding var dragging: NotchViewModel.Tab?
    @Binding var dragOffset: CGSize

    @State private var startIndex = 0

    /// 相邻标签中心间距：布局占位 36（42 胶囊 + 8 热区 − 14 负 padding）+ HStack 间距 14。
    /// 标签胶囊等宽，恒定步距成立（与置顶图标的 cellW+14 同理）
    private let slotStride: CGFloat = 50

    private var isDragging: Bool { dragging == tab }

    var body: some View {
        TabButton(tab: tab, isActive: isActive, ns: ns) {
            if dragging == nil { vm.activeTab = tab }   // 拖动松手不算点击
        }
        .offset(isDragging ? dragOffset : .zero)
        .zIndex(isDragging ? 1 : 0)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    // 拖拽全程在「可见页」索引空间计算：有隐藏页时视觉槽位≠tabOrder 槽位，
                    // 直接换算 tabOrder 会错位（隐藏页夹在中间时尤甚）
                    let vis = vm.visibleTabs
                    guard let current = vis.firstIndex(of: tab) else { return }
                    if dragging == nil {
                        dragging = tab
                        startIndex = current
                    }
                    // 目标槽位 = 起始槽位 + 累计位移格数（基于起点，不逐帧漂移）
                    let target = min(max(startIndex + Int((value.translation.width / slotStride).rounded()), 0),
                                     vis.count - 1)
                    if target != current {
                        var newVisible = vis
                        newVisible.move(fromOffsets: IndexSet(integer: current),
                                        toOffset: target > current ? target + 1 : target)
                        // 稳定合并写回：可见页按新序流入可见槽位，隐藏页锚定原位不动
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                            vm.tabOrder = NotchViewModel.mergeVisibleOrder(full: vm.tabOrder, visible: newVisible)
                        }
                    }
                    // 视觉偏移每帧重算 = 跟手位移 − 当前槽位相对起点的布局位移（胶囊贴着鼠标走）
                    let nowIndex = vm.visibleTabs.firstIndex(of: tab) ?? target
                    dragOffset = CGSize(
                        width: value.translation.width - CGFloat(nowIndex - startIndex) * slotStride,
                        height: value.translation.height)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { dragOffset = .zero }
                    // 延迟清 dragging：让 Button 的 mouse-up 先看到「在拖动」而不触发切页
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if dragging == tab { dragging = nil }
                    }
                }
        )
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
                // 圆比方显小（光学错觉），直径 18 补偿后与 17 方框视觉等大；占位仍 17。
                // 22.5 = 18 ÷ 0.8：本原件的圆只占画布 80%（四周留白），
                // 直接给 18 的话圆实际只有 14.4pt，肉眼就比旁边几个小一圈（大梁老师指出）。
                // 换原件时务必重算这个系数——按内容占比反推，别照抄数字
                .frame(width: 22.5, height: 22.5)
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
