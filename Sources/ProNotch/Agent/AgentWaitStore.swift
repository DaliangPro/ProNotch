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
}

/// 等待拍板提醒的状态层：一次挂一张卡，后来的排队等着。
///
/// 两种卡的停留规则不同：
/// - 只提醒一声的（别家的中途信号）停 8 秒自动收回，信号送到就够了；
/// - 能当场答复的（Claude Code 的授权请求）**一直挂着直到答复**（大梁老师定）——
///   它不是通知而是待办，自己消失就等于把待办悄悄扔了，而终端那头还在等。
///   随时可按「打开终端」脱身，不会真被一张卡钉住
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

    /// 停留时长。可注入只为测试：真等 8 秒会让用例慢得没法跑
    private let autoDismissAfter: TimeInterval
    private let broker: AgentPermissionBroker
    private var dismissTask: Task<Void, Never>?

    init(autoDismissAfter: TimeInterval = 8, broker: AgentPermissionBroker = AgentPermissionBroker()) {
        self.autoDismissAfter = autoDismissAfter
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
        if let host = notice.host, !host.isEmpty, host == frontmost, hostWindowVisible {
            // 要拍板的那种不能一声不响丢掉：不答复它，终端也不会弹框，整轮就那么干等着。
            // 得先把「照旧弹终端框」写回去，让用户在眼前那个终端里正常答
            release(notice)
            return
        }
        guard notice.id != self.notice?.id,
              !queued.contains(where: { $0.id == notice.id }) else { return }
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
        dismissTask?.cancel()
        dismissTask = nil
        // 能答复的那种不自动收（大梁老师定：一直等到答复）
        guard !notice.isAnswerable else { return }
        // 8 秒后自行收回：信号送到就够了，长期挂着会挡住刘海下方区域。
        // 错过了还有 Agent 页的会话卡可查
        dismissTask = Task { @MainActor [weak self] in
            guard let seconds = self?.autoDismissAfter else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // 期间换了另一条提醒就不越权收别人的卡
            if self?.notice == notice { self?.advance() }
        }
    }

    /// 换下一条：队列空了才真收卡
    private func advance() {
        dismissTask?.cancel()
        dismissTask = nil
        guard !queued.isEmpty else { notice = nil; return }
        show(queued.removeFirst())
    }
}
