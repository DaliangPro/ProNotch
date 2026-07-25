import SwiftUI

/// 收起态槽位里的 Claude Code：Clawd 精灵 + 指示灯。
///
/// 空闲 = 绿灯 + 站姿；工作中 = 黄灯 + 抱笔记本上下轻跳（打字律动）。四态形象是大梁老师
/// 重绘、逐张打进 bundle 的 512×512 PNG（见 `Resources/claude-code-idle|working.png`），
/// 与 Codex 同一套模板、等大等高。渲染与动画都在 `AgentSpriteSlotView` 里，两家共用。
struct ClawdSlotView: View {
    let working: Bool

    /// 「精灵框 + 间距 + 指示灯」内容总宽：与 Codex 完全一致（都取统一度量），刘海宽度不随选谁变
    static let contentWidth = AgentSlotMetrics.contentWidth

    var body: some View {
        AgentSpriteSlotView(
            idleImage: "claude-code-idle",
            workingImage: "claude-code-working",
            working: working,
            label: working ? "Claude Code 工作中" : "Claude Code 空闲")
    }
}
