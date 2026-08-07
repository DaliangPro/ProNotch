import XCTest
import SwiftUI
@testable import ProNotch

/// 闪问正文的划词选中（大梁老师 2026-08-07：「我发出的文字和 AI 回复的文字都无法选中，
/// 那我就无法复制」）。
///
/// 正文改由 AppKit 的 `NSTextView` 承载，而不是加回 `.textSelection(.enabled)`——
/// 后者有把整扇窗卡死的前科（见 `MarkdownLite` 顶部注释）。
/// 这组测试钉住改造过程中实测踩到的两个坑，两个都只在离屏量尺寸时才现形
@MainActor
final class SelectableTextTests: XCTestCase {

    private func attr(_ text: String, size: CGFloat = 12) -> NSAttributedString {
        MarkdownLite.plainNS(text, size: size, weight: .regular, color: .white, lineSpacing: 1)
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// 一行放得下就一行，放不下才换行——高度得随给定宽度变
    func test高度随给定宽度换行() {
        let text = "折线有线宽，再小的日子也在曲线上有位置"
        let wide = height(SelectableText(attr(text)).frame(width: 300))
        let narrow = height(SelectableText(attr(text)).frame(width: 150))
        XCTAssertGreaterThan(wide, 0, "高度不能塌成 0")
        XCTAssertGreaterThan(narrow, wide, "窄一半应该多出一行")
    }

    /// 宽度未定时报的是**单行自然宽度**，不是容器宽度。
    ///
    /// 踩过的坑：原来拿 `.greatestFiniteMagnitude` 的容器去问 NSLayoutManager，
    /// 段落是 natural 对齐、占满容器，`usedRect` 把容器宽度原样报回来（实测 1e7）。
    /// SwiftUI 拿这个当理想宽度，HStack 里按比例一分，正文就被挤窄了
    func test宽度未定时报自然宽度而非容器宽度() {
        let host = NSHostingView(rootView: SelectableText(attr("折线有线宽")))
        host.layoutSubtreeIfNeeded()
        let width = host.fittingSize.width
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThan(width, 1000, "五个字不该报出上万的宽度（曾经是 1e7）")
    }

    /// 列表项的形状：符号 + 正文并排。正文必须吃满剩余宽度，
    /// 否则 300pt 宽里一行放得下的字会被断成两行（实测 31pt vs 15pt）
    func test列表项里的正文吃满剩余宽度() {
        let text = "折线有线宽，再小的日子也在曲线上有位置"
        func row<V: View>(@ViewBuilder _ body: () -> V) -> CGFloat {
            height(HStack(alignment: .top, spacing: 6) {
                Text("•").font(.system(size: 12))
                body()
            }.frame(width: 300, alignment: .leading))
        }
        let bare = row { SelectableText(self.attr(text)) }
        let filled = row { SelectableText(self.attr(text)).modifier(FillWidth()) }
        XCTAssertLessThan(filled, bare, "加了 FillWidth 才不会多断一行")
        XCTAssertEqual(filled, height(SelectableText(attr(text)).frame(width: 280)),
                       accuracy: 2, "满宽后应与单独限宽到同等可用宽度时一样高")
    }

    // MARK: - 属性映射

    /// 提问是所见即所得，不能被当成 Markdown 解析掉
    func test提问按纯文本渲染不吃掉星号() {
        let raw = "把 *这段* 改短一点"
        XCTAssertEqual(attr(raw).string, raw, "星号要原样留着")
    }

    /// AI 回复反过来要解析：`**粗**` 得真的变粗，星号本身不能留在屏幕上
    func test回复的加粗解析出来且变亮() {
        let out = MarkdownLite.inlineNS("很**重要**的事", size: 16,
                                        weight: .light, emphasisWeight: .semibold,
                                        base: .white.opacity(0.5), emphasis: .white)
        XCTAssertEqual(out.string, "很重要的事", "星号是标记，不该显示出来")
        let plain = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let strong = out.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(plain)
        XCTAssertNotEqual(plain, strong, "加粗段必须换字重，中文粗体本就含蓄")
    }

    /// 行内代码走等宽字体，否则 `let x = 1` 与正文糊成一片
    func test行内代码用等宽字体() {
        let out = MarkdownLite.inlineNS("值是 `x` 哦", size: 14)
        let index = out.string.distance(from: out.string.startIndex,
                                        to: out.string.firstIndex(of: "x")!)
        let font = out.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    /// 链接要带 .link，NSTextView 才认得出、点得开
    func test链接带上可点属性() {
        let out = MarkdownLite.inlineNS("见[文档](https://example.com)", size: 14)
        var found = false
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if value != nil { found = true }
        }
        XCTAssertTrue(found, "链接没进 .link 属性就成了纯文字")
    }

    /// 行距要真的落到段落样式上（正文 16 时行高目标 1.7 倍，见 MarkdownTypography）
    func test行距落进段落样式() {
        let out = MarkdownLite.inlineNS("一段话", size: 16, lineSpacing: 8)
        let style = out.attribute(.paragraphStyle, at: 0,
                                  effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.lineSpacing ?? 0, 8, accuracy: 0.01)
    }

    /// 同样的入参必须命中缓存拿到同一份成品——流式输出时每个 token 都会重来一遍，
    /// 不缓存的话一条长回答要把每个块重排上千次
    func test相同入参命中缓存() {
        MarkdownLite._resetRenderCachesForTests()
        let first = MarkdownLite.inlineNS("缓存测试", size: 14)
        let second = MarkdownLite.inlineNS("缓存测试", size: 14)
        XCTAssertTrue(first === second, "同一份成品应被复用")
        let other = MarkdownLite.inlineNS("缓存测试", size: 15)
        XCTAssertFalse(first === other, "字号不同是两个键，不能串味")
    }
}
