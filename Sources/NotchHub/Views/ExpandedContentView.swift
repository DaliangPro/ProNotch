import SwiftUI

/// 展开后的面板内容：顶行 = 标签栏（左）+ 当前页功能区（右），下方为功能页
struct ExpandedContentView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var launcherStore: LauncherStore
    @EnvironmentObject var clipboardStore: ClipboardStore
    @EnvironmentObject var chatStore: ChatStore

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(spacing: 10) {
            // 给真实刘海让位
            Color.clear.frame(height: vm.notchRect.height)

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
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                Button("清空") { clipboardStore.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
        case .chat:
            if chatStore.isConfigured {
                Text(chatStore.model)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            if !chatStore.messages.isEmpty {
                Button("新对话") { chatStore.clearConversation() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            Button {
                chatStore.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("API 设置")
        }
    }
}

private struct TabButton: View {
    let tab: NotchViewModel.Tab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(isActive ? 0.18 : 0)))
        }
        .buttonStyle(.plain)
    }
}
