import SwiftUI

/// App 启动台：常用固定区 + 全部应用滚动网格
struct LauncherView: View {
    @EnvironmentObject var store: LauncherStore

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                if !store.pinned.isEmpty {
                    SectionHeader(title: "常用")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.pinned) { app in
                            AppCell(app: app)
                        }
                    }
                }
                SectionHeader(title: "全部应用")
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(store.allApps) { app in
                        AppCell(app: app)
                    }
                }
            }
            .padding(.top, 2)
        }
        .onAppear { store.refreshIfNeeded() }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.4))
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
            Button(store.isPinned(app) ? "取消固定" : "固定到常用") {
                store.togglePin(app)
            }
        }
    }
}
