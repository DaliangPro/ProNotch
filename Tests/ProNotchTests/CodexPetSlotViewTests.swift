import XCTest
import SwiftUI
@testable import ProNotch

/// Codex 槽位的素材完整性与尺寸边界。
///
/// 素材照大梁老师提供的第二张官方「终端云」像素画比例还原（22 列三色，见 `CodexPetSprite` 的说明），
/// 网格一旦被改歪，在 24pt 上肉眼看不出来，只能靠断言钉住。
/// 尺寸同样要钉：右槽可用宽度只有 50pt。
@MainActor
final class CodexPetSlotViewTests: XCTestCase {

    /// 右侧槽位 56pt 宽，但有 6pt 内边距贴向刘海，实际可用 50pt
    private let usableWidth: CGFloat = 50
    /// 收起态刘海高度（14 寸 MBP 典型值）
    private let slotHeight: CGFloat = 38

    private var allFrames: [(String, [String])] {
        [("resting", CodexPetSprite.resting), ("hopping", CodexPetSprite.hopping)]
    }

    /// 落地/弹起两态共用同一坐标系（弹跳靠网格内的留白表现），尺寸必须完全一致，
    /// 否则切帧时整只会缩放，旁边的指示灯跟着横向跳
    func test两态网格尺寸一致() {
        for (name, grid) in allFrames {
            XCTAssertEqual(grid.count, CodexPetSprite.rows, "\(name) 行数不对")
            for (i, row) in grid.enumerated() {
                XCTAssertEqual(row.count, CodexPetSprite.cols,
                               "\(name) 第 \(i) 行是 \(row.count) 列，应为 \(CodexPetSprite.cols)")
            }
        }
    }

    /// 网格只认 . b k c：混进别的字符会被 `CodexPetCanvas` 的 default 分支当成身体画出来，多一块糊在身上
    func test网格只含约定的四种字符() {
        for (name, grid) in allFrames {
            for row in grid {
                XCTAssertTrue(row.allSatisfy { $0 == "." || $0 == "b" || $0 == "k" || $0 == "c" },
                              "\(name) 混入了非法字符：\(row)")
            }
        }
    }

    /// 得有一整块黑色终端屏——那是这只的辨识主体。掉了就只剩一朵纯蓝云，认不出是 Codex。
    /// 阈值按 22 列网格定（本体黑格约 70 出头）
    func test有成块的终端屏() {
        let black = CodexPetSprite.character.reduce(0) { $0 + $1.filter { $0 == "k" }.count }
        XCTAssertGreaterThan(black, 40, "黑屏只剩 \(black) 格，终端脸没了")
    }

    /// 屏上的 `>_` 提示符是独立浅蓝格（`c`），必须都嵌在黑屏包围盒内——
    /// 落在屏外就是画歪了。数量太少说明 `>` 或 `_` 掉了，脸就残了
    func test终端屏上留着提示符() {
        let g = CodexPetSprite.character
        func at(_ y: Int, _ x: Int) -> Character {
            let row = g[y]
            return row[row.index(row.startIndex, offsetBy: x)]
        }
        // 黑屏包围盒
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in g.indices {
            for x in 0..<g[y].count where at(y, x) == "k" {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        var prompt = 0
        for y in g.indices {
            for x in 0..<g[y].count where at(y, x) == "c" {
                prompt += 1
                XCTAssertTrue(x >= minX && x <= maxX && y >= minY && y <= maxY,
                              "提示符像素 (\(x),\(y)) 跑到黑屏外了")
            }
        }
        XCTAssertGreaterThanOrEqual(prompt, 6, "屏内的提示符像素只剩 \(prompt) 格，`>_` 残了")
    }

    /// 提示符浅蓝必须与身体蓝分色——同色就退回上一张「靠黑屏衬」的旧观感了
    func test提示符与身体分色() {
        XCTAssertNotEqual(CodexPetSprite.promptColor, CodexPetSprite.bodyColor,
                          "提示符与身体同色，脸从黑屏里衬不出来")
    }

    /// 落地与弹起必须真的错开一格，否则「弹跳」是原地不动
    func test两态确有位移() {
        XCTAssertNotEqual(CodexPetSprite.resting, CodexPetSprite.hopping,
                          "落地态与弹起态完全一样，弹跳看不出来")
    }

    /// 弹跳只是整体平移，不该增删像素——两态的非空格子数必须相等
    func test弹跳前后像素守恒() {
        func filled(_ g: [String]) -> Int { g.reduce(0) { $0 + $1.filter { $0 != "." }.count } }
        XCTAssertEqual(filled(CodexPetSprite.resting), filled(CodexPetSprite.hopping))
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
