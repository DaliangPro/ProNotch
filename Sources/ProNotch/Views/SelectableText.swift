import AppKit
import SwiftUI

/// 可划词选中的只读文本。闪问的正文（提问与回答）都走它。
///
/// ## 为什么自己拿 AppKit 承载，而不是 `.textSelection(.enabled)`
///
/// SwiftUI 那个修饰符会把整扇闪问窗**卡死**——它装的 SelectionOverlay 在布局过程里
/// 走 `setFont` → `invalidateIntrinsicContentSize` → 又把布局标脏，
/// `GraphHost.flushTransactions()` 于是永远收敛不了（2026-07-31 两次采样实证，
/// 详见 `MarkdownLite` 顶部注释）。一条回答七八个块就是七八套这种覆盖视图。
///
/// 这里换成裸 `NSTextView`，并把 AppKit 自己的固有尺寸通道**焊死**（见
/// `NonReflowingTextView`）：尺寸只在 `sizeThatFits` 里**读**一次布局管理器算好的高度，
/// 全程不往回标脏，那条环的入口就不存在。
///
/// 不套 `NSScrollView`：滚动由外层 SwiftUI 的 ScrollView 负责，
/// 裸 TextView 的滚轮事件沿响应链上传，正好交给它
struct SelectableText: NSViewRepresentable {
    let attributed: NSAttributedString

    init(_ attributed: NSAttributedString) {
        self.attributed = attributed
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NonReflowingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false          // 只读展示，不接受粘贴进来的样式
        view.importsGraphics = false
        // 内边距归零：位置全由外层 SwiftUI 的 padding 决定，两处各留一份会对不齐
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        // 自动伸缩全关：高度是 sizeThatFits 算出来告诉 SwiftUI 的，不是 AppKit 自己长的
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        // 内容没变就不写：流式输出时每个 token 都会重建一次视图树，
        // 无条件 setAttributedString 会把用户刚拖出来的选区清掉
        guard view.textStorage?.isEqual(to: attributed) != true else { return }
        view.textStorage?.setAttributedString(attributed)
    }

    /// SwiftUI 问尺寸，我们**只读不写**：按给定宽度让布局管理器排一遍，回报实际用掉的尺寸。
    /// 这是整个方案的关键——量尺寸这件事必须发生在这里，
    /// 一旦挪进 `updateNSView` 里去改 frame，就又是「布局中改布局」。
    ///
    /// 宽度也要如实回报，不能一律占满：用户那条提问是右侧气泡，
    /// 按内容宽度收才对，返回 proposal 宽度会让每句话都拉成整行长条
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView,
                      context: Context) -> CGSize? {
        guard let container = nsView.textContainer,
              let manager = nsView.layoutManager else { return nil }
        // 宽度未定（.unspecified）＝「你理想多宽」。这里**不能**拿超宽容器去问布局管理器：
        // 段落是 natural 对齐，占满容器，`usedRect` 会把容器宽度原样报回来（实测 1e7）。
        // SwiftUI 拿这个数当理想宽度，在 HStack 里按比例分配就把正文挤成两行了
        //（实测：300pt 宽的列表项，一行放得下的字硬生生断成两行）。
        // 单行自然宽度得问 NSAttributedString 自己
        guard let width = proposal.width, width > 0, width.isFinite else {
            let natural = attributed.size()
            return CGSize(width: ceil(natural.width), height: ceil(natural.height))
        }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: min(ceil(used.width), width), height: ceil(used.height))
    }
}

/// 正文块专用：吃满外层给的宽度。
///
/// 不能省（离屏实测）：`SelectableText` 是 `NSViewRepresentable`，SwiftUI 在 HStack 里
/// 给它协商出的宽度会小于实际可用宽度——300pt 的列表项里，一行明明放得下的十九个字
/// 被断成了两行。声明「我要满宽」之后回到单行。
///
/// 用户那条提问**不加**：右侧气泡要按内容收窄，满宽会让每句话都拉成整行长条
struct FillWidth: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 固有尺寸通道被焊死的 TextView：高度只由 `SelectableText.sizeThatFits` 决定。
///
/// `invalidateIntrinsicContentSize` 空实现不是偷懒——那正是 `.textSelection`
/// 卡死环里的关键一跳（AppKit 在布局中把 SwiftUI 的布局标脏）。
/// 我们既然不靠固有尺寸摆位，就把这条路直接堵上
private final class NonReflowingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}

    /// 滚轮交给外层的 ScrollView。裸 TextView 不该自己消化滚动——
    /// 光标停在回答上滚不动页，是比不能选中更烦的毛病
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    /// 只读文本没有「插入点」，闪一根竖线会让人以为能在这儿打字
    override var shouldDrawInsertionPoint: Bool { false }
}

/// SwiftUI 的样式值翻成 AppKit 的。
///
/// 两套字重枚举没有公开转换，`NSAttributedString(AttributedString)` 也不搬
/// SwiftUI-only 的 `.font` / `.foregroundColor`——所以正文要走 AppKit 承载，
/// 就得在这里把度量重新落一遍。数值取自 `Font.Weight` 各档对应的 CSS 字重
enum AppKitTextStyle {
    static func font(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// 段落样式。`lineSpacing` 与 SwiftUI 的同名修饰符语义一致（默认行高之上再加）
    static func paragraph(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        // 长英文标识符（URL、函数签名）比一行还宽时按字符断，否则会顶出容器被裁掉
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        return style
    }
}
