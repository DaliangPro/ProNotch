import XCTest
@testable import ProNotch

/// 窗口吸附截图的迟到结果隔离。
///
/// 吸附窗口 A 后异步截它的真实圆角形状图（走 ScreenCaptureKit，几十到几百毫秒）。
/// 用户手快，这期间完全来得及改吸附窗口 B。若 A 的结果后返回而实现只做
/// `snappedWindowImage = img`，B 的图就被 A 覆盖了——而导出只判断"图非空"，
/// 于是复制/保存出来的是 A 窗口的内容。这类问题不会报错，只会悄悄导出错东西。
@MainActor
final class WindowShapeCaptureRaceTests: XCTestCase {

    /// 造一张可区分的小图：用灰度值当"身份证"，方便断言拿到的是哪一张
    private func image(tag: UInt8) -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: CGFloat(tag) / 255.0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    private func tag(of image: CGImage) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data.first ?? 0
    }

    // MARK: - 代际与身份

    func test吸附新窗口会递增代际() {
        let c = WindowShapeCoordinator()
        XCTAssertEqual(c.generation, 0)
        let g1 = c.beginSnap(windowID: 1)
        let g2 = c.beginSnap(windowID: 2)
        XCTAssertEqual(g1, 1)
        XCTAssertEqual(g2, 2)
        XCTAssertEqual(c.windowID, 2)
    }

    func test吸附新窗口会清掉旧形状() {
        let c = WindowShapeCoordinator()
        let g = c.beginSnap(windowID: 1)
        XCTAssertTrue(c.accept(image(tag: 11), windowID: 1, generation: g))
        XCTAssertNotNil(c.currentShapeImage)

        c.beginSnap(windowID: 2)
        XCTAssertNil(c.currentShapeImage, "切到新窗口后不能还留着上一个窗口的图")
    }

    func testA的结果迟到_不覆盖已切去的B() {
        let c = WindowShapeCoordinator()
        let gA = c.beginSnap(windowID: 100)          // 吸附 A，开始截图
        let gB = c.beginSnap(windowID: 200)          // 用户手快，改吸附 B
        XCTAssertTrue(c.accept(image(tag: 22), windowID: 200, generation: gB))

        // A 的截图现在才回来
        XCTAssertFalse(c.accept(image(tag: 11), windowID: 100, generation: gA),
                       "A 的迟到结果必须被丢弃")
        XCTAssertEqual(tag(of: c.currentShapeImage!), 22, "手上必须还是 B 的图")
    }

    func test同一窗口的旧代际结果也要丢() {
        // 同一个窗口反复吸附（框选→重选→再吸附同一个），只认最后一次
        let c = WindowShapeCoordinator()
        let old = c.beginSnap(windowID: 7)
        let new = c.beginSnap(windowID: 7)
        XCTAssertFalse(c.accept(image(tag: 11), windowID: 7, generation: old),
                       "窗口 ID 相同但代际过期，同样是迟到结果")
        XCTAssertTrue(c.accept(image(tag: 22), windowID: 7, generation: new))
        XCTAssertEqual(tag(of: c.currentShapeImage!), 22)
    }

    func test截图返回nil不写入() {
        let c = WindowShapeCoordinator()
        let g = c.beginSnap(windowID: 1)
        XCTAssertFalse(c.accept(nil, windowID: 1, generation: g))
        XCTAssertNil(c.currentShapeImage)
    }

    // MARK: - 失效路径

    func test重新框选后_在途结果作废() {
        let c = WindowShapeCoordinator()
        let g = c.beginSnap(windowID: 1)
        c.invalidate()                                 // 用户改成自由框选
        XCTAssertFalse(c.accept(image(tag: 11), windowID: 1, generation: g))
        XCTAssertNil(c.currentShapeImage)
        XCTAssertNil(c.windowID)
    }

    func test关闭overlay后_任何结果都不再收() {
        let c = WindowShapeCoordinator()
        let g = c.beginSnap(windowID: 1)
        c.close()
        XCTAssertFalse(c.accept(image(tag: 11), windowID: 1, generation: g))
        // 关闭后即便再开一轮也不收——overlay 已经没了，写进去只是内存垃圾
        let g2 = c.beginSnap(windowID: 1)
        XCTAssertFalse(c.accept(image(tag: 11), windowID: 1, generation: g2))
    }

    // MARK: - 导出取图的判据

    func test取图必须ID匹配_不是有图就用() {
        let c = WindowShapeCoordinator()
        let g = c.beginSnap(windowID: 5)
        c.accept(image(tag: 33), windowID: 5, generation: g)

        XCTAssertNotNil(c.shapeImage(for: 5))
        XCTAssertNil(c.shapeImage(for: 6), "换个窗口问，就不该给图")
        XCTAssertNil(c.shapeImage(for: nil))
    }

    func test代际前进后_旧图不再被取出() {
        let c = WindowShapeCoordinator()
        let g = c.beginSnap(windowID: 5)
        c.accept(image(tag: 33), windowID: 5, generation: g)
        c.beginSnap(windowID: 5)   // 同窗口重新吸附，代际+1
        XCTAssertNil(c.shapeImage(for: 5), "代际对不上就当没有，宁可重截一次")
    }
}
