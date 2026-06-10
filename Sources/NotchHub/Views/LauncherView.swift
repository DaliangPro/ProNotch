import SwiftUI

/// App 启动台：搜索框 + 置顶槽位区 + 全部应用滚动网格
struct LauncherView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: LauncherStore

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    private var filteredApps: [AppEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.allApps }
        return store.allApps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    /// 图标(48pt)居中于网格单元，标题行内缩到与首末列图标边缘对齐：
    /// 内容宽 680，8 列间距 10 → 单元宽 76.25，(76.25-48)/2 ≈ 14
    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 置顶区：固定槽位，不随滚动移动
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<store.maxPinned, id: \.self) { index in
                    if index < store.pinned.count {
                        AppCell(app: store.pinned[index])
                    } else {
                        EmptySlotView()
                    }
                }
            }

            HStack {
                SectionHeader(title: searchText.isEmpty
                    ? "全部应用"
                    : "搜索结果（\(filteredApps.count)）")
                Spacer()
                searchField
            }
            .padding(.horizontal, edgeInset)

            ScrollView(showsIndicators: false) {
                if filteredApps.isEmpty {
                    Text("没有匹配的应用")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(filteredApps) { app in
                            AppCell(app: app)
                        }
                    }
                }
            }
        }
        .onAppear { store.refreshIfNeeded() }
        .onChange(of: searchFocused) { focused in
            // 搜索框聚焦期间暂停自动收起，避免打字时鼠标不在面板上导致面板消失
            vm.keyboardHold = focused
        }
        .onDisappear { vm.keyboardHold = false }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
            TextField("", text: $searchText,
                      prompt: Text("搜索应用")
                          .foregroundColor(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .focused($searchFocused)
                .onSubmit { launchFirstResult() }
                .onExitCommand {
                    searchText = ""
                    searchFocused = false
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(searchFocused ? 0.14 : 0.08)))
        .frame(width: 180)
        .help("回车启动第一个结果，Esc 清空")
    }

    private func launchFirstResult() {
        guard !searchText.isEmpty, let first = filteredApps.first else { return }
        store.launch(first)
        vm.collapseNow()
    }
}

/// 置顶区空槽位：右键下方应用图标可置顶到此处
private struct EmptySlotView: View {
    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.15)))
            Text(" ")
                .font(.system(size: 10))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .help("右键下方应用图标可置顶到此处")
    }
}

private struct AppCell: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: LauncherStore
    let app: AppEntry

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
                Text(app.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
