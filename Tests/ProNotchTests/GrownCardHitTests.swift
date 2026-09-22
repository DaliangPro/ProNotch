import XCTest
@testable import ProNotch

/// 提醒卡挂着时只有卡身接点击（大梁老师 2026-09-22 反馈：弹窗出现时会干扰点击其他软件）。
///
/// 此前卡一挂出来整扇刘海窗口（约 1088×550pt）解除穿透，窗口里的透明处也接点击，
/// 屏幕上方正中一大块点别的 App 全被吞。这里钉住「只有卡身范围算数」。
///
/// 刘海 185×32pt，摆在 y ∈ [0, 32]，顶边 y=32 即屏幕顶边（同 NotchEdgeGuardTests 的建模）
@MainActor
final class GrownCardHitTests: XCTestCase {

    private func makeVM() -> NotchViewModel {
        NotchViewModel(notchRect: CGRect(x: 500, y: 0, width: 185, height: 32))
    }

    /// 刘海正中 x；任务完成卡 360 宽、伸出 132，卡底 y = 32 - 32 - 132 = -132
    private let midX: CGFloat = 592.5

    func test没有卡时哪里都不接() {
        let vm = makeVM()
        XCTAssertFalse(vm.mouseOnGrownCard(CGPoint(x: midX, y: -50)))
        XCTAssertTrue(vm.grownCardHitRects.isEmpty)
    }

    func test任务完成卡只有卡身接点击() {
        let vm = makeVM()
        vm.agentCardVisible = true
        XCTAssertTrue(vm.mouseOnGrownCard(CGPoint(x: midX, y: -50)), "卡身中间要点得到")
        XCTAssertTrue(vm.mouseOnGrownCard(CGPoint(x: midX - 175, y: -50)), "卡身左缘内侧要点得到")
        XCTAssertFalse(vm.mouseOnGrownCard(CGPoint(x: midX, y: -140)), "卡底往下 8pt 已是光晕，不该接")
        XCTAssertFalse(vm.mouseOnGrownCard(CGPoint(x: midX - 190, y: -50)), "卡左侧外面不该接")
        XCTAssertFalse(vm.mouseOnGrownCard(CGPoint(x: midX - 450, y: -300)), "窗口里的远处不该接")
    }

    func test鼠标顶到屏幕最顶仍算在卡上() {
        let vm = makeVM()
        vm.agentCardVisible = true
        // CGRect.contains 的上界是开区间，顶边 y=32 恰好是屏幕顶
        XCTAssertTrue(vm.mouseOnGrownCard(CGPoint(x: midX, y: 32)))
    }

    func test天气预警卡按自己的尺寸算() {
        let vm = makeVM()
        vm.alertBannerVisible = true
        // 预警卡 440 宽、伸出 180：比任务完成卡宽也更长
        XCTAssertTrue(vm.mouseOnGrownCard(CGPoint(x: midX - 200, y: -50)))
        XCTAssertTrue(vm.mouseOnGrownCard(CGPoint(x: midX, y: -170)))
        XCTAssertFalse(vm.mouseOnGrownCard(CGPoint(x: midX, y: -190)))
    }

    func test两张卡同时在场取并集() {
        let vm = makeVM()
        vm.agentCardVisible = true
        vm.alertBannerVisible = true
        XCTAssertEqual(vm.grownCardHitRects.count, 2)
        XCTAssertTrue(vm.mouseOnGrownCard(CGPoint(x: midX - 200, y: -50)), "预警卡更宽的那截也算")
        vm.alertBannerVisible = false
        XCTAssertFalse(vm.mouseOnGrownCard(CGPoint(x: midX - 200, y: -50)), "预警收了只剩任务完成卡的范围")
    }
}
