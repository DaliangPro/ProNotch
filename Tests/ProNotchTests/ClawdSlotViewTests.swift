import XCTest
import SwiftUI
@testable import ProNotch

/// Clawd 槽位的素材完整性与尺寸边界。
///
/// 素材是从 Claude Code 二进制里解出来的官方原件，不是手画的——
/// 网格一旦被改歪（少一列、多一行），肉眼在 36×12pt 上根本看不出来，只能靠断言钉住。
/// 尺寸更要钉：刘海右侧槽位可用宽度只有 50pt，超了就是被裁掉半只 Clawd。
@MainActor
final class ClawdSlotViewTests: XCTestCase {

    /// 右侧槽位 56pt 宽，但有 6pt 内边距贴向刘海，实际可用 50pt
    private let usableWidth: CGFloat = 50
    /// 收起态刘海高度（14 寸 MBP 典型值）
    private let slotHeight: CGFloat = 38

    func test两个姿态的网格尺寸一致() {
        for (name, grid) in [("standing", ClawdSprite.standing), ("armsUp", ClawdSprite.armsUp)] {
            XCTAssertEqual(grid.count, 5, "\(name) 行数不对")
            for (i, row) in grid.enumerated() {
                XCTAssertEqual(row.count, ClawdSprite.cols,
                               "\(name) 第 \(i) 行是 \(row.count) 列，应为 \(ClawdSprite.cols)")
            }
        }
    }

    /// 网格只认 # 与 .：混进别的字符会被当成空白静默吞掉，画出来缺一块
    func test网格只含约定的两种字符() {
        for grid in [ClawdSprite.standing, ClawdSprite.armsUp] {
            for row in grid {
                XCTAssertTrue(row.allSatisfy { $0 == "#" || $0 == "." }, "混入了非法字符：\(row)")
            }
        }
    }

    /// 举手帧要比站立帧更宽（触手抬起来伸出去），否则动画看着没动
    func test举手帧确实比站立帧多铺了像素() {
        func filled(_ g: [String]) -> Int { g.reduce(0) { $0 + $1.filter { $0 == "#" }.count } }
        XCTAssertGreaterThan(filled(ClawdSprite.armsUp), filled(ClawdSprite.standing),
                             "两帧像素数一样，多半是复制粘贴时没改")
    }

    /// 站立帧第 2 行有且仅有两个缺口——那是眼睛。填死了就成一块砖
    func test站立帧留着两只眼睛() {
        let eyes = ClawdSprite.standing[1]
        let gaps = eyes.enumerated().filter { $0.element == "." && (3...14).contains($0.offset) }
        XCTAssertEqual(gaps.count, 2, "眼睛数量不对：\(eyes)")
    }

    /// 顶上那一行留白是给弹跳用的。rows 若等于内容行数，举手帧上抬时会顶出画布被裁
    func test网格高度给弹跳留了一行() {
        XCTAssertEqual(ClawdSprite.rows, ClawdSprite.standing.count + 1)
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
