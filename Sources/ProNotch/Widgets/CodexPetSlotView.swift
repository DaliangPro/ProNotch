import SwiftUI

/// Codex 官方吉祥物「终端云」的像素原件（大梁老师提供的 ChatGPT 出图，1254² 放大像素画）。
///
/// **换掉了此前从 CDN 图集降采样的那版**：旧版是官方 terminal pet（抱笔记本的小机器人），
/// 带多层明暗渐变，放进 26pt 槽位后和隔壁 Clawd 的实心块完全不是一个精细度，
/// 并排像成品挨着草稿。这版是一朵蓝云顶着黑色终端屏、屏上一个蓝色 `>_` 提示符，
/// **只有蓝、黑两色，扁平无渐变**——和 Clawd 的两色实心块正好同一路画风，
/// 「不是一个画风」的问题到此收口。
///
/// 取法：源图背景是烘焙进 RGB 的灰白棋盘（非真透明通道），按面积多数投票降到 26 列。
/// 屏上的 `>_` 其实和云身同一个蓝，靠黑屏衬出来，因此不必单开色位。
enum CodexPetSprite {
    /// 26 列 × 26 行 = 25 行本体 + 顶上留一行给弹跳（与 Clawd 同构：留白写进网格，
    /// 弹跳时整只上抬一格而画布不变，旁边指示灯不会被挤动）
    static let cols = 26
    static let rows = 26

    /// 云身与提示符同色 `#5090F0`；终端屏 `#101010`。取自源图量化后的两个主色
    static let bodyColor = Color(red: 0x50 / 255, green: 0x90 / 255, blue: 0xF0 / 255)
    static let screenColor = Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255)

    /// 本体 25 行（`b` 云身/提示符、`k` 终端屏、`.` 透明）
    static let character = [
        ".........bbbbbb...........",
        "........bbbbbbbb.bbb......",
        ".......bbbbbbbbbbbbbb.....",
        "......bbbbbbbbbbbbbbbb....",
        "......bbbbbbbbbbbbbbbb....",
        "...bbbbbbbbbbbbbbbbbbbb...",
        "..bbbbbbbbbbbbbbbbbbbbbb..",
        ".bbbbbbbbbbbbbbbbbbbbbbbb.",
        ".bbbbbbbkkkkkkkkkkkkbbbbbb",
        "bbbbbbbkkkkkkkkkkkkkkbbbbb",
        "bbbbbbbkkkkkkkkkkkkkkbbbbb",
        "bbbbbbbkkkbkkkkkkkkkkbbbbb",
        "bbbbbbbkkkkbkkkkkkkkkbbbbb",
        "bbbbbbbkkkkbkkkkkkkkkbbbbb",
        "bbbbbbbkkkbkkkkkkkkkkbbbb.",
        "..bbbbbkkkkkkkkbbbbkkbbbb.",
        "..bbbbbkkkkkkkkkkkkkkbbbb.",
        "..bbbbbbkkkkkkkkkkkkbbbbb.",
        "..bbbbbbbbbbbbbbbbbbbbbb..",
        "...bbbbbbbbbbbbbbbbbbbb...",
        "..bbbbbbbbbbbbbbbbbbbbbbb.",
        "..bbbb.bbbbbbbbbbbb..bbbb.",
        "..bbb..bbbb....bbbb...bbb.",
        "...b...bbbb....bbbb....b..",
        "........bbb....bbb........",
    ]

    private static let blankRow = String(repeating: ".", count: cols)
    /// 落地态：留白在顶，云沉在底。空闲与弹跳的低点都用它
    static let resting = [blankRow] + character
    /// 弹起态：留白挪到底，整只上抬一格。工作态与 `resting` 交替就是原地一跳
    static let hopping = character + [blankRow]
}

/// 把两色网格画出来：按色归并成两条 path 再落笔（一帧近 500 格，逐格 fill 是 500 次绘制，
/// 归并后只剩两次）。`drawingGroup()` 再合成一层位图，弹跳重绘时不必逐帧重走 Canvas。
private struct CodexPetCanvas: View {
    let grid: [String]

    var body: some View {
        Canvas { ctx, size in
            let cellW = size.width / CGFloat(CodexPetSprite.cols)
            let cellH = size.height / CGFloat(CodexPetSprite.rows)
            var body = Path()
            var screen = Path()
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    let rect = CGRect(x: CGFloat(x) * cellW, y: CGFloat(y) * cellH,
                                      width: cellW, height: cellH)
                    if ch == "k" { screen.addRect(rect) } else { body.addRect(rect) }
                }
            }
            // 先铺云身再压黑屏：屏是嵌在云里的，顺序反了会被云身盖住
            ctx.fill(body, with: .color(CodexPetSprite.bodyColor))
            ctx.fill(screen, with: .color(CodexPetSprite.screenColor))
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
    /// 24pt 宽。原件近正方（含留白 26×26），高度随之 24pt——比 Clawd（约 20pt）高 4pt，
    /// 在 `test与Clawd槽位同高` 允许的 8pt 内；再大就顶破 38pt 刘海高度
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
