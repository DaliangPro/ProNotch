import SwiftUI

/// Agent「等你拍板」大卡：收起态的刘海「长」出一块卡，把它正在等的那个选择摆上来。
///
/// 两种形态（同一套出场动画，与恶劣天气预警共用 `NotchGrownCard`，大梁老师要求观感一致）：
/// - **能当场答复**（Claude Code 的 `PermissionRequest`）：照搬终端里的真实选项，
///   允许一次 / 允许并不再询问 / 拒绝 / 打开终端，按完就走，终端那头不再弹框。
///   大梁老师定的正是这个：「不是给我一个弹窗提醒，而是直接把等我拍板的选项出现在上面」
/// - **只能提醒一声**（别家的中途信号发完就走，收不了答复）：窄卡一张，点它跳到对应终端
struct AgentWaitCardView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var wait: AgentWaitStore
    @EnvironmentObject var sessions: AgentSessionsStore

    /// 正在展示的内容：退场动画期间仍要有东西可画，与 store 解耦（同预警卡）
    @State private var displayed: AgentWaitNotice?
    /// 出场/退场开关：驱动揭示裁剪与过冲弹跳
    @State private var shown = false

    /// 展开态不显示：面板都开着，Agent 页的会话卡本身就在讲这件事
    private var showing: Bool { wait.notice != nil && !vm.isExpanded }

    var body: some View {
        ZStack(alignment: .top) {
            if let n = displayed {
                card(n)
            }
        }
        .onChange(of: showing) { _, on in
            // 收起态窗口对鼠标隐形，大卡在场时临时解除穿透才点得到（见 NotchViewModel）
            vm.agentWaitCardVisible = on
            syncHoverHold()
            if on {
                displayed = wait.notice
                // 卡宽登记进 vm 并放在同一条动画事务里：两侧小图标靠它随卡张开一起外移，
                // 分开写就会出现「卡长出来了、图标晚一拍才追上去」
                withAnimation(NotchGrownCardMotion.grow) {
                    shown = true
                    vm.agentCardWidth = Self.cardWidth(for: wait.notice)
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
        // 展示中来了另一条（另一家 / 另一个会话在等）：只换卡面，不重播出场。
        // 答完一张换上排队里的下一张也走这里，闸门与卡宽都要跟着重算
        //（能答复的宽卡换成只提醒的窄卡时，图标要跟着往里收）
        .onChange(of: wait.notice) { _, new in
            if let new, showing {
                displayed = new
                withAnimation(NotchGrownCardMotion.grow) {
                    vm.agentCardWidth = Self.cardWidth(for: new)
                }
            }
            syncHoverHold()
        }
        .onAppear {
            // 快照/演示路径：视图出现前 notice 已就位，onChange 等不到，直接摆到位
            if showing {
                displayed = wait.notice
                shown = true
                vm.agentWaitCardVisible = true
                vm.agentCardWidth = Self.cardWidth(for: wait.notice)
                syncHoverHold()
            }
        }
    }

    /// 悬停展开的闸门：只有「在等答复」的卡才拦，只提醒一声的那种不拦
    /// （它 8 秒自己走，拦了反而让刘海在这 8 秒里像坏了）
    private func syncHoverHold() {
        vm.answerCardPending = showing && wait.notice?.isAnswerable == true
    }

    // MARK: - 卡面

    /// 卡宽：能答复的那张要摆一行命令 + 一行按钮，只提醒一声的那张窄一半。
    /// 抽成常量是因为两侧小图标要随卡张开外移到卡的两边（见 `NotchViewModel.grownCardWidth`）
    static let answerWidth: CGFloat = 560
    static let noticeWidth: CGFloat = 360

    /// 这条提醒该用多宽的卡。nil＝没有卡
    private static func cardWidth(for notice: AgentWaitNotice?) -> CGFloat {
        guard let notice else { return 0 }
        return notice.isAnswerable ? answerWidth : noticeWidth
    }

    @ViewBuilder
    private func card(_ n: AgentWaitNotice) -> some View {
        if let request = n.request {
            // 光晕用该家品牌色：一眼认出是谁在等你，与额度页/菜单栏同一套颜色语言。
            // 整卡不可点（action: nil）：按钮各答一种决定，「点空白算什么」没有答案。
            // （实测外层 Button 并不会抢走里面按钮的点击，SwiftUI 派给最内层——
            // 这里不套是语义问题，不是事件问题）
            NotchGrownCard(width: Self.answerWidth, grownHeight: Self.grownHeight(for: request),
                           glow: n.source.tint, shown: shown,
                           topGap: NotchGrownCardMetrics.inset,
                           bottomGap: NotchGrownCardMetrics.inset, action: nil) {
                answerFace(n, request)
            }
        } else {
            NotchGrownCard(width: Self.noticeWidth, grownHeight: 132,
                           glow: n.source.tint, shown: shown,
                           topGap: NotchGrownCardMetrics.inset,
                           bottomGap: NotchGrownCardMetrics.inset) {
                // 点卡即去处理：先收卡再跳，免得跳过去了刘海还挂着一张
                wait.dismiss()
                jump(n)
            } content: {
                noticeFace(n)
            }
        }
    }

    /// 能当场答复的卡面。三段自上而下：谁在等（居中）、它要干什么（整宽）、你怎么答（整宽等分）
    private func answerFace(_ n: AgentWaitNotice, _ request: AgentPermissionRequest) -> some View {
        VStack(spacing: 10) {
            header(n)
            detailBlock(request)
            buttons(n, request)
        }
        .padding(.horizontal, NotchGrownCardMetrics.horizontalInset)
    }

    /// 标题行：整组水平居中（大梁老师定「重点信息要居中」）。
    ///
    /// 「还有 N 个在等」并进这一组的尾部、而不是用 Spacer 甩到行尾——
    /// 甩到行尾就又造出一处单侧留白，正是这次要消掉的东西
    private func header(_ n: AgentWaitNotice) -> some View {
        HStack(spacing: 8) {
            tag(n)
            BrandIcon(polys: n.source.polys)
                .foregroundColor(n.source.tint)
                .frame(width: 18, height: 18)
            Text(n.source.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            if !n.project.isEmpty {
                Text("·").foregroundColor(.white.opacity(0.3))
                Text(n.project)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            // 后面还排着几条：不说一声，答完这张突然又冒一张会以为是重复弹的
            if !wait.queued.isEmpty {
                Text("·").foregroundColor(.white.opacity(0.3))
                Text("还有 \(wait.queued.count) 个在等")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 只提醒一声的卡面：**所有文字算一个整体**，品牌图标摆在这个整体的一侧、与它垂直居中
    ///（大梁老师定）。此前是「图标 + 中间两行字」成组，再与上下的胶囊、脚注一起居中，
    /// 图标于是对着两行字的中线而不是整块文字的中线，看着别扭
    private func noticeFace(_ n: AgentWaitNotice) -> some View {
        HStack(spacing: 14) {
            BrandIcon(polys: n.source.polys)
                .foregroundColor(n.source.tint)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                tag(n)
                Text(n.source.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                // 项目名抓不到时（cwd 缺失）退一句通用文案，不留空行
                Text(n.project.isEmpty ? "正在等你选择" : n.project)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                Text("点击跳到对应终端")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, NotchGrownCardMetrics.horizontalInset)
    }

    private func tag(_ n: AgentWaitNotice) -> some View {
        Text("等你拍板")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(n.source.tint)
            .padding(.horizontal, 10).padding(.vertical, 3.5)
            .background(Capsule().fill(n.source.tint.opacity(0.16)))
    }

    /// 它到底要干什么：工具名 + 那一行入参。
    /// 等宽字体是必要的——这里躺着的是要跑的命令和要写的路径，看错一个字符就按错了。
    ///
    /// 块本身整宽（左右各留 `inset`，对称），块内文字**居中**（大梁老师定）：
    /// 卡上其余内容全部居中，只有这一块贴着左边，看着像放歪了。
    /// 逐字符核对仍靠等宽字形本身，不靠行首对齐——代价是命令满到第二行时两行各自居中、
    /// 行首不再齐，所以这里维持 `lineLimit(2)` 与尾部截断，不让它长成一段左对齐的正文
    ///
    /// 高度写死两行：卡是从刘海里「长」出来的，那扇揭示窗的终态尺寸必须提前定下
    /// （见 `NotchGrownCard.grownHeight`）。让详情行数决定卡高，长命令就会被窗口裁掉半截
    private func detailBlock(_ request: AgentPermissionRequest) -> some View {
        VStack(spacing: 4) {
            Text(request.tool)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
            Text(request.detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: NotchGrownCardMetrics.innerRadius)
            .fill(Color.white.opacity(0.06)))
    }

    /// 卡高要提前算出来：卡是从刘海里「长」出来的，那扇揭示窗的终态尺寸必须先定
    /// （见 `NotchGrownCard.grownHeight`）。上游给两条以上建议时，它们各占一行整宽，
    /// 每多一条卡就高 38pt
    static func grownHeight(for request: AgentPermissionRequest) -> CGFloat {
        let stacked = request.options.count > 1 ? request.options.count : 0
        return 176 + CGFloat(stacked) * 38
    }

    /// 按钮区。上游给几条建议就有几个「不再询问」——它们粒度不同（只放这条命令 /
    /// 本轮会话自动接受所有编辑 / 允许访问某目录），在终端里本来也是各自独立的选项
    private func buttons(_ n: AgentWaitNotice, _ request: AgentPermissionRequest) -> some View {
        VStack(spacing: 6) {
            // 这一行**等宽铺满整宽**：一行里绝不留单侧空白（大梁老师定）。
            // 分量差全交给颜色——实底品牌色 / 浅底品牌色 / 红字 / 灰字，不再靠宽度差撑
            HStack(spacing: 8) {
                WaitActionButton(title: "允许一次", tone: .primary(n.source.tint)) {
                    wait.answer(.allowOnce)
                }
                // 只有一条建议（最常见）就并进这一行，卡不必长高；两条以上另起整宽行，
                // 横排挤三个长标题必然全被截断
                if request.options.count == 1, let option = request.options.first {
                    WaitActionButton(title: option.title, subtitle: option.detail,
                                     tone: .secondary(n.source.tint)) {
                        wait.answer(.allowAlways(0))
                    }
                }
                WaitActionButton(title: "拒绝", tone: .danger) {
                    wait.answer(.deny)
                }
                // 想在终端里慢慢看的退路：答一份「不作决策」，终端立刻照旧弹框，再跳过去
                WaitActionButton(title: "打开终端", tone: .quiet) {
                    wait.answer(.terminal)
                    jump(n)
                }
            }
            if request.options.count > 1 {
                ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                    WaitActionButton(title: option.title, subtitle: option.detail,
                                     tone: .secondary(n.source.tint), wide: true) {
                        wait.answer(.allowAlways(index))
                    }
                }
            }
        }
    }

    /// 跳到那个会话所在的终端 / IDE。
    ///
    /// 会话在监控台列表里就走 `activate`（顺带把该会话的「该你了」标记清掉，
    /// 语义一致：你已经去处理了）；不在列表里（刘海收起时监控台不扫描，新会话可能还没进表）
    /// 就直接按 hook 报来的宿主 bundle id 前置那个 App
    private func jump(_ n: AgentWaitNotice) {
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

/// 卡上的一个选项按钮。四个按钮的分量必须一眼分得出来——
/// 「拒绝」和「允许一次」长得一样的话，急着按的人一定会按错
private struct WaitActionButton: View {
    enum Tone {
        /// 主选项：品牌色实底
        case primary(Color)
        /// 次选项：品牌色描边
        case secondary(Color)
        /// 拒绝：红字
        case danger
        /// 退路：灰字
        case quiet
    }

    let title: String
    var subtitle: String?
    let tone: Tone
    /// 独占一行（多条建议摞起来时用）：标题与规则原文并排居中，长命令也读得完
    var wide = false
    let action: () -> Void

    @State private var hovering = false

    private static let dangerColor = Color(hex: "#FF453A")

    private var textColor: Color {
        switch tone {
        case .primary: return .white
        case .secondary(let c): return c
        case .danger: return Self.dangerColor
        case .quiet: return .white.opacity(0.6)
        }
    }

    private var fill: Color {
        switch tone {
        case .primary(let c): return c.opacity(hovering ? 1 : 0.85)
        case .secondary(let c): return c.opacity(hovering ? 0.28 : 0.16)
        case .danger: return .white.opacity(hovering ? 0.14 : 0.07)
        case .quiet: return .white.opacity(hovering ? 0.14 : 0.07)
        }
    }

    var body: some View {
        Button(action: action) {
            Group {
                if wide {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(textColor)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(textColor.opacity(0.65))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(height: 32)
                } else {
                    VStack(spacing: 1) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(textColor)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(textColor.opacity(0.65))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                // 让规则原文可被压缩：不降优先级，一条长规则会把同行
                                // 其它按钮挤窄，等宽就破了
                                .layoutPriority(-1)
                        }
                    }
                    .frame(height: 38)
                }
            }
            // padding 在内、撑满在外：反过来写会让按钮总宽等于「可用宽 + 22」，一行就溢出
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: NotchGrownCardMetrics.innerRadius).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: NotchGrownCardMetrics.innerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
