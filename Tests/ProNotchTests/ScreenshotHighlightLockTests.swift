import XCTest
@testable import ProNotch

/// 高亮范围的锁定口径（大梁老师 2026-08-07）。
///
/// 由来：高亮框整块都可命中，于是在高亮范围里用别的工具框选时，鼠标稍靠边就把高亮范围拖走了。
/// 规则＝切到任何其他工具即锁定（连选中都不给），回到高亮工具才解锁。
@MainActor
final class ScreenshotHighlightLockTests: XCTestCase {

    func test高亮框只在高亮工具下解锁() {
        XCTAssertTrue(ScreenshotOverlayView.boxUnlocked(isHighlight: true, isHighlightTool: true),
                      "回到高亮工具，范围要能调")
        XCTAssertFalse(ScreenshotOverlayView.boxUnlocked(isHighlight: true, isHighlightTool: false),
                       "切到框选/文字等其他工具时，高亮范围必须锁死")
    }

    /// 锁的是高亮，不是所有框：普通框选在任何工具下都照旧可选中调整
    func test普通框选不受锁影响() {
        XCTAssertTrue(ScreenshotOverlayView.boxUnlocked(isHighlight: false, isHighlightTool: false))
        XCTAssertTrue(ScreenshotOverlayView.boxUnlocked(isHighlight: false, isHighlightTool: true))
    }
}
