import SwiftUI

/// 展开后的面板内容：顶行 = 标签栏（左）+ 当前页功能区（右），下方为功能页
struct ExpandedContentView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var launcherStore: LauncherStore
    @EnvironmentObject var clipboardStore: ClipboardStore
    @EnvironmentObject var chatStore: ChatStore
    @EnvironmentObject var quickActions: QuickActionsStore

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(spacing: 10) {
            // 刘海两侧的快捷操作区（中间给真实刘海让位）：
            // 左侧动作类用图标（截图放角落，误触代价高的锁屏放内侧）；
            // 右侧开关类用文字胶囊卡（呼应 macOS 状态区在右上的习惯）
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    StripButton(icon: "camera.viewfinder",
                                help: "区域截图，自动进剪贴板历史（首次需授权屏幕录制）") {
                        vm.collapseNow()
                        quickActions.screenshotToClipboard()
                    }
                    StripButton(icon: "gearshape",
                                help: "打开系统设置") {
                        quickActions.openSystemSettings()
                        vm.collapseNow()
                    }
                    StripButton(icon: "lock",
                                help: "熄屏锁定") {
                        vm.collapseNow()
                        quickActions.lockScreen()
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                Color.clear.frame(width: vm.notchRect.width + 24)

                HStack(spacing: 6) {
                    Spacer()
                    AppearanceSlider()
                    StripToggle(title: "防休眠",
                                active: quickActions.caffeinateActive,
                                help: quickActions.caffeinateActive
                                    ? "防休眠已开启（点击关闭）"
                                    : "防止闲置熄屏与休眠；合盖休眠是系统强制行为，"
                                      + "合盖不睡需接电源 + 外接屏（系统合盖模式）") {
                        quickActions.toggleCaffeinate()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: vm.notchRect.height)
            .padding(.horizontal, edgeInset)

            HStack(spacing: 8) {
                ForEach(NotchViewModel.Tab.allCases, id: \.self) { tab in
                    TabButton(tab: tab, isActive: vm.activeTab == tab) {
                        vm.activeTab = tab
                    }
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .onDisappear { launcherStore.searchText = "" }
    }

    /// 顶行右侧：随当前标签页切换的功能区
    @ViewBuilder
    private var accessory: some View {
        switch vm.activeTab {
        case .launcher:
            LauncherSearchField()
        case .clipboard:
            if !clipboardStore.items.isEmpty {
                Text("\(clipboardStore.items.count) 条")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                AccessoryButton(title: "清空") { clipboardStore.clear() }
            }
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

/// 纯文字开关胶囊：开启时整体点亮青色
private struct StripToggle: View {
    let title: String
    let active: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(active ? .cyan : .white.opacity(hovering ? 0.9 : 0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(
                    active ? Color.cyan.opacity(0.18)
                           : Color.white.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
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
        .help(isDark ? "深色模式（点击切换为浅色）" : "浅色模式（点击切换为深色）")
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
            HStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10))
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: .light))
            }
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
