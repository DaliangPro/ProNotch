import AppKit
import SwiftUI

/// 闪问「第一次」的预热。
///
/// 由来（大梁老师 2026-07-31）：解析/内联缓存上了之后回访个位数毫秒，
/// 但**第一次**呼出独立窗口、第一次切到刘海闪问页还是有点顿——
/// 第一次的账：缓存全冷（当前对话十几条消息的 Markdown 块解析 +
/// 每段 AttributedString(markdown:)）+ 独立窗口的面板整棵现造。
/// 这两笔都不依赖用户输入，启动后空闲时先付掉，首次呼出就只剩 orderFront。
///
/// 预热走**真实渲染路径**（MarkdownMessageView 按刘海/窗口两套排版各过一遍），
/// 缓存键与实际渲染天然一致，不存在「预热了却没命中」的口径漂移。
/// 刻意不用 ChatView 整页做预热：它的 onAppear 会装粘贴/滚轮监听、发连通性检查，
/// 预热的副本多装一套监听是真风险，MarkdownMessageView 是纯视图没有副作用
@MainActor
enum ChatPrewarm {

    /// 预热当前对话最近一段的解析与内联缓存（刘海 + 窗口两套排版），
    /// 并把独立窗口的面板提前建好。启动后空闲时调一次；量级：几十毫秒，一次性
    static func warm(chat: ChatStore) {
        // 与两处渲染完全同参：刘海限 12 条（ChatView.defaultShownLimit(inNotch:)），
        // 窗口 40 条是它的超集，直接按窗口的量预热，刘海必然全命中
        let recent = chat.messages.suffix(ChatView.defaultShownLimit(inNotch: false))
        guard !recent.isEmpty else {
            ChatWindowController.shared.warmUp()
            return
        }
        // 排版参数照抄 MessageBubble.type：刘海 (12, compact)、窗口 (14, 舒适)。
        // 每套排版整棵 VStack 一次过（不是每条消息一棵树——那样 80 棵树 211ms，
        // 合并后 2 棵树实测便宜一半以上），两套之间隔一拍让路给用户事件
        let texts = recent.filter { $0.role == .assistant }.map(\.content)
        for (i, type) in [MarkdownTypography(body: 12, compact: true),
                          MarkdownTypography(body: 14, compact: false)].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                        MarkdownMessageView(text: text, type: type)
                    }
                }.frame(width: 600))
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 10)
                // 不进窗口、不上屏：只逼一次 body 求值与排版，把缓存焐热后即弃
                host.layoutSubtreeIfNeeded()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            ChatWindowController.shared.warmUp()
            AppLog.chat.info("闪问预热完成：\(texts.count, privacy: .public) 条消息 + 独立窗面板")
        }
    }
}
