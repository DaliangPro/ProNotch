import AppKit

/// 截图「输入文字」标注的排版单一事实源：量尺寸与画字用同一套参数。
///
/// 由来（大梁老师 2026-08-07：「无论任何字号都不要有 bug，现在有吞字的情况」）：
/// 旧实现里「量」和「画」是两套——量用输入框 layoutManager 的字形包围盒
/// （且新建时按固定 14pt 量，与实际字号无关），画用 `NSString.draw(in:)` 重新排一遍，
/// 两边的属性、换行宽度、行高来源都不一致。差之毫厘，最后一个字就被挤到下一行、
/// 再被框高裁掉——看起来就是「吞字」，且字号越大越容易犯。
///
/// 这里把两件事收进同一处：同一套 attributes、同一组 DrawingOptions、同一个换行宽度。
/// 只要都走这里，量出来的框就一定装得下画出来的字（构造上不可能对不齐）。
enum TextAnnoLayout {
    /// 文字四周内边距（与气泡同值，落定后位置与编辑态严丝合缝）
    static let padX: CGFloat = 10
    static let padY: CGFloat = 7
    /// 量与画必须同款：行片段原点排版 + 用字体自带行距
    static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    /// 14pt 时的换行宽度，其余字号按比例放大。
    /// 固定 220 的话 24pt 一行只放得下七八个字，被迫换行不算 bug 但很难用；
    /// 按字号缩放后，每行能放的字数在三档字号下大体一致
    static let baseMaxWidth: CGFloat = 220
    static let baseFontSize: CGFloat = 14
    /// 空文字时按占位符量框，保证刚点出来时占位符不被裁
    static let placeholder = "输入文字…"

    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    /// 投影：只为「从任意截图背景上分离出来」，不参与造型。
    ///
    /// 由来（大梁老师 2026-08-07：「文字的阴影显得文字太脏了」）：原来固定 blur 3 / alpha 0.45，
    /// 小字号时模糊半径已接近笔画本身的粗细，黑雾糊在红字外圈上——底越浅越脏。
    /// 改成随字号缩放：14pt 只有 1.3 的虚边（干净），48pt 才到 4.3（大字仍托得住），
    /// 同时把不透明度压到 0.22
    static let shadowAlpha: CGFloat = 0.22
    static let shadowOffsetY: CGFloat = -1
    static func shadowBlur(for fontSize: CGFloat) -> CGFloat { max(fontSize, 1) * 0.09 }

    static func maxWidth(for fontSize: CGFloat) -> CGFloat {
        (baseMaxWidth * max(fontSize, 1) / baseFontSize).rounded()
    }

    static func attrs(fontSize: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = .left
        p.lineBreakMode = .byWordWrapping
        return [.font: font(fontSize), .foregroundColor: color, .paragraphStyle: p]
    }

    /// 文字所需的整框尺寸（含内边距）
    static func size(_ text: String, fontSize: CGFloat) -> NSSize {
        let t = text.isEmpty ? placeholder : text
        let textMax = maxWidth(for: fontSize) - padX * 2
        let bound = (t as NSString).boundingRect(
            with: NSSize(width: textMax, height: .greatestFiniteMagnitude),
            options: options, attributes: attrs(fontSize: fontSize, color: .white))
        // 各 +1pt 安全余量：boundingRect 与真正绘制之间的亚像素舍入差，
        // 正是「最后一个字掉到下一行又被裁掉」的成因。宽度只多不少，不会多出换行
        return NSSize(width: ceil(bound.width) + 1 + padX * 2,
                      height: ceil(bound.height) + 1 + padY * 2)
    }

    /// 画字（屏上与导出共用）。传入整框，内部自己去掉内边距
    static func draw(_ text: String, in rect: NSRect, fontSize: CGFloat, color: NSColor) {
        guard !text.isEmpty else { return }
        (text as NSString).draw(with: rect.insetBy(dx: padX, dy: padY),
                                options: options,
                                attributes: attrs(fontSize: fontSize, color: color),
                                context: nil)
    }
}
