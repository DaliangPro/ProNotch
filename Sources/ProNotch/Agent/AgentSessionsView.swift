import SwiftUI

/// 刘海「Agent」页:本机 Claude Code / Codex 会话卡片列表。
/// 「可能在等你」橙点呼吸置顶,运行中青点,空闲灰点;每卡显示项目、模型、最后一句
struct AgentSessionsView: View {
    @EnvironmentObject var store: AgentSessionsStore
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var usageStore: UsageStore
    @EnvironmentObject var settings: SettingsStore
    /// 看着页面时状态要自己动:8 秒轮询,仅面板展开且当前页可见时才真的刷
    private let ticker = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    /// 出场动画开关：两栏会话卡逐张发牌式上浮，切页/展开时重播
    @State private var entrancePlayed = false

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 24)).foregroundColor(.white.opacity(0.25))
                    Text("48 小时内没有 Agent 会话")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(entrancePlayed ? 1 : 0.92)
                .opacity(entrancePlayed ? 1 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: entrancePlayed)
            } else {
                // 按家分栏(勾选且支持监控台的),各自独立滚动,不混排
                HStack(alignment: .top, spacing: 10) {
                    ForEach(sessionKinds) { kind in
                        sourceColumn(kind, title: kind.displayName, tint: columnTint(kind))
                    }
                }
            }
        }
        .padding(.horizontal, ExpandedContentView.pageHInset)   // 左右留白对齐全局基准线
        .pageEntrance($entrancePlayed)
        .onAppear { store.refresh(); usageStore.refresh() }   // 顺带刷额度：拿每会话 token 消耗
        .onReceive(ticker) { _ in
            // 会话列表 8 秒一刷（本地文件，随便刷）；额度走 5 分钟节流的顺带通道，
            // 免得停在这一页就把 Kimi/Grok 的 token 接口按 30 秒一轮薅着
            if vm.isExpanded, vm.activeTab == .agent { store.refresh(force: true); usageStore.refreshIncidental() }
        }
    }

    /// 勾选且支持监控台的家(至少留 Claude/Codex 的空列对称感:全取消时上面早走了空态分支)
    private var sessionKinds: [AgentKind] {
        AgentKind.allCases.filter { $0.supportsSessions && settings.enabledAgents.contains($0) }
    }

    /// 列头点色:比卡片 tint 略提亮的品牌色
    private func columnTint(_ kind: AgentKind) -> Color {
        switch kind {
        case .claude: return Color(hex: "#ED8445")
        case .codex: return .cyan
        default: return kind.tint
        }
    }

    /// 一个来源的分栏:着色标题 + 竖排方块卡,栏内独立滚动;无会话显示轻空态保持左右对称
    private func sourceColumn(_ source: AgentKind, title: String, tint: Color) -> some View {
        let items = store.sessions.filter { $0.source == source }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(title).font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text("\(items.count)").font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity)   // 角标在本列内居中（大梁老师定），不贴左
            if items.isEmpty {
                Text("暂无会话")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(entrancePlayed ? 1 : 0)
                    .animation(.easeOut(duration: 0.3).delay(0.1), value: entrancePlayed)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        // 发牌：每张卡比上一张晚 0.055s 上浮进场，两栏并行各发各的
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, session in
                            SessionCard(session: session)
                                .offset(y: entrancePlayed ? 0 : 14)
                                .opacity(entrancePlayed ? 1 : 0)
                                .animation(.spring(response: 0.36, dampingFraction: 0.66)
                                    .delay(min(0.05 + Double(i) * 0.055, 0.38)),
                                           value: entrancePlayed)
                        }
                    }
                    .padding(.bottom, 12)   // 底部留白与渐隐等高，滚到底最后一张卡不被吃掉
                }
                // 滚到底的卡片渐隐消失，替代生硬截断（与启动器页同一范式）
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.black)
                        LinearGradient(colors: [.black, .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 12)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SessionCard: View {
    let session: AgentSession
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: AgentSessionsStore
    @EnvironmentObject var usageStore: UsageStore
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StateDot(state: session.state, animate: vm.isExpanded)
                Text(session.title ?? session.projectName)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                if session.title != nil {   // 有对话名时,项目名(文件夹)作归属显示在副行
                    Text(session.projectName)
                        .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Text(stateText)
                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(stateColor)
                Text(Self.ago(session.lastActivity))
                    .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.35))
                Spacer()
                if let tok = usageStore.sessionTokens[session.key], tok > 0 {
                    Text(Self.tokenText(tok))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            Text(session.lastMessage ?? "(没有可显示的消息)")
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.09 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(session.state.needsAttention ? Color(hex: "#FF9F0A").opacity(session.state == .waiting ? 0.6 : 0.35) : Color.white.opacity(0.08),
                          lineWidth: session.state == .waiting ? 1 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            store.activate(session)   // 切到该会话所在的终端/IDE
            vm.collapseNow()
        }
        .onHover { hovering = $0 }
        .help("点击跳到该会话所在 App\n\(session.projectPath)\(session.model.map { "\n模型: \($0)" } ?? "")")
    }

    private var stateText: String {
        switch session.state {
        case .waiting: return "该你了"
        case .running: return "运行中"
        case .idle: return "空闲"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .waiting: return Color(hex: "#FF9F0A")
        case .running: return .cyan
        case .idle: return .white.opacity(0.35)
        }
    }

    private static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 90 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    /// 会话消耗的有效 token（绝对量）
    private static func tokenText(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM token", Double(t) / 1_000_000) }
        if t >= 1_000 { return "\(t / 1000)K token" }
        return "\(t) token"
    }
}

/// 状态点:等你确认橙色呼吸(仅面板展开时动画,收起即停避免常驻标脏),运行中青色,空闲灰
private struct StateDot: View {
    let state: AgentSession.State
    let animate: Bool
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(state.needsAttention ? (breathing ? 1 : 0.35) : 1)
            .animation(state.needsAttention && animate
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : .default, value: breathing)
            .onAppear { breathing = animate && state.needsAttention }
            .onChange(of: animate) { _, on in breathing = on && state.needsAttention }
    }

    private var color: Color {
        switch state {
        case .waiting: return Color(hex: "#FF9F0A")
        case .running: return .cyan
        case .idle: return .white.opacity(0.3)
        }
    }
}
