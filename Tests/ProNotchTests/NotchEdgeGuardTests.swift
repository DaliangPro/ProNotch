import XCTest
@testable import ProNotch

/// 悬停触发区往里收一圈之后的判据（大梁老师 2026-07-31 提出：擦到边缘不该弹出来）。
///
/// 用本机实测的真实尺寸建模：刘海 185×32pt，贴屏幕顶边
@MainActor
final class NotchEdgeGuardTests: XCTestCase {

    /// 刘海：宽 185、高 32，摆在 y ∈ [0, 32]，顶边 y=32 即屏幕顶边。
    /// 默认关掉两侧功能区，先量纯刘海这一段；带侧区的另有一条用例
    private func makeVM(sideSlots: Bool = false) -> NotchViewModel {
        let vm = NotchViewModel(notchRect: CGRect(x: 500, y: 0, width: 185, height: 32))
        vm.sideSlotsActive = sideSlots
        return vm
    }

    func test中心照常展开() {
        let vm = makeVM()
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 592, y: 16)), "正中间必须还能触发")
    }

    func test擦左右边缘不触发() {
        let vm = makeVM()
        // 左缘往里 6pt（收边是 12），仍算擦边
        XCTAssertFalse(vm.hoverShouldExpand(at: CGPoint(x: 506, y: 16)), "左边缘擦过不该触发")
        XCTAssertFalse(vm.hoverShouldExpand(at: CGPoint(x: 679, y: 16)), "右边缘擦过不该触发")
    }

    func test走进去就触发() {
        let vm = makeVM()
        // 越过 12pt 收边（500+12=512）之后即生效
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 514, y: 16)), "真的走进去要能触发")
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 671, y: 16)), "右侧同理")
    }

    func test下沿浅蹭不触发() {
        let vm = makeVM()
        XCTAssertFalse(vm.hoverShouldExpand(at: CGPoint(x: 592, y: 3)), "刚碰到下沿不该触发")
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 592, y: 7)), "越过 5pt 收边就该触发")
    }

    func test侧区开着时收边同样生效() {
        // 侧区各 56pt：热区 x ∈ [444, 741]，收边 12 之后是 [456, 729]。
        // 收边若写在扩宽之前就会被完全抵消——这条用例专门盯住那个顺序
        let vm = makeVM(sideSlots: true)
        XCTAssertFalse(vm.hoverShouldExpand(at: CGPoint(x: 450, y: 16)), "侧区外缘擦过不该触发")
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 460, y: 16)), "走进侧区要能触发")
        XCTAssertFalse(vm.hoverShouldExpand(at: CGPoint(x: 735, y: 16)), "右侧同理")
    }

    func test上沿不收_顶到屏幕顶边仍能触发() {
        let vm = makeVM()
        // 上沿若也往里收，鼠标顶到屏幕最上面反而落在区外，想召唤都召唤不出来
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 592, y: 31.5)),
                      "贴着屏幕顶边必须仍然能触发")
    }

    func test鼠标滑到最顶端_坐标正好等于顶边也要触发() {
        // CGRect.contains 上界是开区间：y == maxY 判为区外。
        // 鼠标滑到屏幕最顶时 y 正好是 maxY(=32)，触发区必须往屏幕外多留一截才接得住。
        // 大梁老师 2026-07-31 实机撞到：「滑到刘海最顶部反而不弹出来」
        let vm = makeVM()
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 592, y: 32)),
                      "滑到最顶端必须触发")
        XCTAssertTrue(vm.hoverShouldExpand(at: CGPoint(x: 592, y: 34)),
                      "系统偶尔报出略高于顶边的 y，也要接住")
    }
}
