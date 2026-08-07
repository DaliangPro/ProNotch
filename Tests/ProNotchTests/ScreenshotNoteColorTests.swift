import XCTest
@testable import ProNotch

/// 备注（框选 + 输入文字）的新建默认色（大梁老师 2026-08-07）。
@MainActor
final class ScreenshotNoteColorTests: XCTestCase {

    /// 默认红：白色在浅色截图（文档、网页、白底 App）上等于框了没框，
    /// 与框选/箭头/文字统一取调色板首位，不新增配色
    func test备注默认色为调色板首位红() {
        XCTAssertEqual(ScreenshotOverlayView.defaultNoteColorHex, BoxOptionsBar.palette.first)
        XCTAssertEqual(ScreenshotOverlayView.defaultNoteColorHex, "#FF453A")
    }
}
