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

    @State private var draggingApp: AppEntry?
    @State private var dragOffset: CGSize = .zero

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)
    /// 图标(48pt)居中于网格单元，分隔线内缩到与首末列图标边缘对齐
    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 置顶区：固定槽位、只显示图标。拖动用 SwiftUI 手势自绘——图标跟手移动、
            // 其它图标实时让位、松手弹簧弹回，全程动画自控（不走系统拖放的归位动画）
            HStack(spacing: 10) {
                ForEach(store.pinned) { app in
                    DraggablePinnedCell(app: app,
                                        dragging: $draggingApp,
                                        dragOffset: $dragOffset)
                }
                ForEach(Array(0..<max(0, store.maxPinned - store.pinned.count)), id: \.self) { _ in
                    EmptySlotView()
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

/// 置顶图标：手势自绘拖动重排。一个 DragGesture 同时承担「点击启动」与「拖动换位」——
/// 移动超过阈值才算拖动，否则按点击处理；拖到覆盖某槽位即实时 move + 让位（弹簧动画），
/// 松手弹簧把 offset 归零、平滑落到新位置。全程不经系统拖放，故无归位卡顿、无半透明预览。
private struct DraggablePinnedCell: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: LauncherStore
    let app: AppEntry
    @Binding var dragging: AppEntry?
    @Binding var dragOffset: CGSize

    @State private var hovering = false
    @State private var jumping = false
    @State private var startIndex = 0
    @State private var cellW: CGFloat = 0

    private var isDragging: Bool { dragging?.id == app.id }
    /// 相邻槽位中心间距 = 实测单元宽 + HStack 间距(10)
    private var stride: CGFloat { cellW + 10 }

    var body: some View {
        Button { if dragging == nil { launch() } } label: {   // 整体用 Button：与「全部应用」同款，第一下点击必生效；拖动中(dragging非空)不启动
            Image(nsImage: AppIconCache.icon(for: app.url))
                .resizable()
                .frame(width: 48, height: 48)
                .offset(y: jumping ? -10 : 0)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .background(GeometryReader { g in
                    Color.clear.onAppear { cellW = g.size.width }
                })
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(isDragging ? dragOffset : .zero)
        .zIndex(isDragging ? 1 : 0)
        .onHover { hovering = $0 }
        .help(app.name)
        .simultaneousGesture(   // 拖动换位叠加在 Button 上：移动超 6px 才算拖动，不影响第一下单击
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    guard let current = store.pinned.firstIndex(where: { $0.id == app.id }) else { return }
                    if dragging == nil {
                        dragging = app
                        startIndex = current
                    }
                    // 目标槽位 = 起始槽位 + 累计位移格数（基于起点，不逐帧漂移）
                    let target = min(max(startIndex + Int((value.translation.width / stride).rounded()), 0),
                                     store.pinned.count - 1)
                    if target != current {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                            store.movePinned(from: current, to: target)
                        }
                    }
                    // 视觉偏移每帧重算 = 跟手位移 − 当前槽位相对起点的布局位移（让图标始终贴着鼠标）
                    let nowIndex = store.pinned.firstIndex(where: { $0.id == app.id }) ?? target
                    dragOffset = CGSize(
                        width: value.translation.width - CGFloat(nowIndex - startIndex) * stride,
                        height: value.translation.height)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { dragOffset = .zero }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if dragging?.id == app.id { dragging = nil }
                    }
                }
        )
        .contextMenu {
            Button("取消置顶") { store.togglePin(app) }
        }
    }

    /// 点击启动：Dock 同款跳动反馈后收起面板
    private func launch() {
        store.launch(app)
        withAnimation(.easeOut(duration: 0.28)) { jumping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { jumping = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) { vm.collapseNow() }
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
    @State private var jumping = false

    var body: some View {
        Button {
            store.launch(app)
            // Dock 同款跳动反馈：图标弹起落回，让用户确认点击成功后再收起；
            // 节奏对齐 Dock（上弹约 0.28s、回落约 0.4s）
            withAnimation(.easeOut(duration: 0.28)) { jumping = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    jumping = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) {
                vm.collapseNow()
            }
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: AppIconCache.icon(for: app.url))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .offset(y: jumping ? -10 : 0)
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
