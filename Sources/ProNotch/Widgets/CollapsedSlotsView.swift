import SwiftUI

/// 收起态功能区可选内容（大梁老师定的自由功能区，新组件在此扩展）
enum NotchSlot: String, CaseIterable {
    case none, memory, weather, agentClaude

    var title: String {
        switch self {
        case .none: return "关闭"
        case .memory: return "内存占用"
        case .weather: return "实时天气"
        case .agentClaude: return "Claude Code"
        }
    }

    /// 该槽位依赖哪一家 Agent 被勾选。与 Agent 无关的槽位返回 nil
    var requiredAgent: AgentKind? {
        self == .agentClaude ? .claude : nil
    }

    /// 菜单里能选什么，取决于用户勾了哪几家（大梁老师定的口径：
    /// 扫描发现什么、设置里才出现什么）——没接入的家不该出现在选项里
    static func available(agents: Set<AgentKind>) -> [NotchSlot] {
        allCases.filter { slot in
            slot.requiredAgent.map(agents.contains) ?? true
        }
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

    var body: some View {
        // 两侧都关时整个视图不上树：10 秒心跳的订阅一并拆除，不再空转（真停机）
        if settings.sideSlotsActive {
            slotsBody
        }
    }

    private var slotsBody: some View {
        HStack(spacing: 0) {
            slotContent(settings.leftSlot)
                .frame(width: vm.sideSlotWidth)
                .frame(maxHeight: .infinity)
            Color.clear.frame(width: vm.notchRect.width)   // 物理刘海（摄像头）区
            slotContent(settings.rightSlot)
                .padding(.leading, 6)   // 整体贴向刘海（大梁老师定）：外侧让出余量，不显局促
                .frame(width: vm.sideSlotWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
        }
        .frame(height: vm.notchRect.height)
        .onAppear { refreshActive() }
        .onReceive(ticker) { _ in
            guard !vm.isExpanded else { return }
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
        // 展开时整块淡出，此时再跑动画是白烧 CPU——动画只在收起且真在工作时才有
        case .agentClaude:
            ClawdSlotView(working: agentActivity.working.contains(.claude) && !vm.isExpanded)
        }
    }

    /// 内存圆环（大梁老师定）：环色随压力变、数字嵌环心，
    /// 比图标+文字横排省一半宽度；% 由环形本身表意，环心只放数字
    private var memorySlot: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
            if let s = memory.snapshot {
                Circle().trim(from: 0, to: min(1, s.usedPercent / 100))
                    .stroke(s.loadColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
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
