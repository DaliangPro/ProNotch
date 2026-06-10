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
            // 刘海两侧的快捷操作区（中间给真实刘海让位）
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
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                Color.clear.frame(width: vm.notchRect.width + 24)

                HStack(spacing: 4) {
                    Spacer()
                    StripButton(icon: quickActions.caffeinateActive
                                    ? "cup.and.saucer.fill" : "cup.and.saucer",
                                help: quickActions.caffeinateActive
                                    ? "防休眠已开启（点击关闭）" : "防休眠：保持 Mac 不锁屏不休眠",
                                active: quickActions.caffeinateActive) {
                        quickActions.toggleCaffeinate()
                    }
                    StripButton(icon: "lock",
                                help: "熄屏锁定") {
                        vm.collapseNow()
                        quickActions.lockScreen()
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
                Text(chatStore.model)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            if !chatStore.messages.isEmpty {
                AccessoryButton(title: "新对话") { chatStore.clearConversation() }
            }
            AccessoryIconButton(systemName: "gearshape", help: "API 设置") {
                chatStore.showSettings.toggle()
            }
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

/// 刘海两侧快捷操作按钮：圆形可点击区域、悬停高亮，激活态青色
private struct StripButton: View {
    let icon: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(active ? .cyan : .white.opacity(hovering ? 0.9 : 0.45))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 顶行功能区图标按钮：圆形可点击区域、悬停高亮
private struct AccessoryIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.55))
                .padding(6)
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
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isActive ? .white : .white.opacity(hovering ? 0.85 : 0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(
                Color.white.opacity(isActive ? 0.18 : (hovering ? 0.08 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
