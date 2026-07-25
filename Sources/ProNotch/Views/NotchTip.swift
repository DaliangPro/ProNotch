import SwiftUI

/// 气泡弹出方向。刘海顶部那排按钮往下弹够用；贴着面板底部的控件（如闪问输入栏的图标）
/// 只能往上弹，且要与按钮左对齐——居中的长气泡会甩出面板左边缘
enum NotchTipEdge {
    /// 控件下方居中
    case below
    /// 控件上方、左边缘对齐
    case aboveLeading
}

/// 悬停中文提示气泡：刘海是后台非激活面板（LSUIElement），原生 .help 的 tooltip
/// 只在所属 App 处于激活态时才弹，这里用不了——故自绘，在控件旁渲染。
struct NotchTip: ViewModifier {
    let text: String
    let edge: NotchTipEdge
    @State private var show = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                task?.cancel()
                if hovering {
                    task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)   // 悬停约 0.6s 才弹
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) { show = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { show = false }
                }
            }
            .overlay(alignment: edge == .below ? .top : .bottomLeading) {
                if show {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                        )
                        // 都是「让开控件本身」：往下弹让过 31pt 高的按钮，往上弹让过图标加间距
                        .offset(y: edge == .below ? 32 : -22)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(999)
                }
            }
    }
}

extension View {
    /// 悬停约 0.6s 后弹出中文气泡说明（纯图标按钮用，告诉用户图标是干嘛的）
    func notchTip(_ text: String, edge: NotchTipEdge = .below) -> some View {
        modifier(NotchTip(text: text, edge: edge))
    }
}
