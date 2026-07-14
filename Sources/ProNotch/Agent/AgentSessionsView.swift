import SwiftUI

/// 刘海「Agent」页:本机 Claude Code / Codex 会话卡片列表。
/// 「可能在等你」橙点呼吸置顶,运行中青点,空闲灰点;每卡显示项目、模型、最后一句
struct AgentSessionsView: View {
    @EnvironmentObject var store: AgentSessionsStore
    @EnvironmentObject var vm: NotchViewModel
    /// 看着页面时状态要自己动:8 秒轮询,仅面板展开且当前页可见时才真的刷
    private let ticker = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

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
            } else {
                // 左右分栏:Claude 左 / Codex 右,各自独立滚动,不混排
                HStack(alignment: .top, spacing: 10) {
                    sourceColumn(.claude, title: "Claude Code", tint: Color(hex: "#ED8445"))
                    sourceColumn(.codex, title: "Codex", tint: .cyan)
                }
            }
        }
        .onAppear { store.refresh() }
        .onReceive(ticker) { _ in
            if vm.isExpanded, vm.activeTab == .agent { store.refresh(force: true) }
        }
    }

    /// 一个来源的分栏:着色标题 + 竖排方块卡,栏内独立滚动;无会话显示轻空态保持左右对称
    private func sourceColumn(_ source: AgentSession.Source, title: String, tint: Color) -> some View {
        let items = store.sessions.filter { $0.source == source }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(title).font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text("\(items.count)").font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
            if items.isEmpty {
                Text("暂无会话")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(items) { SessionCard(session: $0) }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SessionCard: View {
    let session: AgentSession
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: AgentSessionsStore
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
