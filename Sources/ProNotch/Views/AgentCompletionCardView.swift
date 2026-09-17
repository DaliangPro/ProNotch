import SwiftUI

/// 「任务完成」弹窗：完成提醒选「顶部弹窗」时，收起态的刘海「长」出一块卡。
///
/// 与恶劣天气预警共用 `NotchGrownCard`（同一套出场动画，大梁老师要求观感一致）。
/// 整卡可点：点它收卡并回到这个会话所在的 App
struct AgentCompletionCardView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var completion: AgentCompletionStore
    @EnvironmentObject var sessions: AgentSessionsStore

    /// 正在展示的内容：退场动画期间仍要有东西可画，与 store 解耦（同预警卡）
    @State private var displayed: AgentCompletionNotice?
    /// 出场/退场开关：驱动揭示裁剪与过冲弹跳
    @State private var shown = false

    /// 展开态不显示：面板都开着，Agent 页的会话卡本身就在讲这件事
    private var showing: Bool { completion.notice != nil && !vm.isExpanded }

    /// 卡宽。两侧小图标要随卡张开外移到卡的两边（见 `NotchViewModel.grownCardWidth`）
    static let cardWidth: CGFloat = 360

    var body: some View {
        ZStack(alignment: .top) {
            if let n = displayed {
                card(n)
            }
        }
        .onChange(of: showing) { _, on in
            // 收起态窗口对鼠标隐形，大卡在场时临时解除穿透才点得到（见 NotchViewModel）
            vm.agentCardVisible = on
            if on {
                displayed = completion.notice
                // 卡宽登记进 vm 并放在同一条动画事务里：两侧小图标靠它随卡张开一起外移，
                // 分开写就会出现「卡长出来了、图标晚一拍才追上去」
                withAnimation(NotchGrownCardMotion.grow) {
                    shown = true
                    vm.agentCardWidth = Self.cardWidth
                }
            } else {
                withAnimation(NotchGrownCardMotion.shrink) {
                    shown = false
                    vm.agentCardWidth = 0
                } completion: {
                    if !showing { displayed = nil }
                }
            }
        }
        // 展示中又完成了一个：只换卡面，不重播出场
        .onChange(of: completion.notice) { _, new in
            if let new, showing { displayed = new }
        }
        .onAppear {
            // 快照/演示路径：视图出现前 notice 已就位，onChange 等不到，直接摆到位
            if showing {
                displayed = completion.notice
                shown = true
                vm.agentCardVisible = true
                vm.agentCardWidth = Self.cardWidth
            }
        }
    }

    // MARK: - 卡面

    private func card(_ n: AgentCompletionNotice) -> some View {
        NotchGrownCard(width: Self.cardWidth, grownHeight: 132,
                       glow: n.tintHex.map { Color(hex: $0) } ?? n.source.tint, shown: shown,
                       topGap: NotchGrownCardMetrics.inset,
                       bottomGap: NotchGrownCardMetrics.inset) {
            // 先收卡再跳，免得跳过去了刘海还挂着一张。
            // 设置页预览出来的那张没有真会话可回，只收卡
            completion.dismiss()
            if n.session != AgentCompletionNotice.previewSession { jump(n) }
        } content: {
            face(n)
        }
    }

    /// 图标在侧、文字一整块，与它垂直居中。
    /// 项目名单独一行且提亮——同时开着几个项目时，最要紧的是「哪个项目完成了」
    private func face(_ n: AgentCompletionNotice) -> some View {
        let tint = n.tintHex.map { Color(hex: $0) } ?? n.source.tint
        return HStack(spacing: 14) {
            BrandIcon(polys: n.source.polys)
                .foregroundColor(n.source.tint)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("任务完成")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(tint)
                    .padding(.horizontal, 10).padding(.vertical, 3.5)
                    .background(Capsule().fill(tint.opacity(0.16)))
                Text(n.source.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                // 项目名抓不到时（cwd 缺失、老脚本）退一句通用文案，不留空行
                Text(n.project.isEmpty ? "本轮任务已完成" : n.project)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                Text("点击回到 \(hostAppName(n) ?? "对应窗口")")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, NotchGrownCardMetrics.horizontalInset)
    }

    /// 宿主 App 的显示名（Ghostty / Claude…）。与 `jump` 同一套候选顺序，
    /// 保证卡上写的那个 App 就是点下去会跳到的那个
    private func hostAppName(_ n: AgentCompletionNotice) -> String? {
        let candidates = [n.host, n.source.appBundleID].compactMap { $0 }.filter { !$0.isEmpty }
        for bid in candidates {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { continue }
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    /// 跳到那个会话所在的终端 / IDE / 桌面版。
    ///
    /// 会话在监控台列表里就走 `activate`（顺带把该会话的「该你了」标记清掉，
    /// 语义一致：你已经去处理了）；不在列表里（刘海收起时监控台不扫描，新会话可能还没进表）
    /// 就直接按 hook 报来的宿主 bundle id 前置那个 App
    private func jump(_ n: AgentCompletionNotice) {
        if let s = sessions.sessions.first(where: { $0.source == n.source && $0.id == n.session }) {
            sessions.activate(s)
            return
        }
        let candidates = [n.host, n.source.appBundleID].compactMap { $0 }.filter { !$0.isEmpty }
        for bid in candidates {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return
        }
    }
}
