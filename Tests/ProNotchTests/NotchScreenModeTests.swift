import XCTest
@testable import ProNotch

/// 「显示屏幕」筛选口径（NotchGeometry.pick 纯函数）。
/// 约定：列表首项是主屏（与 NSScreen.screens 一致），其余为副屏
final class NotchScreenModeTests: XCTestCase {
    private let dual = ["主屏", "副屏"]
    private let triple = ["主屏", "副屏A", "副屏B"]
    private let single = ["主屏"]

    func test全部屏幕原样返回() {
        XCTAssertEqual(NotchGeometry.pick(dual, mode: .all), dual)
        XCTAssertEqual(NotchGeometry.pick(triple, mode: .all), triple)
    }

    func test仅主屏只留首项() {
        XCTAssertEqual(NotchGeometry.pick(dual, mode: .primary), ["主屏"])
        XCTAssertEqual(NotchGeometry.pick(triple, mode: .primary), ["主屏"])
    }

    func test仅副屏留下除主屏外全部() {
        XCTAssertEqual(NotchGeometry.pick(dual, mode: .secondary), ["副屏"])
        XCTAssertEqual(NotchGeometry.pick(triple, mode: .secondary), ["副屏A", "副屏B"],
                       "三屏时两块副屏都要有，不是只取一块")
    }

    /// 拔掉外接屏后若严格执行「仅副屏」，刘海会整个消失——用户只会当成 App 坏了，
    /// 且没有任何提示能让人联想到是这个设置。故退回主屏
    func test仅副屏但只剩一块屏时退回主屏() {
        XCTAssertEqual(NotchGeometry.pick(single, mode: .secondary), ["主屏"])
    }

    func test无屏幕时返回空() {
        XCTAssertEqual(NotchGeometry.pick([String](), mode: .all), [])
        XCTAssertEqual(NotchGeometry.pick([String](), mode: .secondary), [])
    }
}
