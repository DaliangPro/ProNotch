import SwiftUI

/// 收起态 Agent 槽位的统一度量。
///
/// Clawd 与 Codex 两只并排在刘海右侧，必须同高同宽——大梁老师定：图标该规整统一、
/// 刘海宽度恒定，绝不能让某只偏胖的图标去撑宽刘海。四态形象是大梁老师重绘的贴身横向
/// PNG，各按 `aspectRatio(.fit)` 居中塞进同一个固定框：框宽恒定 → 两家等宽、刘海不随选谁变；
/// 框高 = 内存环高（21pt）→ 精灵填满高度、与内存环一样大（大梁老师实测诉求）。
enum AgentSlotMetrics {
    /// 所有 Agent、所有状态统一的显示高度，取内存环直径 21pt——两侧图标一样大。
    /// 精灵贴身横向、比例 ≤ 1.55，fit 进来会顶到 21pt 高，视觉上就和左侧内存环等大。
    /// 21pt 远在收起态刘海 38pt 高度内
    static let spriteHeight: CGFloat = 21
    /// 统一显示宽度。取 32pt：既容得下最横那只（1.55 → 需 ≈32.6，略以宽定高、仅差 0.4pt 不可见），
    /// 又让「内容总宽 + 内边距 + 让灯圆角」正好压在固定侧宽 56pt 内。两家共用此框 → 收起态刘海宽度恒定
    static let spriteWidth: CGFloat = 32
    /// 指示灯直径
    static let dotSize: CGFloat = 6
    /// 精灵与指示灯的间距
    static let spacing: CGFloat = 4
    /// 「精灵框 + 间距 + 指示灯」内容总宽——两家 Agent 完全一致，是刘海固定侧宽的依据
    static let contentWidth = spriteWidth + spacing + dotSize
}

/// 收起态 Agent 精灵槽位：直接显示大梁老师重绘的四态 PNG（空闲/工作 × 两家），
/// 而不是手绘字符网格——立体笔记本、终端符、阴影都由原图保真。
///
/// 图是贴身横向 PNG，按 `aspectRatio(.fit)` 居中塞进统一固定框（顶到 21pt 高、与内存环等大）；工作态整只上下轻跳（打字律动）。
/// 动画只在工作态存在（`TimelineView` 只在那一支里），空闲不留常驻定时器——
/// 这个槽位一天里绝大多数时间空闲，为它挂亚秒级心跳正是「两侧全关仍空转」那类问题的来源。
struct AgentSpriteSlotView: View {
    /// 空闲态图片名（bundle 内，无扩展名，走 `NSImage(named:)`）
    let idleImage: String
    /// 工作态图片名
    let workingImage: String
    let working: Bool
    let label: String

    /// 每帧 0.42 秒，两家同一套点头节奏，看着像同一个世界里的
    private static let frameInterval: TimeInterval = 0.42

    var body: some View {
        HStack(spacing: AgentSlotMetrics.spacing) {
            ZStack {
                if working {
                    // TimelineView 只在这一支里存在：熄灯即整支下树，定时器随之消失
                    TimelineView(.periodic(from: .now, by: Self.frameInterval)) { ctx in
                        let tick = Int(ctx.date.timeIntervalSinceReferenceDate / Self.frameInterval)
                        // 取模前先取绝对值：参考日期之前 tick 为负。交替 0/-2 即原地一跳
                        sprite(workingImage)
                            .offset(y: abs(tick).isMultiple(of: 2) ? 0 : -2)
                    }
                } else {
                    sprite(idleImage)
                }
            }
            // 贴身横向图 fit 进这个固定框：两家两态顶到同一 21pt 高、居中，切状态指示灯不横跳、选谁刘海不变宽
            .frame(width: AgentSlotMetrics.spriteWidth, height: AgentSlotMetrics.spriteHeight)
            Circle()
                .fill(working ? Color(hex: "#FFCC00") : Color(hex: "#34C759"))
                .frame(width: AgentSlotMetrics.dotSize, height: AgentSlotMetrics.dotSize)
        }
        .accessibilityLabel(label)
    }

    /// 精灵按自身比例 fit 进统一框，居中不变形。图缺失时静默显示空白（不崩）
    private func sprite(_ name: String) -> some View {
        Image(nsImage: NSImage(named: name) ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
