import SwiftUI

/// 展开后的面板内容：顶部标签栏 + 各功能页（M0 阶段为占位实现）
struct ExpandedContentView: View {
    @EnvironmentObject var vm: NotchViewModel

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
            }

            Group {
                switch vm.activeTab {
                case .launcher:
                    LauncherView()
                case .clipboard:
                    ClipboardView()
                case .chat:
                    PlaceholderView(icon: "sparkles",
                                    title: "AI 对话", note: "M3 实现")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
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

private struct PlaceholderView: View {
    let icon: String
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
            Text(note)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
        }
    }
}
