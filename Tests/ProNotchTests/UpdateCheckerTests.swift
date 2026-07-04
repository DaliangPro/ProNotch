import XCTest
@testable import ProNotch

/// 版本比较：更新提醒的判定核心，错一位就会漏报/误报新版本
@MainActor
final class UpdateCheckerTests: XCTestCase {
    func test版本比较() {
        XCTAssertTrue(UpdateChecker.isNewer("1.5.4", than: "1.5.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.6.0", than: "1.5.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.5.10", than: "1.5.9"))   // 逐段数字比较，不是字符串比较
        XCTAssertTrue(UpdateChecker.isNewer("1.5.1", than: "1.5"))      // 缺位补 0
        XCTAssertFalse(UpdateChecker.isNewer("1.5.4", than: "1.5.4"))   // 相同不算新
        XCTAssertFalse(UpdateChecker.isNewer("1.5.3", than: "1.5.4"))
        XCTAssertFalse(UpdateChecker.isNewer("1.5", than: "1.5.0"))
    }
}
