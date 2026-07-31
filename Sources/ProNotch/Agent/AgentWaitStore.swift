import Foundation
import Combine

/// 「Agent 跑到一半卡住等你拍板」的一条提醒。
///
/// 与「完成提醒」（Stop 钩子 → 光晕）是两件事：那个说的是「这轮跑完了」，
/// 这个说的是「它跑到一半弹了个框在等你选，你不理它就一直停在那」——
/// 大梁老师指出这种情况此前没有任何提示。
struct AgentWaitNotice: Equatable, Identifiable, Sendable {
    let source: AgentKind
    /// Claude 的 session_id / Kimi 同构字段。空串＝抓不到（脚本 sed 扑空），仍可弹卡只是点了跳不准
    let session: String
    /// hook 探测到的宿主 App bundle id（终端 / IDE / 桌面版），点卡跳转与前台不打扰都靠它
    let host: String?
    /// 项目名（cwd 末段）。抓不到时为空，卡面只显示 Agent 名
    let project: String
    /// 待拍板的授权请求。nil＝只是提醒一声，卡上只有「打开终端」。
    ///
    /// 只有 Claude Code 给得出：它的 `PermissionRequest` 钩子会等我们的答复，
    /// 别家的中途信号是发完就走的（见 `AgentKind.supportsPermissionCard`）
    let request: AgentPermissionRequest?

    /// 能不能当场答复（而不是只提醒一声）
    var isAnswerable: Bool { request != nil }

    /// 同一会话可以先后来好几条拍板请求，所以 id 得带上请求 id 才分得开
    var id: String { "\(source.rawValue)/\(session)/\(request?.id ?? "")" }

    init(source: AgentKind, session: String, host: String?, project: String,
         request: AgentPermissionRequest? = nil) {
        self.source = source
        self.session = session
        self.host = host
        self.project = project
        self.request = request
    }

    /// 项目名从 hook 传来时是 base64url（无补位）编码的。
    ///
    /// 目录名可以带空格和中文，裸拼进 query 会在 `open` 或 URLComponents 那一关散架；
    /// 而 base64 原生的 `+ / =` 又都是 query 里的敏感字符，所以脚本那边换成了 `- _` 并去掉补位，
    /// 这里补回来再解。解不出就当没有——卡面退化成只显示 Agent 名，不至于整条提醒作废
    static func decodeProject(_ encoded: String) -> String {
        guard !encoded.isEmpty else { return "" }
        var s = encoded.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 哪些通知值得打扰用户。
///
/// Claude Code 把好几件事混在同一个 `Notification` 钩子里发，只有「真的在等你做决定」
/// 那几种该弹卡（`notification_type` 取值系扫本机二进制实测所得）：
/// - `permission_prompt`：工具授权对话框（要不要允许跑这条命令）
/// - `elicitation_dialog` / `elicitation_url_dialog`：跳选项让你选
///
/// 明确**不弹**的：`idle_prompt` 只是你 60 秒没打字，不是它在等你选；
/// `auth_success` 之类更无关。
///
/// 判定放在应用侧而不是 hook 脚本里：这份名单以后要增减，改 Swift 不必让用户重装 hook；
/// 而且 shell 里的字符串匹配写不了测试
enum AgentWaitPolicy {
    static let notifyingTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
    ]

    /// 类型抓空时放行：别家 Agent 的同类事件未必有这个字段，
    /// 而它们的 Notification 本来就只在等你时发——宁可多提醒一次，也别整家都漏掉
    static func shouldNotify(type: String) -> Bool {
        type.isEmpty || notifyingTypes.contains(type)
    }

    /// 一扇窗里装多个会话的宿主。
    ///
    /// 「前台不打扰」的前提是「宿主在前台 ＝ 你正看着这个会话」。这条在终端上成立
    /// （一个窗口一个会话），在这些宿主上不成立：你可能正在**同一个 App 的另一个对话**里，
    /// 而提醒被当成「你看见了」吞掉（2026-07-29 大梁老师反馈的正是这一幕——我弹出选项，
    /// 刘海一声不响，因为他在另一个 Claude 对话窗口）。
    ///
    /// 而且这个粒度做不细：切对话是在**同一扇窗里**切的，窗里是哪个对话属于 App 内部状态，
    /// 任何系统 API 都拿不到。既然无从分辨，就按 `AgentHostVisibility` 已经定下的方向走——
    /// 判错只是多提醒一次（卡 8 秒自收、又在屏幕最顶端不遮内容），
    /// 反过来是把该弹的卡悄悄吞掉
    static let multiSessionHosts: Set<String> = [
        "com.anthropic.claudefordesktop",   // Claude 桌面版：一扇窗，侧栏切会话
    ]

    /// 该不该把这条信号放回宿主自己弹，也就是「前台不打扰」生效（纯函数，可测）。
    ///
    /// 三个条件缺一不可：宿主已知、它正是最前台的 App、它的窗确实压在最上层。
    /// 再加一道——它不能是多会话宿主（理由见 `multiSessionHosts`）
    static func shouldReleaseToHost(host: String?, frontmost: String?, hostWindowVisible: Bool) -> Bool {
        guard let host, !host.isEmpty, host == frontmost, hostWindowVisible else { return false }
        return !multiSessionHosts.contains(host)
    }

    /// 本身就是「找你确认」的工具。它们照样会触发 `PermissionRequest`（那个钩子不分工具），
    /// 但把它们摆到卡上是空转一轮：
    ///
    /// 大梁老师实测到的正是这一幕——我要问他版本号定哪个，刘海却弹出「允许一次 / 不再询问」。
    /// 按「允许」只是允许它把问题显示出来，真正的选项（2.3.0 还是 2.2.2）在窗口里，
    /// 卡上摆不出来（卡渲染的是权限建议，不是问题本身的选项）；而「不再询问」在这里的意思是
    /// 「以后都允许我问你话」，更容易被当成答案。
    ///
    /// 所以这类请求直接放回窗口正常问，刘海只提醒一声「它在等你选」。
    /// 名单放在 Swift 而不是钩子的 matcher 里：以后加新工具改这里就行，不必让用户重装钩子
    static let selfPromptingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// 这个工具的授权请求能不能摆到卡上当场答
    static func canAnswerOnCard(tool: String) -> Bool {
        !selfPromptingTools.contains(tool)
    }

    /// 「去宿主那儿处理」按钮的标题。
    ///
    /// 写死「打开终端」是不对的：同一个 Claude Code 可能跑在终端里，也可能是桌面版 App，
    /// 按钮说「打开终端」而实际跳到桌面版，人会以为按错了（大梁老师 2026-07-31）。
    /// 名字取不到时仍退回「打开终端」——绝大多数 Agent 确实跑在终端里，这个兜底不离谱
    static func openHostTitle(appName: String?) -> String {
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "打开终端" : "打开" + name
    }
}

/// 等待拍板提醒的状态层：一次挂一张卡，后来的排队等着。
///
/// **卡一律挂着，点掉才收**（大梁老师 2026-07-31 重申）。
///
/// 曾经分成两档：能当场答的常驻，答不了的停 8 秒自收。但这个分档站不住——
/// 进这个 store 的每一条都是「某个 Agent 在等你」，区别只在于**能不能在卡上直接答**，
/// 而不在于「要不要你回应」。答不了的（比如 AskUserQuestion，选项在窗口里、卡上摆不出来）
/// 同样是待办，自己消失就等于把待办悄悄扔了，人回头一看什么都没有
/// ——这正是大梁老师说「怎么又没提醒」的成因。
///
/// 答不了的那张卡点一下＝收卡并跳到宿主 App 去处理，所以常驻不会真把人钉住
///
/// 只存内存不落盘：这是个「此刻」的信号，重启后那个对话框早就不在原样了，
/// 恢复出来只会误导人（重启时还挂着的请求由 `AgentPermissionBroker.releaseOrphans` 放行）
@MainActor
final class AgentWaitStore: ObservableObject {

    /// 当前要弹的卡。nil＝不弹
    @Published private(set) var notice: AgentWaitNotice?

    /// 排在后面的。同时来两条很常见：两个终端各跑一个 Claude Code。
    /// 一条一条来，答完自动换下一条——四个按钮的卡摞在一起是按不准的
    @Published private(set) var queued: [AgentWaitNotice] = []

    private let broker: AgentPermissionBroker

    init(broker: AgentPermissionBroker = AgentPermissionBroker()) {
        self.broker = broker
    }

    /// 收到「等你拍板」信号。
    ///
    /// 前台不打扰要**两条同时成立**才算「你正盯着那个框」：
    /// `frontmost`（最前台 App 的 bundle id）等于宿主，且 `hostWindowVisible`
    /// ——那个宿主真有一扇窗压在最上层（由 `AgentHostVisibility` 判）。此时不弹，刘海再弹纯属添乱。
    ///
    /// 只看最前台是不够的：桌面版的授权框长在窗口**里面**，窗口被压住或被最小化时你同样看不见，
    /// 那种情况必须弹（大梁老师定）。完成光晕那条仍是宽口径，不与这里同步——
    /// 宿主已在最前台时点亮的光晕等不到「切回它」的激活事件，会永远熄不掉（见 `GlowController`）。
    ///
    /// 两件事都取参而不在内部读 NSWorkspace / CGWindowList，是为了让这条规则可测；
    /// `hostWindowVisible` 默认 true，让不关心窗口层级的调用方（离屏预览、用例）保持原判定
    func present(_ notice: AgentWaitNotice, frontmost: String?, hostWindowVisible: Bool = true) {
        if AgentWaitPolicy.shouldReleaseToHost(host: notice.host, frontmost: frontmost,
                                               hostWindowVisible: hostWindowVisible) {
            // 要拍板的那种不能一声不响丢掉：不答复它，终端也不会弹框，整轮就那么干等着。
            // 得先把「照旧弹终端框」写回去，让用户在眼前那个终端里正常答
            AppLog.glow.debug("等你拍板：宿主 \(notice.host ?? "-", privacy: .public) 就在眼前，放回它自己弹")
            release(notice)
            return
        }
        guard notice.id != self.notice?.id,
              !queued.contains(where: { $0.id == notice.id }) else {
            AppLog.glow.debug("等你拍板：同一条信号重复送达，忽略")
            return
        }
        // 这条链路原先从头到尾一行日志都没有，于是「提醒到底响没响」根本无从追查
        // ——2026-07-29 排这个问题只能靠读代码加扒 Claude 二进制。补上
        AppLog.glow.debug("等你拍板：挂卡 \(notice.source.rawValue, privacy: .public) 宿主 \(notice.host ?? "-", privacy: .public) 可答复 \(notice.isAnswerable, privacy: .public)")
        guard let current = self.notice else { show(notice); return }
        // 只提醒一声的那种可以互相顶掉：最新那条才是此刻在等你的，攒着轮播没意义。
        // 但绝不许顶掉一张能拍板的卡——那是待办，终端那头正卡着等答复
        if !notice.isAnswerable, !current.isAnswerable { show(notice); return }
        queued.append(notice)
    }

    /// 卡上按了某个按钮：写回答复，换下一条
    func answer(_ decision: AgentPermissionDecision) {
        guard let current = notice else { return }
        if let request = current.request, !broker.answer(request, decision) {
            // 写不进去（盘满 / 目录被删）时脚本会继续等，直到 hook 自己超时。
            // 这里除了留一条线索没别的能做——重试同样会失败
            AppLog.glow.error("拍板答复写入失败：\(current.source.rawValue, privacy: .public) \(decision.logLabel, privacy: .public)")
        }
        advance()
    }

    /// 手动收回（点了卡去处理、或视图侧要求关闭）。
    /// 要拍板的那种「收回」不能只是消失——终端那头还在等，得顺手放它走
    func dismiss() {
        guard let current = notice else { return }
        release(current)
        advance()
    }

    /// 放行成「照旧弹终端框」
    private func release(_ notice: AgentWaitNotice) {
        guard let request = notice.request else { return }
        broker.answer(request, .terminal)
    }

    private func show(_ notice: AgentWaitNotice) {
        self.notice = notice
    }

    /// 换下一条：队列空了才真收卡
    private func advance() {
        guard !queued.isEmpty else { notice = nil; return }
        show(queued.removeFirst())
    }
}
