import SwiftUI

/// Codex 官方吉祥物「终端云」的像素原件（大梁老师提供的第二张 ChatGPT 出图，1254² 像素画）。
///
/// **换掉了此前那张有机曲线出图**：上一张云身是抗锯齿曲线，降采样到任何列数边缘都带一圈
/// 碎块锯齿角（大梁老师反馈「碎块角太多」），只能手工重画剪影凑合。这张是**真正网格对齐的
/// 像素画**——每条边都是规整整块台阶、真·像素风，可无损提取原生网格，天生没有碎块角。
///
/// 三色（比上一张多一色）：身体蓝 `#5580F4`、终端屏黑 `#101010`、提示符浅蓝 `#95CDFD`。
/// 上一张的 `>_` 与云身同色、只能靠黑屏衬出；这张的 `>_` 是**独立浅蓝**，脸更清楚。
/// 造型也更全：圆角三层顶 + 大黑屏 + 屏内 `>` 箭头与右下 `_` 光标 + 底部 5 条触须腿。
/// 仍只有平涂色块、无渐变，和 Clawd 的两色实心块同一路画风。
///
/// 网格照原图比例定为 22 列——原图是干净像素画，这个列数能规整还原 5 条腿与 `>_` 而不糊。
enum CodexPetSprite {
    /// 22 列 × 18 行 = 17 行本体 + 顶上留一行给弹跳（与 Clawd 同构：留白写进网格，
    /// 弹跳时整只上抬一格而画布不变，旁边指示灯不会被挤动）
    static let cols = 22
    static let rows = 18

    /// 三个平涂色，取自原图量化后的中位色
    static let bodyColor = Color(red: 0x55 / 255, green: 0x80 / 255, blue: 0xF4 / 255)
    static let screenColor = Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255)
    /// 提示符 `>_` 的浅蓝，比身体蓝更亮，把脸从黑屏里衬出来
    static let promptColor = Color(red: 0x95 / 255, green: 0xCD / 255, blue: 0xFD / 255)

    /// 本体 17 行（`b` 身体、`k` 终端屏、`c` 提示符浅蓝、`.` 透明）。
    /// 第 6–8 行屏内的 `c` 是 `>` 箭头，第 9 行右侧的 `cccc` 是 `_` 光标，末 3 行是 5 条腿
    static let character = [
        ".......bbbbbbbb.......",
        ".......bbbbbbbb.......",
        ".....bbbbbbbbbbbb.....",
        "...bbbbbbbbbbbbbbbb...",
        "..bbbbbbbbbbbbbbbbbb..",
        "..bbkkkkkkkkkkkkkkbb..",
        "..bbkkcckkkkkkkkkkbb..",
        "..bbkkkkcckkkkkkkkbb..",
        "..bbkkcckkkkkkkkkkbb..",
        "..bbkkkkkkkkkcccckbb..",
        "..bbkkkkkkkkkkkkkkbb..",
        "..bbbbbbbbbbbbbbbbbb..",
        "...bbbbbbbbbbbbbbbb...",
        "...bbbbbbbbbbbbbbbb...",
        "....bb.bb.bb.bb.bb....",
        "....bb.bb.bb.bb.bb....",
        "....bb.bb.bb.bb.bb....",
    ]

    private static let blankRow = String(repeating: ".", count: cols)
    /// 落地态：留白在顶，云沉在底。空闲与弹跳的低点都用它
    static let resting = [blankRow] + character
    /// 弹起态：留白挪到底，整只上抬一格。工作态与 `resting` 交替就是原地一跳
    static let hopping = character + [blankRow]
}

/// 把三色网格画出来：按色归并成三条 path 再落笔（逐格 fill 是每格一次绘制，
/// 归并后只剩三次）。`drawingGroup()` 再合成一层位图，弹跳重绘时不必逐帧重走 Canvas。
private struct CodexPetCanvas: View {
    let grid: [String]

    var body: some View {
        Canvas { ctx, size in
            let cellW = size.width / CGFloat(CodexPetSprite.cols)
            let cellH = size.height / CGFloat(CodexPetSprite.rows)
            var body = Path()
            var screen = Path()
            var prompt = Path()
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    let rect = CGRect(x: CGFloat(x) * cellW, y: CGFloat(y) * cellH,
                                      width: cellW, height: cellH)
                    switch ch {
                    case "k": screen.addRect(rect)
                    case "c": prompt.addRect(rect)
                    default: body.addRect(rect)
                    }
                }
            }
            // 从底到面：身体 → 嵌在身体里的黑屏 → 压在黑屏上的提示符，顺序反了会被下层盖住
            ctx.fill(body, with: .color(CodexPetSprite.bodyColor))
            ctx.fill(screen, with: .color(CodexPetSprite.screenColor))
            ctx.fill(prompt, with: .color(CodexPetSprite.promptColor))
        }
        .drawingGroup()
    }
}

/// 收起态槽位里的 Codex 工作状态：终端云 + 指示灯。
///
/// 空闲 = 绿灯 + 静止落地；工作中 = 黄灯 + 原地弹跳（落地/弹起两态交替）。
/// 只有一个姿态，故动画靠弹跳而非换帧。和 `ClawdSlotView` 同一套规矩：
/// 动画只在工作态存在，空闲不留常驻定时器。
struct CodexPetSlotView: View {
    let working: Bool

    /// 每帧 0.3 秒 → 一次完整弹跳 0.6 秒，和 Clawd 走一步的节奏对齐，看着像同一个世界里的
    private static let frameInterval: TimeInterval = 0.3
    /// 24pt 宽。网格 22×18（含顶部弹跳留白），每格约 1.1pt，高度随之约 19.6pt——
    /// 与 Clawd（约 19.7pt）几乎同高，并排最齐；远在 38pt 刘海高度内
    private static let spriteWidth: CGFloat = 24
    private static let spriteHeight: CGFloat = 24.0 / CGFloat(CodexPetSprite.cols) * CGFloat(CodexPetSprite.rows)

    var body: some View {
        HStack(spacing: 4) {
            if working {
                // TimelineView 只在这一支里存在：熄灯即整支下树，定时器随之消失
                TimelineView(.periodic(from: .now, by: Self.frameInterval)) { ctx in
                    let tick = Int(ctx.date.timeIntervalSinceReferenceDate / Self.frameInterval)
                    sprite(abs(tick).isMultiple(of: 2) ? CodexPetSprite.resting : CodexPetSprite.hopping)
                }
            } else {
                sprite(CodexPetSprite.resting)
            }
            Circle()
                .fill(working ? Color(hex: "#FFCC00") : Color(hex: "#34C759"))
                .frame(width: 6, height: 6)
        }
        .accessibilityLabel(working ? "Codex 工作中" : "Codex 空闲")
    }

    private func sprite(_ grid: [String]) -> some View {
        CodexPetCanvas(grid: grid)
            .frame(width: Self.spriteWidth, height: Self.spriteHeight)
    }
}
