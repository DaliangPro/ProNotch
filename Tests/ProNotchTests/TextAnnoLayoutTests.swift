import XCTest
import AppKit
@testable import ProNotch

/// 截图文字标注的排版闸门（大梁老师 2026-08-07：「无论任何字号都不要有 bug，现在有吞字的情况」）。
///
/// 「吞字」＝量框与画字用了两套排版：量出来的框差一点点，最后一个字被挤到下一行再被裁掉。
/// 这里用两条独立于 TextAnnoLayout 自身的路子验证「框一定装得下字」：
/// ① NSLayoutManager 真排一遍拿 usedRect（另一套 TextKit 路径，非自证）；
/// ② 离屏渲染两次——按量出的框画一次、把框加高一大截再画一次，比较着墨像素数，
///    少一个点都说明被裁了。
@MainActor
final class TextAnnoLayoutTests: XCTestCase {

    /// 覆盖三档字号 + 超大字号，以及中文/长英文单词/中英混排/多行/表情
    private let sizes: [CGFloat] = [14, 18, 24, 36, 48]
    private let samples = [
        "重点看这里",
        "A",
        "Supercalifragilisticexpialidocious",
        "这段是中英混排 mixed content 的标注文字",
        "第一行文字\n第二行更长一些的文字内容",
        "先看这里 👉 再看那边",
        "这是一段足够长的说明文字，长到必须换行才放得下，用来验证多行排版不会把末行吃掉"
    ]

    /// ① 独立路径校验：TextKit 真排一遍，用到的宽高必须都在量出的框以内
    func test任何字号量出的框都装得下真实排版() {
        for size in sizes {
            for text in samples {
                let box = TextAnnoLayout.size(text, fontSize: size)
                let inner = NSSize(width: box.width - TextAnnoLayout.padX * 2,
                                   height: box.height - TextAnnoLayout.padY * 2)
                let used = Self.layoutUsedSize(text, fontSize: size,
                                               wrapWidth: TextAnnoLayout.maxWidth(for: size) - TextAnnoLayout.padX * 2)
                XCTAssertLessThanOrEqual(used.width, inner.width + 0.5,
                                         "字号 \(size)「\(text)」量出的框比真实排版还窄，右边会被裁")
                XCTAssertLessThanOrEqual(used.height, inner.height + 0.5,
                                         "字号 \(size)「\(text)」量出的框比真实排版还矮，末行会被吃掉")
            }
        }
    }

    /// ② 离屏渲染校验：按量出的框画，与加高 200pt 再画，着墨像素数必须一致（一致＝没裁）
    func test任何字号渲染都不被裁掉() {
        for size in sizes {
            for text in samples {
                let box = TextAnnoLayout.size(text, fontSize: size)
                let tight = Self.inkPixels(text, fontSize: size, box: box, extraHeight: 0)
                let loose = Self.inkPixels(text, fontSize: size, box: box, extraHeight: 200)
                XCTAssertGreaterThan(tight, 0, "字号 \(size)「\(text)」一个像素都没画出来")
                XCTAssertEqual(tight, loose, "字号 \(size)「\(text)」被框裁掉了字（少了 \(loose - tight) 个着墨像素）")
            }
        }
    }

    /// 换行宽度随字号放大：固定 220 的话 24pt 一行只放得下七八个字
    func test换行宽度随字号放大() {
        XCTAssertEqual(TextAnnoLayout.maxWidth(for: 14), 220)
        XCTAssertGreaterThan(TextAnnoLayout.maxWidth(for: 24), TextAnnoLayout.maxWidth(for: 18))
        XCTAssertGreaterThan(TextAnnoLayout.maxWidth(for: 18), TextAnnoLayout.maxWidth(for: 14))
    }

    /// 空文字按占位符量框：刚点出来时「输入文字…」不能被裁
    func test空文字按占位符量框() {
        for size in sizes {
            let empty = TextAnnoLayout.size("", fontSize: size)
            let holder = TextAnnoLayout.size(TextAnnoLayout.placeholder, fontSize: size)
            XCTAssertEqual(empty, holder, "字号 \(size) 空框应按占位符量")
        }
    }

    /// 字号越大框越大（防止哪天把 fontSize 漏传成固定值——那正是旧实现犯的错）
    func test字号越大框越大() {
        for text in samples {
            let small = TextAnnoLayout.size(text, fontSize: 14)
            let big = TextAnnoLayout.size(text, fontSize: 24)
            XCTAssertGreaterThan(big.height, small.height, "「\(text)」24pt 的框不该比 14pt 矮")
        }
    }

    // MARK: - 工具

    /// 另一套 TextKit 路径量出的实际占用尺寸：逐行取行片段的 usedRect 求并集。
    /// 不直接用 `usedRect(for:)`——它会把末尾光标那条「整条容器宽」的额外行片段算进去
    private static func layoutUsedSize(_ text: String, fontSize: CGFloat, wrapWidth: CGFloat) -> NSSize {
        let storage = NSTextStorage(string: text, attributes: TextAnnoLayout.attrs(fontSize: fontSize, color: .white))
        let container = NSTextContainer(size: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var union = NSRect.zero
        var first = true
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
            union = first ? used : union.union(used)
            first = false
        }
        return first ? manager.usedRect(for: container).size : union.size
    }

    /// 按给定框离屏画一次，数着墨像素（alpha > 0）。extraHeight 只向下加高，保持框顶与换行宽度不变
    private static func inkPixels(_ text: String, fontSize: CGFloat, box: NSSize, extraHeight: CGFloat) -> Int {
        let pad: CGFloat = 4
        let w = Int(ceil(box.width + pad * 2)), h = Int(ceil(box.height + extraHeight + pad * 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return -1 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // 框顶固定在上边缘下方 pad 处：加高只往下延伸，文字起点与换行点都不变
        let rect = NSRect(x: pad, y: CGFloat(h) - pad - box.height - extraHeight,
                          width: box.width, height: box.height + extraHeight)
        TextAnnoLayout.draw(text, in: rect, fontSize: fontSize, color: .white)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return -1 }
        var ink = 0
        let stride = rep.bytesPerRow, spp = rep.samplesPerPixel
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where data[y * stride + x * spp + 3] > 8 { ink += 1 }
        }
        return ink
    }
}
