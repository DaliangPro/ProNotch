import XCTest
import SwiftUI
@testable import ProNotch

/// Clawd 槽位的素材完整性与尺寸边界。
///
/// 四态形象改用大梁老师重绘的 PNG（`Resources/claude-code-idle|working.png`），手绘字符网格已退役。
/// 这里钉两件事：① 素材在位、贴身横向、fit 进显示框后能顶到内存环量级的高度（不再是过小的方画布）；
/// ② 槽位内容塞得进**固定黑条侧宽**（不随选谁变）、与 Codex 等宽、指示灯不被圆角裁。
///
/// 素材直接按源文件路径读——xctest 没有 App bundle，`NSImage(named:)` 解析不到，只能读盘校验。
@MainActor
final class ClawdSlotViewTests: XCTestCase {

    /// 定位项目根 `Resources/`：#filePath = …/Tests/ProNotchTests/本文件，往上三级到项目根
    private var resourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ProNotchTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 项目根
            .appendingPathComponent("Resources")
    }

    /// 右槽实际可用宽 = 固定侧宽 − 摄像头侧内边距（侧宽恒为 `fixedSideWidth`，不随选谁变）
    private var usableWidth: CGFloat { NotchSlot.fixedSideWidth - NotchSlot.leadingPad }
    /// 收起态刘海高度（14 寸 MBP 典型值）
    private let slotHeight: CGFloat = 38

    // MARK: - 素材

    /// 空闲/工作两张 PNG 必须都在、贴身横向（宽>高），且 fit 进显示框后渲染高度与内存环同量级。
    /// 大梁老师实测：图标要跟左侧内存环（21pt）一样大。裁成正方画布会把横向身形上下夹扁到约 14pt，
    /// 故改贴身横向 + 21pt 高框，实际渲染高度须 ≥ 18pt 才算「一样大」
    func test四态素材齐全且填满槽高() throws {
        for name in ["claude-code-idle", "claude-code-working"] {
            let url = resourcesDir.appendingPathComponent(name + ".png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缺素材 \(name).png")
            let img = try XCTUnwrap(NSImage(contentsOf: url), "\(name).png 读不出，可能损坏")
            let rep = try XCTUnwrap(img.representations.first, "\(name).png 没有位图表示")
            let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
            XCTAssertGreaterThan(w, h, "\(name) 该是贴身横向（\(rep.pixelsWide)×\(rep.pixelsHigh)）")
            // aspectRatio(.fit) 进 spriteWidth×spriteHeight 框后的实际渲染高度
            let scale = min(AgentSlotMetrics.spriteWidth / w, AgentSlotMetrics.spriteHeight / h)
            XCTAssertGreaterThanOrEqual(h * scale, 18,
                                        "\(name) fit 后仅 \(h * scale)pt 高，比内存环 21pt 明显小")
        }
    }

    // MARK: - 尺寸

    /// 大梁老师的核心诉求：**选 Claude 与选 Codex，收起态刘海必须一样宽**。
    /// 两家内容宽取同一个 `AgentSlotMetrics.contentWidth`，从根上等宽——侧宽固定、内容等宽，
    /// 刘海就绝不会「选了 Claude 宽一些」
    func test与Codex内容等宽() {
        XCTAssertEqual(ClawdSlotView.contentWidth, CodexPetSlotView.contentWidth,
                       "两家 Agent 内容宽不相等，选谁刘海会不一样宽")
        XCTAssertEqual(ClawdSlotView.contentWidth, AgentSlotMetrics.contentWidth)
    }

    /// 回归：固定侧宽必须给指示灯让开圆角直壁。黑 pill 的竖直壁在 `maxX - topRadius` 处、
    /// 比名义边缘往里收 `cornerInset`，若外侧余量不够，靠左对齐的指示灯会顶出直壁被裁——
    /// 就是大梁老师报的「小黄点出去了」。外侧余量 = 固定侧宽 − 摄像头侧内边距 − 内容宽，须 ≥ 圆角内收量
    func testAgent固定侧宽给指示灯让开圆角() {
        let outerSlack = NotchSlot.fixedSideWidth
            - NotchSlot.leadingPad - ClawdSlotView.contentWidth
        XCTAssertGreaterThanOrEqual(outerSlack, NotchSlot.cornerInset,
                                    "外侧余量不足以让开圆角直壁，指示灯会被裁")
    }

    func test空闲态尺寸塞得进槽位() throws {
        let size = try fittingSize(working: false)
        XCTAssertLessThanOrEqual(size.width, usableWidth, "宽了会被裁掉半只 Clawd")
        XCTAssertLessThanOrEqual(size.height, slotHeight)
    }

    /// 黄灯亮起的瞬间指示灯不该横向跳——两态整体尺寸必须一致（靠固定宽度容器保证；上下轻跳是 offset，不改尺寸）
    func test工作态与空闲态尺寸一致() throws {
        XCTAssertEqual(try fittingSize(working: true), try fittingSize(working: false))
    }

    /// 两个 Agent 槽位并排时高度必须相等（都取 `AgentSlotMetrics.spriteHeight`）
    func test与Codex槽位同高() throws {
        let clawd = try fittingSize(working: false)
        let codex = NSHostingView(rootView: CodexPetSlotView(working: false))
        codex.layoutSubtreeIfNeeded()
        XCTAssertEqual(clawd.height, codex.fittingSize.height, "两只高度不相等，并排会一高一低")
    }

    private func fittingSize(working: Bool) throws -> CGSize {
        let host = NSHostingView(rootView: ClawdSlotView(working: working))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
