import XCTest
import SwiftUI
@testable import ProNotch

/// Codex 槽位的素材完整性与尺寸边界。
///
/// 素材是官方精灵图降采样来的（见 `CodexPetSprite` 的说明），网格与调色板一旦被改歪，
/// 在 24×26pt 上肉眼看不出来，只能靠断言钉住。尺寸同样要钉：右槽可用宽度只有 50pt。
@MainActor
final class CodexPetSlotViewTests: XCTestCase {

    /// 右侧槽位 56pt 宽，但有 6pt 内边距贴向刘海，实际可用 50pt
    private let usableWidth: CGFloat = 50
    /// 收起态刘海高度（14 寸 MBP 典型值）
    private let slotHeight: CGFloat = 38

    private var allGrids: [(String, [String])] {
        [("idle", CodexPetSprite.idle),
         ("working0", CodexPetSprite.working0),
         ("working1", CodexPetSprite.working1)]
    }

    func test三帧的网格尺寸一致() {
        for (name, grid) in allGrids {
            XCTAssertEqual(grid.count, CodexPetSprite.rows, "\(name) 行数不对")
            for (i, row) in grid.enumerated() {
                XCTAssertEqual(row.count, CodexPetSprite.cols,
                               "\(name) 第 \(i) 行是 \(row.count) 列，应为 \(CodexPetSprite.cols)")
            }
        }
    }

    /// 网格里只允许出现「.」与调色板范围内的色位字母。
    /// 越界字母会被绘制时静默跳过，画出来缺一块——这里提前拦掉
    func test网格字符都落在调色板范围内() {
        let last = Character(UnicodeScalar(97 + CodexPetSprite.palette.count - 1)!)
        for (name, grid) in allGrids {
            for row in grid {
                for ch in row where ch != "." {
                    XCTAssertTrue(("a"..."z").contains(ch) && ch <= last,
                                  "\(name) 里出现越界色位「\(ch)」，可用到 \(last)")
                }
            }
        }
    }

    /// 青色（色位 i）是脸上那个 >_，是这只的辨识点。三帧都得有，
    /// 掉了就只剩一坨蓝、认不出是 Codex
    func test每帧都留着脸上的青色() {
        let cyan = Character(UnicodeScalar(97 + CodexPetSprite.palette.count - 1)!)
        for (name, grid) in allGrids {
            let count = grid.reduce(0) { $0 + $1.filter { $0 == cyan }.count }
            XCTAssertGreaterThanOrEqual(count, 2, "\(name) 的青色只剩 \(count) 格")
        }
    }

    /// 工作态两帧必须真的不一样，否则动画看着没动
    func test工作态两帧确有差别() {
        XCTAssertNotEqual(CodexPetSprite.working0, CodexPetSprite.working1)
    }

    /// 空闲是站姿、工作是抱笔记本坐姿，轮廓差别应当明显——
    /// 若两者只差几格，说明取帧时取错了行
    func test空闲与工作取的是不同姿态() {
        func filled(_ g: [String]) -> Int { g.reduce(0) { $0 + $1.filter { $0 != "." }.count } }
        let diff = zip(CodexPetSprite.idle, CodexPetSprite.working0).reduce(0) { acc, pair in
            acc + zip(pair.0, pair.1).filter { $0 != $1 }.count
        }
        XCTAssertGreaterThan(diff, filled(CodexPetSprite.idle) / 3,
                             "两个姿态差别太小，多半是从同一行取的帧")
    }

    func test空闲态尺寸塞得进槽位() throws {
        let size = try fittingSize(working: false)
        XCTAssertLessThanOrEqual(size.width, usableWidth, "宽了会被裁掉半只")
        XCTAssertLessThanOrEqual(size.height, slotHeight)
    }

    /// 黄灯亮起时指示灯不该横向跳一下
    func test工作态与空闲态尺寸一致() throws {
        XCTAssertEqual(try fittingSize(working: true), try fittingSize(working: false))
    }

    /// 两个 Agent 槽位并排时高度不该打架
    func test与Clawd槽位同高() throws {
        let codex = try fittingSize(working: false)
        let clawd = NSHostingView(rootView: ClawdSlotView(working: false))
        clawd.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(abs(codex.height - clawd.fittingSize.height), 8,
                                 "两只高度差超过 8pt，并排会一高一低")
    }

    private func fittingSize(working: Bool) throws -> CGSize {
        let host = NSHostingView(rootView: CodexPetSlotView(working: working))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
