import XCTest
import SwiftUI
@testable import ProNotch

/// Clawd 槽位的素材完整性与尺寸边界。
///
/// 素材是从官方精灵表 `claude.ai/clawd-frames/all-sprite.png` 逐像素解出来的原件，不是手画的——
/// 网格一旦被改歪（少一列、多一行、错一格），肉眼在 28×19.7pt 上根本看不出来，只能靠断言钉住。
/// 尺寸更要钉：刘海右侧槽位可用宽度只有 50pt，超了就是被裁掉半只 Clawd。
@MainActor
final class ClawdSlotViewTests: XCTestCase {

    /// 右侧槽位 56pt 宽，但有 6pt 内边距贴向刘海，实际可用 50pt
    private let usableWidth: CGFloat = 50
    /// 收起态刘海高度（14 寸 MBP 典型值）
    private let slotHeight: CGFloat = 38

    private var allFrames: [(String, [String])] {
        [("standing", ClawdSprite.standing)]
            + ClawdSprite.walking.enumerated().map { ("walk\($0.offset)", $0.element) }
    }

    /// 五帧共用同一坐标系（弹跳靠网格内的留白表现），尺寸必须完全一致，
    /// 否则切帧时整只会缩放，旁边的指示灯跟着横向跳
    func test五帧网格尺寸一致() {
        for (name, grid) in allFrames {
            XCTAssertEqual(grid.count, ClawdSprite.rows, "\(name) 行数不对")
            for (i, row) in grid.enumerated() {
                XCTAssertEqual(row.count, ClawdSprite.cols,
                               "\(name) 第 \(i) 行是 \(row.count) 列，应为 \(ClawdSprite.cols)")
            }
        }
    }

    /// 网格只认 . # o：混进别的字符会被 `ClawdCanvas` 当成主体画出来，多一块糊在身上
    func test网格只含约定的三种字符() {
        for (name, grid) in allFrames {
            for row in grid {
                XCTAssertTrue(row.allSatisfy { $0 == "." || $0 == "#" || $0 == "o" },
                              "\(name) 混入了非法字符：\(row)")
            }
        }
    }

    /// 每帧都得留着两只眼睛。眼睛是这只唯一的第二个颜色，掉了就成一块纯色饼
    func test每帧都是两只眼睛() {
        for (name, grid) in allFrames {
            guard let eyeRow = grid.first(where: { $0.contains("o") }) else {
                return XCTFail("\(name) 一只眼睛都没有")
            }
            // 数横向游程：连续的 o 算一只
            var runs = 0
            var prev: Character = "."
            for ch in eyeRow {
                if ch == "o" && prev != "o" { runs += 1 }
                prev = ch
            }
            XCTAssertEqual(runs, 2, "\(name) 眼睛数量是 \(runs)，应为 2")
        }
    }

    /// 走路四帧必须两两不同：官方 20 帧里 0…3 是重复的静止帧，
    /// 抽帧时下标写错（比如抽成 0…3）就会得到一个不动的「走路」动画
    func test走路四帧互不相同() {
        let frames = ClawdSprite.walking
        for i in frames.indices {
            for j in frames.indices where j > i {
                XCTAssertNotEqual(frames[i], frames[j], "walk\(i) 与 walk\(j) 完全一样")
            }
        }
    }

    /// 空闲用站立、工作用走路，两态姿态得真不一样，否则黄灯亮了人还杵着
    func test站立与走路是不同姿态() {
        for (i, frame) in ClawdSprite.walking.enumerated() {
            XCTAssertNotEqual(frame, ClawdSprite.standing, "walk\(i) 和站立帧一模一样")
        }
    }

    /// 高度得由原件比例算出，不能手填。
    /// 比的是 `ceil` 后的值——`fittingSize` 会把 19.70 报成 20.0，向上取整到整点。
    /// 精度因此只到 1pt，但「拉扁 / 抻长」这类错法差的是好几 pt，照样拦得住
    func test槽位高度保持原件比例() throws {
        let size = try fittingSize(working: false)
        let expected = 28.0 / CGFloat(ClawdSprite.cols) * CGFloat(ClawdSprite.rows)
        XCTAssertEqual(size.height, expected.rounded(.up),
                       "高度偏离原件比例（应约 \(String(format: "%.2f", expected))pt），Clawd 被拉扁或抻长了")
    }

    func test空闲态尺寸塞得进槽位() throws {
        let size = try fittingSize(working: false)
        XCTAssertLessThanOrEqual(size.width, usableWidth, "宽了会被裁掉半只 Clawd")
        XCTAssertLessThanOrEqual(size.height, slotHeight)
    }

    /// 工作态多一个 TimelineView，但帧内容与空闲态占同一个 frame，尺寸不该变——
    /// 变了就意味着黄灯亮起的瞬间指示灯会横向跳一下
    func test工作态与空闲态尺寸一致() throws {
        XCTAssertEqual(try fittingSize(working: true), try fittingSize(working: false))
    }

    private func fittingSize(working: Bool) throws -> CGSize {
        let host = NSHostingView(rootView: ClawdSlotView(working: working))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
