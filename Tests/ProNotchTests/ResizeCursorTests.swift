import XCTest
import AppKit
@testable import ProNotch

/// 对角调整光标不再走私有 AppKit selector。
///
/// 病灶：原实现 `NSCursor.perform(NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))`。
/// 私有 API 没有兼容性承诺——改名就静默退化成上下箭头，改返回类型就更难说；
/// 上架审核也会因此被拒。
@MainActor
final class ResizeCursorTests: XCTestCase {

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    // MARK: - 自绘位图

    func test两个方向都画得出图() throws {
        for axis in [DiagonalResizeCursor.Axis.nwse, .nesw] {
            let image = DiagonalResizeCursor.image(for: axis)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
            let rep = try bitmap(image)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            XCTAssertGreaterThan(rep.pixelsHigh, 0)
        }
    }

    func test箭头确实沿着各自的对角线() throws {
        // colorAt 的 y 从顶边往下数，与绘制时的坐标系上下相反
        let nwse = try bitmap(DiagonalResizeCursor.image(for: .nwse))
        let nesw = try bitmap(DiagonalResizeCursor.image(for: .nesw))
        let w = nwse.pixelsWide, h = nwse.pixelsHigh
        let near = max(2, w / 12)

        // ↖↘：左上、右下有料；左下、右上是空的
        XCTAssertGreaterThan(alpha(nwse, near, near), 0.5, "左上角该有箭头")
        XCTAssertGreaterThan(alpha(nwse, w - 1 - near, h - 1 - near), 0.5, "右下角该有箭头")
        XCTAssertLessThan(alpha(nwse, near, h - 1 - near), 0.1, "左下角不该有东西")
        XCTAssertLessThan(alpha(nwse, w - 1 - near, near), 0.1, "右上角不该有东西")

        // ↗↙：正好相反
        XCTAssertGreaterThan(alpha(nesw, near, h - 1 - near), 0.5, "左下角该有箭头")
        XCTAssertGreaterThan(alpha(nesw, w - 1 - near, near), 0.5, "右上角该有箭头")
        XCTAssertLessThan(alpha(nesw, near, near), 0.1, "左上角不该有东西")
        XCTAssertLessThan(alpha(nesw, w - 1 - near, h - 1 - near), 0.1, "右下角不该有东西")
    }

    func test中心不透明_热点落在实处() throws {
        for axis in [DiagonalResizeCursor.Axis.nwse, .nesw] {
            let rep = try bitmap(DiagonalResizeCursor.image(for: axis))
            XCTAssertGreaterThan(alpha(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2), 0.5,
                                 "热点取的是正中，那儿必须是箭头本体")
        }
    }

    func test有白填充也有黑描边_压在任何底色上都看得见() throws {
        let rep = try bitmap(DiagonalResizeCursor.image(for: .nwse))
        var sawLight = false, sawDark = false
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9,
                      let rgb = c.usingColorSpace(.deviceRGB) else { continue }
                if rgb.brightnessComponent > 0.9 { sawLight = true }
                if rgb.brightnessComponent < 0.2 { sawDark = true }
            }
        }
        XCTAssertTrue(sawLight, "白色填充：压在深色截图上靠它")
        XCTAssertTrue(sawDark, "黑色描边：压在浅色截图上靠它")
    }

    func test两个方向的图不一样() throws {
        XCTAssertNotEqual(DiagonalResizeCursor.image(for: .nwse).tiffRepresentation,
                          DiagonalResizeCursor.image(for: .nesw).tiffRepresentation,
                          "两条对角线要是画成一样的，四角反馈就等于没做")
    }

    // MARK: - 光标对象

    func test取得到光标且两个方向不是同一个() {
        let nwse = DiagonalResizeCursor.cursor(for: .nwse)
        let nesw = DiagonalResizeCursor.cursor(for: .nesw)
        XCTAssertGreaterThan(nwse.image.size.width, 0)
        XCTAssertGreaterThan(nesw.image.size.width, 0)
        XCTAssertFalse(nwse === nesw)
    }

    func test重复取用同一个光标实例() {
        // resetCursorRects 每次鼠标移动都可能触发，不能每次重画一张图
        XCTAssertTrue(DiagonalResizeCursor.cursor(for: .nwse)
                        === DiagonalResizeCursor.cursor(for: .nwse))
    }

    func test不再回退成上下调整光标() {
        // 老实现取不到私有光标时退化成 .resizeUpDown——四角和上下边反馈一样，等于没反馈
        XCTAssertFalse(DiagonalResizeCursor.cursor(for: .nwse) === NSCursor.resizeUpDown)
        XCTAssertFalse(DiagonalResizeCursor.cursor(for: .nesw) === NSCursor.resizeUpDown)
    }

    // MARK: - 私有 API 回潮守卫

    func test全仓源码不含私有selector调用() throws {
        // 光验当前这处不够——这条守着的是「以后谁也别再加回来」
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ProNotchTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // 仓库根
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 20, "没扫到源码文件的话这条测试等于空转")

        for name in files {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("_windowResize"), "\(name) 又用上私有光标 selector 了")
            XCTAssertFalse(text.contains("NSSelectorFromString"),
                           "\(name) 出现 NSSelectorFromString——私有 API 通常从这里进来")
        }
    }
}
