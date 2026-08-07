import XCTest
import AppKit
@testable import ProNotch

/// 文字标注投影的口径（大梁老师 2026-08-07：「文字的阴影显得文字太脏了」）。
///
/// 脏的成因：原来固定 blur 3 / alpha 0.45，14pt 时模糊半径已接近笔画本身粗细，
/// 黑雾直接糊在字的外圈上。改成随字号缩放 + 压低不透明度。
/// 这里用离屏渲染量「字外面被染黑了多少」，把结论钉死在像素上，不靠肉眼。
@MainActor
final class TextAnnoShadowTests: XCTestCase {

    func test小字号的投影半径远小于笔画粗细() {
        // 半粗体笔画粗细约为字号的 1/10 上下；投影虚边必须比它小，才不会糊住字
        XCTAssertLessThan(TextAnnoLayout.shadowBlur(for: 14), 1.5)
        XCTAssertEqual(TextAnnoLayout.shadowBlur(for: 14), 1.26, accuracy: 0.01)
    }

    func test投影随字号放大() {
        XCTAssertGreaterThan(TextAnnoLayout.shadowBlur(for: 48), TextAnnoLayout.shadowBlur(for: 24))
        XCTAssertGreaterThan(TextAnnoLayout.shadowBlur(for: 24), TextAnnoLayout.shadowBlur(for: 14))
    }

    /// 离屏实测：同一段字，新投影泼在白底上的墨量必须显著少于旧的 blur3/alpha0.45。
    /// 实测值 14pt 10258 → 3666（36%）、24pt 26189 → 12761（49%）；
    /// 阈值取 0.6 留出余量——旧参数原样回来就是 100%，一定会被拦下
    func test新投影在浅底上的灰雾远少于旧参数() {
        var ratios: [CGFloat: Double] = [:]
        for size in [CGFloat(14), 24] {
            let old = Self.smudge("重点看这里", fontSize: size, blur: 3, alpha: 0.45)
            let new = Self.smudge("重点看这里", fontSize: size,
                                  blur: TextAnnoLayout.shadowBlur(for: size), alpha: TextAnnoLayout.shadowAlpha)
            XCTAssertGreaterThan(old, 0)
            ratios[size] = Double(new) / Double(old)
            XCTAssertLessThan(ratios[size]!, 0.6,
                              "字号 \(size)：新投影的墨量没明显低于旧参数（旧 \(old) / 新 \(new)）")
        }
        // 随字号缩放的意义就在这：小字号受益最大——它才是当初「脏」得最厉害的那一档
        XCTAssertLessThan(ratios[14]!, ratios[24]!, "小字号的改善幅度应大于大字号，否则等于没按字号缩放")
    }

    /// 仍要留一点投影：全去掉的话，杂色照片底上红字会和背景糊在一起
    func test投影没有被去干净() {
        XCTAssertGreaterThan(TextAnnoLayout.shadowAlpha, 0.1)
        XCTAssertGreaterThan(Self.smudge("重点看这里", fontSize: 14,
                                         blur: TextAnnoLayout.shadowBlur(for: 14), alpha: TextAnnoLayout.shadowAlpha), 0)
    }

    // MARK: - 工具

    /// 在纯白底上按给定投影画一次红字，量「字外面被泼掉的墨总量」＝Σ(白 − 实际亮度)。
    /// 用无投影渲染做掩膜排除字身，剩下的压暗全部来自投影。
    /// 之所以量墨量而不是数像素个数：大字号的投影半径本来就该大，被染面积大不等于脏；
    /// 脏＝面积 × 深度，墨量才是肉眼看到的那层灰
    private static func smudge(_ text: String, fontSize: CGFloat, blur: CGFloat, alpha: CGFloat) -> Int {
        let box = TextAnnoLayout.size(text, fontSize: fontSize)
        let pad: CGFloat = 12
        let w = Int(ceil(box.width + pad * 2)), h = Int(ceil(box.height + pad * 2))
        let red = NSColor(srgbRed: 1, green: 69 / 255.0, blue: 58 / 255.0, alpha: 1)

        func render(shadow: Bool) -> (px: [UInt8], stride: Int) {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return ([], 0) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)).fill()
            let rect = NSRect(x: pad, y: pad, width: box.width, height: box.height)
            if shadow {
                let s = NSShadow()
                s.shadowColor = NSColor.black.withAlphaComponent(alpha)
                s.shadowBlurRadius = blur
                s.shadowOffset = NSSize(width: 0, height: TextAnnoLayout.shadowOffsetY)
                s.set()
            }
            TextAnnoLayout.draw(text, in: rect, fontSize: fontSize, color: red)
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.bitmapData else { return ([], 0) }
            return (Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * h)), rep.bytesPerRow)
        }

        let bare = render(shadow: false), lit = render(shadow: true)
        guard bare.stride > 0, bare.px.count == lit.px.count else { return -1 }
        var smudged = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bare.stride + x * 4
                // 无投影时是纯白（＝字外面），有投影时被压暗 → 这就是灰雾
                let bareWhite = bare.px[i] > 250 && bare.px[i + 1] > 250 && bare.px[i + 2] > 250
                if bareWhite { smudged += max(0, 255 - Int(lit.px[i])) }
            }
        }
        return smudged
    }
}
