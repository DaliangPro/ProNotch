import SwiftUI

/// Claude Code 官方吉祥物 Clawd 的像素原件。
///
/// **不是照着重画的**：数据取自 Claude Code 二进制里的精灵表（变量 `ZLp`），
/// 原文是 Unicode 四分块字符（U+2588/258C/2590/2596-259F），三行文本、
/// 一个字符 = 2×2 子像素，展开后就是下面这张 18 列 × 5 行的网格。
/// 官方另有 `look-left` / `look-right` 两个张望姿态，本文件没收——
/// 空闲态是静止的（见 `ClawdSlotView` 关于「不挂空转定时器」的说明），收了也没处用。
///
/// 配色同样取自二进制常量 `clawd_body: rgb(215,119,87)`，
/// 与 `AgentKind.claude.tint`（`#D97757`）差 1，此处以官方值为准。
enum ClawdSprite {
    static let cols = 18
    /// 6 行 = 5 行本体 + 顶上留一行给弹跳。留白写进网格而不是靠 offset，
    /// 是为了让举手帧与站立帧占同一个 frame，切换时不会把旁边的指示灯挤动
    static let rows = 6

    static let bodyColor = Color(red: 215 / 255, green: 119 / 255, blue: 87 / 255)

    /// 站立（官方 `default` 姿态）。第 2 行那两个缺口是眼睛
    static let standing = [
        "...############...",
        "...##.######.##...",
        ".################.",
        "...############...",
        "....#.#....#.#....",
    ]

    /// 举手（官方 `arms-up` 姿态）：两侧触手抬起来
    static let armsUp = [
        "...############...",
        ".####.######.####.",
        "..##############..",
        "...############...",
        "....#.#....#.#....",
    ]
}

/// 把像素网格铺成矢量路径。`lift` 为 1 时整体上抬一格，做弹跳的那一下。
///
/// 格子**不是正方形**：原件在终端里一个字符占「宽 1 高 2」，拆成 2×2 子像素后
/// 每个子像素就是 1:2 的竖条。按正方形铺会把 Clawd 压成一条扁片（实测过），
/// 所以横竖各自按 frame 均分，比例交给调用方给的 frame 定。
private struct ClawdShape: Shape {
    let grid: [String]
    let lift: Int

    func path(in rect: CGRect) -> Path {
        let cellW = rect.width / CGFloat(ClawdSprite.cols)
        let cellH = rect.height / CGFloat(ClawdSprite.rows)
        var path = Path()
        for (y, row) in grid.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                path.addRect(CGRect(x: CGFloat(x) * cellW,
                                    y: CGFloat(y + 1 - lift) * cellH,
                                    width: cellW, height: cellH))
            }
        }
        return path
    }
}

/// 收起态槽位里的 Claude Code 工作状态：Clawd + 指示灯。
///
/// 空闲 = 绿灯 + 站着不动；工作中 = 黄灯 + 站立/举手交替并弹跳一下。
///
/// 空闲态刻意**不做**「偶尔左右张望」：那需要一个全天候跑的亚秒级定时器，
/// 而这个槽位一天里绝大多数时间都是空闲的——为一个眼神挂个常驻心跳，
/// 正是之前「两侧全关仍在空转」那类问题的来源。工作中才有动画，动画才有定时器。
struct ClawdSlotView: View {
    let working: Bool

    /// 每帧 0.38 秒：再快像抽搐，再慢就不像在使劲干活了
    private static let frameInterval: TimeInterval = 0.38
    /// 36×24 = 每格 2×4pt，即原件在终端里的真实比例（子像素 1:2）。
    /// 加上 4pt 间距与 6pt 指示灯共 46pt，卡在右槽 50pt 可用宽度内
    private static let spriteWidth: CGFloat = 36
    private static let spriteHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 4) {
            if working {
                // TimelineView 只在这一支里存在：熄灯即整支下树，定时器随之消失
                TimelineView(.periodic(from: .now, by: Self.frameInterval)) { ctx in
                    let step = Int(ctx.date.timeIntervalSinceReferenceDate / Self.frameInterval)
                    sprite(step.isMultiple(of: 2) ? ClawdSprite.standing : ClawdSprite.armsUp,
                           lift: step.isMultiple(of: 2) ? 0 : 1)
                }
            } else {
                sprite(ClawdSprite.standing, lift: 0)
            }
            Circle()
                .fill(working ? Color(hex: "#FFCC00") : Color(hex: "#34C759"))
                .frame(width: 6, height: 6)
        }
        .accessibilityLabel(working ? "Claude Code 工作中" : "Claude Code 空闲")
    }

    private func sprite(_ grid: [String], lift: Int) -> some View {
        ClawdShape(grid: grid, lift: lift)
            .fill(ClawdSprite.bodyColor)
            .frame(width: Self.spriteWidth, height: Self.spriteHeight)
    }
}
