import SwiftUI

/// 闪问独立窗口的配色（任务书 §5.1 的 Design Token）。
///
/// 收成一处的理由：之前窗口底、输入块、气泡、下拉、来源面板各写各的字面量，
/// 改一档底色就要满文件找，还容易漏——实际就漏过（底色改黑之后来源面板比底还深）。
///
/// 整套只有一个自由变量：`background`。其余各层都从它往上推一档一档提亮，
/// 所以换底色时层级关系自动成立，不会出现「某一块比背景还暗」
enum ChatWindowPalette {

    /// 窗口主背景。大梁老师 2026-07-31：纯黑太硬，要灰一点。
    /// 可写＝离屏渲染要拿几档灰出图给他挑；生产运行期不改
    static var background = Color(white: 0.118)

    /// 背景的灰度值，供下面各层推导
    private static var base: Double = 0.118

    static func setBackground(white: Double) {
        base = white
        background = Color(white: white)
    }

    /// 输入区、下拉菜单：比底亮一档
    static var surface1: Color { Color(white: base + 0.055) }
    /// 用户气泡、悬停表面：再亮一档
    static var surface2: Color { Color(white: base + 0.085) }
    /// 来源面板：比底略亮一点点，是「嵌在正文里的块」而不是浮层
    static var surfaceInset: Color { Color(white: base + 0.03) }

    static let border = Color.white.opacity(0.10)
    static let divider = Color.white.opacity(0.07)
}
