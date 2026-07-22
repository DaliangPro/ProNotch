import SwiftUI

/// Codex 官方吉祥物（terminal pet「codex」）的像素原件，降采样版。
///
/// **不是照着重画的**：素材取自官方 CDN 的精灵图
/// `persistent.oaistatic.com/codex/pets/v1/codex-spritesheet-v4.webp`，
/// 原件是 8 列 × 9 行的图集、单元格 192×208，行即状态（第 0 行 idle、第 7 行 running）。
///
/// 原件那身细腻的多层上色放进 26pt 高的槽位后，和隔壁 Clawd 的实心块完全不是一个精细度，
/// 并排像成品挨着草稿（大梁老师拍板的口径：降到 20 列，跟 Clawd 的颗粒感拉齐）。
/// 所以这里把 192×208 面积平均降到 20×22，再用 k-means 把颜色聚成 8 色。
///
/// 屏幕上那个 `>_` 是这只的辨识点，但它太细，降采样后只剩 `#6598B7` 一抹灰蓝。
/// 因此青色单独占第 9 个色位、由色相判据直接归位，不参与聚类——
/// 这是全篇唯一一处对原件的改动，为的是这个尺寸下还认得出脸。
enum CodexPetSprite {
    static let cols = 20
    static let rows = 22

    /// a…h 由 k-means 从官方原件聚出，i 是屏幕上 `>_` 的青
    static let palette: [Color] = [
        Color(hex: "#181F4E"), Color(hex: "#202863"), Color(hex: "#232E6F"),
        Color(hex: "#2A3B7B"), Color(hex: "#203084"), Color(hex: "#364B8B"),
        Color(hex: "#283DA1"), Color(hex: "#2C44BE"), Color(hex: "#8FE3EE"),
    ]

    /// 空闲：官方第 0 行 idle 首帧，站姿
    static let idle = [
        "....................",
        "....................",
        "....................",
        "........dd..........",
        ".......hhhgggd......",
        "......ghhhhhhhd.....",
        ".....dhhhhhhhhg.....",
        "....hhhhhhhhhhhg....",
        "...ehhgcabaabbfhf...",
        "...fhhdadaaaaabhg...",
        "...eghdaidaaaabhf...",
        "...bghdaidadidahe...",
        "....ggeacaabbabhd...",
        "....eggdbbbbbdgg....",
        ".....eefgggggfea....",
        "......cceeeeeb......",
        ".....egeghhhhef.....",
        ".....gfeghhhgehb....",
        ".....eccfeeecae.....",
        ".......cgcafe.......",
        "........ea.ca.......",
        "....................",
    ]

    /// 工作中之一：官方第 7 行 running 首帧，抱着笔记本坐着敲
    static let working0 = [
        "....................",
        "....................",
        "....................",
        ".......d............",
        ".....fhhhfggd.......",
        "....chhhhhhhhc......",
        "...dghhhhhhhhgc.....",
        "..bhhhhgggggghg.....",
        "..ehhgcbbbbbbfhd....",
        "..fgheadcbbbache....",
        "..eggeadibbbbcgc....",
        "...fgeaidbcibcg.....",
        "...egfbaaaabacfa....",
        "...bfggeeeebbbabba..",
        ".....ceeffebbcdbba..",
        ".....ffeefebbbicba..",
        "....aegffcdbbcdba...",
        ".....eeccbbbaaaba...",
        ".....eebefccceb.....",
        "......ceffbcefb.....",
        "........cc..........",
        "....................",
    ]

    /// 工作中之二：同一行第 4 帧，眼睛瞪成两竖。官方 running 六帧只有脸在变，
    /// 20 列下多数帧的差别落不到一个像素上，取这两帧是因为脸差得最开
    static let working1 = [
        "....................",
        "....................",
        "....................",
        ".......d..c.........",
        ".....fhhhghhf.......",
        "....chhhhhhhhd......",
        "...dghhhhhhhhgd.....",
        "..chhhhgggggghhc....",
        "..fhhgcabbbabfhe....",
        "..fghdaddbbibche....",
        "..fggeaiiabibcge....",
        "..afgeaidabibcgc....",
        "...fgfbaaaaaacfa....",
        "...cfgfeeeecbbabbb..",
        "....aeeeffecbbdbba..",
        "....affeefebbaidba..",
        "....afgffddbbbdbb...",
        ".....eeccbbbaaaba...",
        ".....eebefcccec.....",
        "......ceffcbefc.....",
        "........cc..........",
        "....................",
    ]
}

/// 把调色板网格画出来。按色位归并再落笔：一帧 440 格若逐格 fill 是 440 次绘制，
/// 归并后只剩 9 次（每个色位一条 path）
private struct CodexPetCanvas: View {
    let grid: [String]

    var body: some View {
        Canvas { ctx, size in
            let cellW = size.width / CGFloat(CodexPetSprite.cols)
            let cellH = size.height / CGFloat(CodexPetSprite.rows)
            var paths = [Path](repeating: Path(), count: CodexPetSprite.palette.count)
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    // 'a' 起算的色位下标；越界（网格被改坏）就跳过，不画总比画错色好
                    let i = Int(ch.asciiValue ?? 0) - 97
                    guard paths.indices.contains(i) else { continue }
                    paths[i].addRect(CGRect(x: CGFloat(x) * cellW, y: CGFloat(y) * cellH,
                                            width: cellW, height: cellH))
                }
            }
            for (i, path) in paths.enumerated() where !path.isEmpty {
                ctx.fill(path, with: .color(CodexPetSprite.palette[i]))
            }
        }
        .drawingGroup()   // 九条 path 合成一层位图，槽位重绘时不必逐帧重走 Canvas
    }
}

/// 收起态槽位里的 Codex 工作状态：官方小人 + 指示灯。
///
/// 空闲 = 绿灯 + 站着；工作中 = 黄灯 + 抱着笔记本敲，两帧交替。
/// 和 `ClawdSlotView` 同一套规矩：动画只在工作态存在，空闲不留常驻定时器。
struct CodexPetSlotView: View {
    let working: Bool

    /// 与 Clawd 同一节奏。官方 running 标的是 120ms，那是给全尺寸看的，
    /// 20 列下脸上那点差别每秒闪八次只会像抽搐
    private static let frameInterval: TimeInterval = 0.38
    /// 24×26.4 = 每格 1.2pt。原件近似正方（192:208），再大就顶破 38pt 的刘海高度；
    /// 加 4pt 间距与 6pt 指示灯共 34.4pt，在右槽 50pt 可用宽度内
    private static let spriteWidth: CGFloat = 24
    private static let spriteHeight: CGFloat = 26.4

    var body: some View {
        HStack(spacing: 4) {
            if working {
                TimelineView(.periodic(from: .now, by: Self.frameInterval)) { ctx in
                    let step = Int(ctx.date.timeIntervalSinceReferenceDate / Self.frameInterval)
                    sprite(step.isMultiple(of: 2) ? CodexPetSprite.working0 : CodexPetSprite.working1)
                }
            } else {
                sprite(CodexPetSprite.idle)
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
