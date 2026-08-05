import SwiftUI

/// 收起态功能区可选内容（大梁老师定的自由功能区，新组件在此扩展）
enum NotchSlot: String, CaseIterable {
    case none, memory, weather, clock, agentClaude, agentCodex

    var title: String {
        switch self {
        case .none: return "关闭"
        case .memory: return "内存占用"
        case .weather: return "实时天气"
        case .clock: return "时间"
        case .agentClaude: return "Claude Code"
        case .agentCodex: return "Codex"
        }
    }

    /// 该槽位依赖哪一家 Agent 被勾选。与 Agent 无关的槽位返回 nil
    var requiredAgent: AgentKind? {
        switch self {
        case .agentClaude: return .claude
        case .agentCodex: return .codex
        default: return nil
        }
    }

    /// 菜单里能选什么，取决于用户勾了哪几家（大梁老师定的口径：
    /// 扫描发现什么、设置里才出现什么）——没接入的家不该出现在选项里
    static func available(agents: Set<AgentKind>) -> [NotchSlot] {
        allCases.filter { slot in
            slot.requiredAgent.map(agents.contains) ?? true
        }
    }

    /// 收起态黑 pill 的圆角把**直壁**从名义边缘往里收这么多（= `RevealNotchShape` 收起态 `topRadius`）。
    ///
    /// 关键坑：右槽内容靠左对齐、指示灯贴在最外侧，而黑 pill 的竖直壁在 `maxX - topRadius` 处，
    /// 不在名义边缘。侧宽若不把这一截让开，灯会被直壁裁掉一半——就是大梁老师报的「小黄点出去了」。
    static let cornerInset: CGFloat = 6
    /// 精灵贴向摄像头一侧的内边距（`slotsBody` 右槽 `.padding(.leading:)` 用同一值，避免两处漂移）
    static let leadingPad: CGFloat = 4
    /// 指示灯到直壁之间的可见留白：在 `cornerInset` 之外再留这么多，灯才明显「落在黑条里」而不贴边
    static let dotEdgeGap: CGFloat = 4

    /// 收起态黑 pill 的**单侧固定宽度——恒定不变，不随选了哪个槽位、哪家 Agent 而变**（大梁老师定：
    /// 图标该规整统一、刘海宽度恒定，绝不能让某个偏胖的图标去撑宽刘海）。
    /// 取值 = 最宽内容（天气 100%/-12° 极值）所需宽；其余窄内容在这个固定框内靠摄像头侧留白，
    /// 外侧自然让开圆角直壁与可见留白，指示灯稳稳落在黑条里。左右两侧同取此值，pill 恒对称。
    static let fixedSideWidth: CGFloat = 56

    /// 时钟内容宽。13pt 等宽数字下「08:02」实测 37.3pt，取 40 留余量
    static let clockWidth: CGFloat = 40

    /// 该槽位内容**自身**所需宽度（内容 + 摄像头侧内边距 + 让开圆角直壁 `cornerInset` + 可见留白 `dotEdgeGap`）。
    /// 不参与布局——布局一律用 `fixedSideWidth`；仅供自检：必须 ≤ `fixedSideWidth`，
    /// 否则内容会顶出直壁被裁（尤其右槽最外侧的指示灯）。
    var neededWidth: CGFloat {
        let trailingAir = Self.cornerInset + Self.dotEdgeGap   // 让开圆角直壁 + 可见留白
        switch self {
        case .none: return 0
        // 内存环外径 21：描边收在框内，不再向外多探（见 `CollapsedSlotsView.memorySlot`）
        case .memory: return 21 + Self.leadingPad + trailingAir
        case .weather: return Self.fixedSideWidth                     // 最宽内容，正好等于固定框
        // 13pt 等宽数字下「08:02」实测 37.3pt（NSFont 量的，别凭字符数估——
        // 我按 5×7 估了 36，差 1.3pt 就把时间折成了两行，离屏渲染当场看见）。
        // 取 40 留出余量，仍在固定框可用宽 42 之内
        case .clock: return Self.clockWidth + Self.leadingPad + trailingAir
        case .agentClaude: return ClawdSlotView.contentWidth + Self.leadingPad + trailingAir
        case .agentCodex: return CodexPetSlotView.contentWidth + Self.leadingPad + trailingAir
        }
    }
}

/// 量出内容的真实宽度回写给外面（`background` 里的 GeometryReader 不参与布局，
/// 不会反过来撑大内容）。回写放在 onAppear/onChange 里而不是 body 中：
/// 布局途中改 @State 会触发 SwiftUI 的告警
private struct SlotWidthReader: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width = new }
            })
    }
}

/// 收起态刘海两侧功能区：左右各一个可配置 slot（默认左内存右天气，
/// 设置页可换/可关）。展开时由容器整体淡出
struct CollapsedSlotsView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var weather: WeatherStore
    @EnvironmentObject var agentActivity: AgentActivityStore
    /// 收起态低频心跳：10 秒刷内存（微秒级 syscall）；天气走 store 内置 15 分钟节流
    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    /// 时钟当前时刻。由既有的 10 秒心跳推进——分钟级显示，10 秒粒度绰绰有余，
    /// 不为它单开一个每秒定时器（收起态要安静）
    @State private var now = Date()
    /// 两侧内容的真实宽度（见 `outwardGap`）
    @State private var leftContentWidth: CGFloat = 0
    @State private var rightContentWidth: CGFloat = 0

    var body: some View {
        // 两侧都关时整个视图不上树：10 秒心跳的订阅一并拆除，不再空转（真停机）
        if settings.sideSlotsActive {
            slotsBody
        }
    }

    /// 两个 slot 分居的跨度。
    ///
    /// 收起态 = 黑条宽（中间那段正好等于物理刘海，摄像头区不放东西）；
    /// 有大卡张开时 = 卡宽减去卡的四边留白，两侧图标随卡一起向外走、停在卡内容的左右边线上
    /// （大梁老师定：「随着刘海的拓展而移动到弹出的两边，而不是保持原来位置不变」）。
    ///
    /// 只改这一个宽度、让中间的 Spacer 吃掉增量：全程是可插值的数值动画，
    /// 与卡的揭示动画同一条事务。改 alignment 或换 padding 那种写法 SwiftUI 不插值，
    /// 图标会「跳」一下而不是走过去
    private var slotsSpan: CGFloat {
        guard vm.grownCardWidth > 0 else { return vm.collapsedShapeWidth }
        return max(vm.collapsedShapeWidth,
                   vm.grownCardWidth - NotchGrownCardMetrics.horizontalInset * 2)
    }

    /// 固定框（56pt）里内容与外侧之间的那段空隙。大卡张开时把它让出去，
    /// 图标才真正贴在卡内容的边线上、与下方整宽按钮行左右对齐；收起态一律 0，维持原样。
    ///
    /// 宽度是量出来的而不是查表算的：气温位数（`-12°`/`8°`）和精灵图各不相同，
    /// 写死常量会让两侧一边贴齐、另一边差着几 pt——大梁老师一眼就能看出不对称。
    /// 让位靠 padding 而不是切换 alignment：padding 是可插值的，切 alignment 会让图标瞬跳
    private func outwardGap(_ contentWidth: CGFloat) -> CGFloat {
        guard vm.grownCardWidth > 0, contentWidth > 0 else { return 0 }
        return max(0, vm.sideSlotWidth - contentWidth)
    }

    private var slotsBody: some View {
        HStack(spacing: 0) {
            slotContent(settings.leftSlot)
                .modifier(SlotWidthReader(width: $leftContentWidth))
                // 让出右侧空隙 = 把内容顶到框的左边（框内居中，加满这段就正好贴左）
                .padding(.trailing, outwardGap(leftContentWidth))
                .frame(width: vm.sideSlotWidth)
                .frame(maxHeight: .infinity)
            Spacer(minLength: 0)   // 收起态这段正好是物理刘海（摄像头）区；卡张开时它被拉长
            slotContent(settings.rightSlot)
                .modifier(SlotWidthReader(width: $rightContentWidth))
                // 收起态贴向刘海（大梁老师定）；大卡张开时改为让出左侧空隙、贴到卡的右边线
                .padding(.leading, vm.grownCardWidth > 0
                         ? outwardGap(rightContentWidth) : NotchSlot.leadingPad)
                .frame(width: vm.sideSlotWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
        }
        .frame(width: slotsSpan, height: vm.notchRect.height)
        .onAppear {
            now = Date()
            refreshActive()
        }
        .onReceive(ticker) { _ in
            guard !vm.isExpanded else { return }
            // 时钟每拍都推：展开时不推也没事，收起那一刻 onAppear 会补齐
            now = Date()
            refreshActive()
        }
    }

    /// 只刷新被启用的数据源（天气关掉就不触发定位/联网）
    private func refreshActive() {
        let slots = [settings.leftSlot, settings.rightSlot]
        if slots.contains(.memory) { memory.refresh() }
        if slots.contains(.weather) { weather.refresh() }
    }

    @ViewBuilder
    private func slotContent(_ slot: NotchSlot) -> some View {
        switch slot {
        case .none: Color.clear
        case .memory: memorySlot
        case .weather: weatherSlot
        case .clock: clockSlot
        // 展开时整块淡出，此时再跑动画是白烧 CPU——动画只在收起且真在工作时才有
        case .agentClaude:
            ClawdSlotView(working: agentActivity.working.contains(.claude) && !vm.isExpanded)
        case .agentCodex:
            CodexPetSlotView(working: agentActivity.working.contains(.codex) && !vm.isExpanded)
        }
    }

    /// 环的描边宽度。描边压在环形路径上、向内外各探半个线宽，
    /// 所以圆必须先往里收 `ringWidth / 2`，环的**外沿**才严格落在 21pt 框边上
    private static let ringWidth: CGFloat = 2.5

    /// 内存圆环（大梁老师定）：环色随压力变、数字嵌环心，
    /// 比图标+文字横排省一半宽度；% 由环形本身表意，环心只放数字。
    ///
    /// 环收在 21pt 框**以内**（大梁老师定）：此前用 `stroke` 时描边向外多探 1.25pt，
    /// 大卡张开时左侧外沿量到 12.0pt 而右侧 14.5pt——两侧的框本是严格对齐的，
    /// 差的就是这圈描边。收进来后外沿正好压在 14pt 内容线上，代价是环小 2.5pt
    private var memorySlot: some View {
        ZStack {
            // strokeBorder 把描边画在圆的内侧，外沿即框边
            Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: Self.ringWidth)
            if let s = memory.snapshot {
                // 进度弧要 trim，而 trim 之后就不再是 InsettableShape 了，
                // 所以先 inset 半个线宽再 trim，才与上面那圈同心同径
                Circle().inset(by: Self.ringWidth / 2)
                    .trim(from: 0, to: min(1, s.usedPercent / 100))
                    .stroke(s.loadColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))   // 从 12 点方向顺时针走
                Text("\(Int(s.usedPercent.rounded()))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .minimumScaleFactor(0.7)   // 100 三位数时縮进环心
            } else {
                Text("--")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(width: 21, height: 21)
    }

    /// 侧栏时钟（大梁老师 2026-08-04）：只显 `HH:mm`，时区在设置里选。
    ///
    /// 不显时区缩写是他拍板的——单侧仅 56pt，加缩写就得压字号。
    /// 等宽数字（`.monospacedDigit`）：不加的话分钟从 1 跳到 11 整串会左右抖
    private var clockSlot: some View {
        Text(ClockFormatter.text(for: now, zone: settings.clockZone.timeZone))
            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundColor(.white.opacity(0.92))
            .frame(width: NotchSlot.clockWidth)
    }

    /// 天气图标 + 当前气温；未定位/未授权时安静显示占位。
    /// 有恶劣天气预警时联动换脸（大梁老师定）：图标换成来袭的恶劣天气、气温描橙——
    /// 大卡缩回后刘海仍持续报警，直到事件出窗随扫描自动还原
    private var weatherSlot: some View {
        HStack(spacing: 4) {
            if let s = weather.upcomingSevere {
                Image(systemName: s.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 11))
                Text(weather.now.map { "\(Int($0.temperature.rounded()))°" } ?? "--")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(hex: "#FF9F0A"))
            } else if let w = weather.now {
                Image(systemName: w.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 11))
                Text("\(Int(w.temperature.rounded()))°")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            } else {
                Image(systemName: "cloud")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                Text("--")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}
