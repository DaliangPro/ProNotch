import XCTest
import AppKit
@testable import ProNotch

/// 序号（流程）新交互的几何口径（大梁老师 2026-08-07：
/// 「用户点一个地方，然后拉出一条线，停止以后出现序号，并且序号后面可以输入文字」）。
///
/// 「后面」＝紧贴角标右侧，不是斜上方另起一个气泡再连一根线。
@MainActor
final class ScreenshotStepLayoutTests: XCTestCase {

    private let r: CGFloat = 13                                   // badgeRadius
    private let sel = NSRect(x: 100, y: 100, width: 600, height: 400)
    private let size = NSSize(width: 120, height: 30)

    func test说明框紧贴角标右侧且垂直居中() {
        let c = NSPoint(x: 300, y: 300)
        let b = ScreenshotOverlayView.stepBubbleRect(center: c, size: size, in: sel, badgeRadius: r)
        XCTAssertEqual(b.minX, c.x + r + 8, accuracy: 0.01, "说明框应挨着角标右边，不留大缝")
        XCTAssertEqual(b.midY, c.y, accuracy: 0.01, "说明框应与角标垂直居中，序号和文字在一条线上")
    }

    /// 这条是「那截斜杠」的回归闸门：新建时气泡就贴着角标，此时若还画引导线，
    /// 只会在角标和气泡的夹缝里露出一小段斜线
    func test新建时不该画引导线() {
        for c in [NSPoint(x: 300, y: 300), NSPoint(x: 110, y: 110), NSPoint(x: 690, y: 490)] {
            let b = ScreenshotOverlayView.stepBubbleRect(center: c, size: size, in: sel, badgeRadius: r)
            XCTAssertFalse(ScreenshotOverlayView.bubbleDetached(from: c, b, badgeRadius: r),
                           "角标 \(c) 新建时说明框还贴着，不该判为「已拖离」")
        }
    }

    /// 拖远了才画：把气泡挪到角标斜上方一大截，就该恢复引导线
    func test拖远后要画引导线() {
        let c = NSPoint(x: 300, y: 300)
        let far = NSRect(x: c.x + 90, y: c.y + 70, width: size.width, height: size.height)
        XCTAssertTrue(ScreenshotOverlayView.bubbleDetached(from: c, far, badgeRadius: r))
    }

    func test右侧放不下就翻到角标左边() {
        let c = NSPoint(x: sel.maxX - 30, y: 300)   // 贴着选区右边缘
        let b = ScreenshotOverlayView.stepBubbleRect(center: c, size: size, in: sel, badgeRadius: r)
        XCTAssertLessThanOrEqual(b.maxX, c.x - r, "右边放不下时说明框应整体翻到角标左侧")
    }

    /// 无论角标落在哪，说明框都不许探出选区（探出去的部分导出时会被裁掉）
    func test说明框始终夹在选区内() {
        for x in stride(from: sel.minX, through: sel.maxX, by: 50) {
            for y in stride(from: sel.minY, through: sel.maxY, by: 50) {
                let b = ScreenshotOverlayView.stepBubbleRect(center: NSPoint(x: x, y: y), size: size, in: sel, badgeRadius: r)
                XCTAssertTrue(sel.contains(b), "角标 (\(x), \(y)) 的说明框 \(b) 探出了选区 \(sel)")
            }
        }
    }
}
