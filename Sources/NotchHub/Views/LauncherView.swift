import SwiftUI

/// 顶行搜索框：与启动台网格共用 LauncherStore.searchText
struct LauncherSearchField: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: LauncherStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
            TextField("", text: $store.searchText,
                      prompt: Text("搜索应用")
                          .foregroundColor(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .focused($focused)
                .onSubmit { launchFirstResult() }
                .onExitCommand {
                    store.searchText = ""
                    focused = false
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(focused ? 0.14 : 0.08)))
        .frame(width: 190)
        .help("回车启动第一个结果，Esc 清空")
        .onChange(of: focused) { vm.keyboardHold = $0 }
        .onDisappear { vm.keyboardHold = false }
    }

    private func launchFirstResult() {
        guard !store.searchText.isEmpty,
              let first = store.filteredApps.first else { return }
        store.launch(first)
        vm.collapseNow()
        store.searchText = ""
    }
}

/// App 启动台：置顶槽位区 + 分隔线 + 全部应用滚动网格
struct LauncherView: View {
    @EnvironmentObject var store: LauncherStore

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)
    /// 图标(48pt)居中于网格单元，分隔线内缩到与首末列图标边缘对齐
    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 置顶区：固定槽位、只显示图标不带名字，给下方腾空间
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<store.maxPinned, id: \.self) { index in
                    if index < store.pinned.count {
                        AppCell(app: store.pinned[index], showsName: false)
                    } else {
                        EmptySlotView()
                    }
                }
            }

            // 浅分隔线区分置顶区与全部应用
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, edgeInset)

            ScrollView(showsIndicators: false) {
                if store.filteredApps.isEmpty {
                    Text("没有匹配的应用")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.filteredApps) { app in
                            AppCell(app: app)
                        }
                    }
                    // 底部留白与渐隐高度匹配；顶部不留白，
                    // 保证分割线上下与图标的间距一致（各约 12pt）
                    .padding(.bottom, 14)
                }
            }
            // 滚动到边缘的图标渐隐消失，替代生硬截断；
            // 顶部渐隐压窄到 5pt，只覆盖格子内边距，静止时首行不受影响
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 5)
                    Rectangle().fill(Color.black)
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
            )
        }
        .onAppear { store.refreshIfNeeded() }
    }
}

/// 置顶区空槽位：右键下方应用图标可置顶到此处
private struct EmptySlotView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.white.opacity(0.12),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: 48, height: 48)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.15)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .help("右键下方应用图标可置顶到此处")
    }
}

private struct AppCell: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: LauncherStore
    let app: AppEntry
    var showsName = true

    @State private var hovering = false

    var body: some View {
        Button {
            store.launch(app)
            vm.collapseNow()
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: AppIconCache.icon(for: app.url))
                    .resizable()
                    .frame(width: 48, height: 48)
                if showsName {
                    Text(app.name)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(app.name)
        .contextMenu {
            if store.isPinned(app) {
                Button("取消置顶") { store.togglePin(app) }
            } else if store.pinned.count < store.maxPinned {
                Button("置顶") { store.togglePin(app) }
            } else {
                Button("置顶（已满，请先取消一个）") {}
                    .disabled(true)
            }
        }
    }
}
