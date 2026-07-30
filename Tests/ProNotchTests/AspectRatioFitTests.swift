import XCTest
@testable import ProNotch

/// 截图选区的比例辅助。
///
/// 由来（大梁老师，2026-07-28）：想截一个正方形，只能盯着实时尺寸数字手动拖，
/// 怎么拖都差几个像素。这里钉住三条约定——**中心不动、只往里收、幂等**，
/// 三条里错一条，用户点两下比例就会发现框跑偏或者越点越小。
final class AspectRatioFitTests: XCTestCase {

    private let wide = NSRect(x: 100, y: 100, width: 800, height: 600)

    // MARK: - 收出来的尺寸

    /// 800×600 点 1:1 → 600×600：短边说话，长边收进来
    func test正方形取短边() {
        let r = AspectRatio.square.fit(wide)
        XCTAssertEqual(r.width, 600, accuracy: 0.001)
        XCTAssertEqual(r.height, 600, accuracy: 0.001)
    }

    /// 太宽 → 收窄（1000×600 要 4:3，得到 800×600）
    func test太宽的框收窄() {
        let r = AspectRatio.fourThree.fit(NSRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(r.width, 800, accuracy: 0.001)
        XCTAssertEqual(r.height, 600, accuracy: 0.001)
    }

    /// 太高 → 压扁（600×600 要 4:3，得到 600×450）
    func test太高的框压扁() {
        let r = AspectRatio.fourThree.fit(NSRect(x: 0, y: 0, width: 600, height: 600))
        XCTAssertEqual(r.width, 600, accuracy: 0.001)
        XCTAssertEqual(r.height, 450, accuracy: 0.001)
    }

    func test各档比例算对() {
        for r in AspectRatio.allCases {
            guard let want = r.value else { continue }
            let fitted = r.fit(wide)
            XCTAssertEqual(fitted.width / fitted.height, want, accuracy: 0.0001, "\(r.label) 比例不对")
        }
    }

    // MARK: - 三条约定

    /// 中心不动：框东西时主体一般居中，钉左上角会让主体往右下偏出去
    func test中心不动() {
        for r in AspectRatio.allCases {
            let fitted = r.fit(wide)
            XCTAssertEqual(fitted.midX, wide.midX, accuracy: 0.001, "\(r.label) 横向中心跑了")
            XCTAssertEqual(fitted.midY, wide.midY, accuracy: 0.001, "\(r.label) 纵向中心跑了")
        }
    }

    /// 只往里收：往外扩会把框外、用户压根没看过的内容拉进画面
    func test只往里收绝不往外扩() {
        for r in AspectRatio.allCases {
            let fitted = r.fit(wide)
            XCTAssertLessThanOrEqual(fitted.width, wide.width + 0.001, "\(r.label) 把框撑宽了")
            XCTAssertLessThanOrEqual(fitted.height, wide.height + 0.001, "\(r.label) 把框撑高了")
            XCTAssertTrue(wide.insetBy(dx: -0.001, dy: -0.001).contains(fitted), "\(r.label) 收出框外了")
        }
    }

    /// 幂等：已经是该比例的框再套一次不该再变。
    /// 这一条保证「反复点同一个比例」不会一路缩水
    func test同一比例反复套用不再变() {
        for r in AspectRatio.allCases {
            let once = r.fit(wide)
            let twice = r.fit(once)
            XCTAssertEqual(once, twice, "\(r.label) 第二次套用又变了")
        }
    }

    // MARK: - 自由与退化输入

    /// 自由态原样返回：它的语义是「不约束」，真正的还原由调用方拿 ratioBaseRect 做
    func test自由态原样返回() {
        XCTAssertNil(AspectRatio.free.value)
        XCTAssertEqual(AspectRatio.free.fit(wide), wide)
    }

    /// 退化输入不许崩、不许返回 NaN 框：刚按下鼠标还没拖开时选区就是 0 尺寸
    func test零尺寸与非法值安全返回() {
        let zero = NSRect(x: 10, y: 10, width: 0, height: 0)
        XCTAssertEqual(AspectRatio.square.fit(zero), zero)
        let flat = NSRect(x: 0, y: 0, width: 500, height: 0)
        XCTAssertEqual(AspectRatio.square.fit(flat), flat)
        // NaN 尺寸原样退回，绝不算出一个 NaN 框——那会让后面的裁剪与导出整条链路失效
        let broken = NSRect(x: 0, y: 0, width: CGFloat.nan, height: 100)
        XCTAssertTrue(AspectRatio.square.fit(broken).width.isNaN, "非法输入应原样退回，不做换算")
        XCTAssertEqual(AspectRatio.square.fit(broken).height, 100)
    }

    /// 档位与文案一一对应，且「自由」排在最前（它是还原用的，位置得稳定）
    func test档位顺序与文案() {
        XCTAssertEqual(AspectRatio.allCases.map(\.label), ["自由", "1:1", "4:3", "3:2", "16:9"])
    }
}
