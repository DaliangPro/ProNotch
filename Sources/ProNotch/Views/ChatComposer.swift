import SwiftUI
import AppKit

/// 闪问输入区的**共享判据与零件**。
///
/// 由来（大梁老师 2026-08-08）：输入区在代码里有两份实现——刘海的 `inputBar`
/// 与独立窗的 `windowComposer`。外壳本就该不一样（刘海方角贴边、窗里圆角浮层，
/// 字号行数也不同），可「附件条显示什么」「开关开着关着怎么解释」
/// 「回车算换行还是发送」这些本该一样的东西也各写了一份，一天之内漏了三次：
/// 附件条只写进刘海那份（截图问 AI 打开的偏偏是独立窗，等于必然踩空）、
/// ⇧回车换行只落在独立窗那份、改完换行行为占位符文案又没跟上。
///
/// 所以这里只收「本该一样」的部分。长得不一样的不合并——
/// 把两种外观塞进一个带一堆开关参数的组件，只会比现在更难改
enum ChatComposer {

    // MARK: - 判据

    /// 回车是换行还是发送：**⌘回车与 ⇧回车都换行**（大梁老师 2026-07-31 定「两个都支持」），
    /// 其余情况落给 `onSubmit` 发送。系统自带的 ⌥回车走 AppKit 原生路径，不经过这儿
    static func isNewlineShortcut(_ modifiers: EventModifiers) -> Bool {
        modifiers.contains(.command) || modifiers.contains(.shift)
    }

    /// 这条草稿能不能发出去。两边发送键的禁用态都读它——
    /// 判据散在各处的话，将来改口径（比如「只挂了图没打字也允许发」）就得记得改全
    static func canSend(draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 文案

    /// 刘海输入框的占位符：**操作说明写在这儿**，刘海里没别处放提示。
    /// 键位改了这句必须跟着改——上一次就是改完 `isNewlineShortcut` 忘了它，
    /// 文案还写着「⌘回车换行」，比行为落后了一轮
    static let notchPlaceholder = "输入问题，回车发送 · ⇧/⌘回车换行"

    /// 独立窗的占位符：窗里空间大、控件各自带中文标签，不必再挤操作说明
    static let windowPlaceholder = "问点什么…"

    /// 联网 / 深度思考这两个随手开关的共享说明。
    ///
    /// 两边长相不同（刘海是一个光图标，窗里是带中文的胶囊），
    /// 但**叫什么、开着关着分别意味着什么**该是同一套话。
    /// 原先窗里那套是 `"\(title)已开启（点击关闭）"`，等于什么都没解释
    struct ToolToggle {
        let title: String
        let onHint: String
        let offHint: String

        func hint(on: Bool) -> String { on ? onHint : offHint }

        static let webSearch = ToolToggle(
            title: "联网",
            onHint: "联网搜索已开启：先搜索再回答（点击关闭）",
            offHint: "联网搜索已关闭：只用模型自身知识（点击开启）")

        /// 深度思考：DeepSeek v4 这类混合模型默认先想一轮，闲聊问答用不上，关掉明显更快
        static let thinking = ToolToggle(
            title: "深度思考",
            onHint: "深度思考已开启：模型先推理再作答，更准也更慢（点击关闭）",
            offHint: "深度思考已关闭：直接作答，更快（点击开启）")
    }

    // MARK: - 附件条

    /// 待发截图的附件条：缩略图 + 说明 + 移除。
    ///
    /// 两处只差尺寸档：刘海要挤进一行控件里，压扁、只留四个字；
    /// 独立窗有整行地方，图放大些、补一句「随下一条消息一起发给模型」。
    /// 摆在哪儿由调用方决定（刘海排在输入框左边，独立窗摞在输入框上方）——
    /// 那是布局，不是这个零件该管的事
    struct AttachmentBar: View {
        let image: NSImage
        /// 刘海用紧凑档
        var compact = false
        let remove: () -> Void

        private var thumbSize: CGSize {
            compact ? CGSize(width: 40, height: 30) : CGSize(width: 54, height: 40)
        }

        private var corner: CGFloat { compact ? 4 : 5 }

        var body: some View {
            HStack(spacing: compact ? 6 : 8) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(ChatWindowPalette.border, lineWidth: 0.5))
                if compact {
                    Text("已附截图").font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("已附截图").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("随下一条消息一起发给模型").font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                // 不放 Spacer：卡片收缩到内容宽度，× 紧跟文字。铺满整宽的话
                // 删除键会被推到最右边，离「已附截图」十万八千里，看不出是在删这个
                removeButton
            }
            .padding(compact ? 0 : 5)
            .background {
                // 刘海那档不上底：它本来就嵌在输入框那一行里，再叠一层底就成了框中框
                if !compact {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ChatWindowPalette.surface2)
                }
            }
        }

        @ViewBuilder
        private var removeButton: some View {
            Button(action: remove) {
                if compact {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.quaternary))
                }
            }
            .buttonStyle(.plain)
            .notchTip("移除截图", edge: .aboveLeading)
            .accessibilityLabel("移除截图")
        }
    }
}
