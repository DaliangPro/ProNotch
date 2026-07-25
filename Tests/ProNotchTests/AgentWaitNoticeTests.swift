import XCTest
@testable import ProNotch

/// Agent「等你拍板」提醒：跑到一半弹了授权框 / 选项框在等你选时，刘海弹一张卡。
///
/// 这个提醒的价值全在「该弹时弹、不该弹时闭嘴」——弹得莫名其妙就是骚扰，
/// 用户第一反应是去设置里关掉它，那这个功能等于没做。所以这里钉三件事：
/// 类型过滤（不是所有通知都值得打断）、项目名解码（中文/空格不能变乱码）、
/// 前台不打扰与自动收回。
@MainActor
final class AgentWaitNoticeTests: XCTestCase {

    // MARK: - 类型过滤

    /// 值得打断的只有三种：授权框、选项框、带链接的选项框。
    /// 这个名单放在 Swift 而不是 shell 脚本里，就是为了改名单不用让用户重装钩子
    func test只有等你做决定的类型才提醒() {
        XCTAssertTrue(AgentWaitPolicy.shouldNotify(type: "permission_prompt"))
        XCTAssertTrue(AgentWaitPolicy.shouldNotify(type: "elicitation_dialog"))
        XCTAssertTrue(AgentWaitPolicy.shouldNotify(type: "elicitation_url_dialog"))
    }

    /// 空闲提醒（60 秒没说话就发）、完成通知、登录成功这些都不是「在等你拍板」，
    /// 尤其 `agent_completed` 已经有完成光晕在管，再弹一张卡就是弹两遍
    func test其余通知类型一律不弹() {
        for type in ["idle_prompt", "agent_completed", "agent_needs_input",
                     "auth_success", "push_notification", "computer_use_enter"] {
            XCTAssertFalse(AgentWaitPolicy.shouldNotify(type: type), "\(type) 不该弹卡")
        }
    }

    /// 别家 Agent（Kimi 同构事件）未必带 notification_type 字段，脚本 sed 会抓空。
    /// 抓空时放行：它既然发了这个事件，就是有事要说
    func test类型抓空时放行() {
        XCTAssertTrue(AgentWaitPolicy.shouldNotify(type: ""))
    }

    // MARK: - 项目名解码

    /// 项目名里有空格、中文、括号都很常见，直接拼进 URL 会被 open / URLComponents 打断，
    /// 所以脚本先 base64url 编码。解不回来就是卡面上一串乱码
    func test项目名base64url往返() {
        for name in ["ProNotch", "我的 项目", "app (v2)", "a+b/c", "日本語のプロジェクト"] {
            let data = Data(name.utf8)
            let encoded = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(AgentWaitNotice.decodeProject(encoded), name)
        }
    }

    func test项目名为空或解不出时退成空串() {
        XCTAssertEqual(AgentWaitNotice.decodeProject(""), "")
        XCTAssertEqual(AgentWaitNotice.decodeProject("!!!not-base64!!!"), "")
    }

    /// 脚本里 `base64 | tr -d '\n'` 偶有残留换行的余地，解出来不能带着空白进卡面
    func test解码后去掉首尾空白() {
        let encoded = Data(" ProNotch \n".utf8).base64EncodedString()
        XCTAssertEqual(AgentWaitNotice.decodeProject(encoded), "ProNotch")
    }

    // MARK: - 弹卡时机

    private func notice(host: String? = "com.apple.Terminal",
                        session: String = "s1",
                        project: String = "ProNotch") -> AgentWaitNotice {
        AgentWaitNotice(source: .claude, session: session, host: host, project: project)
    }

    /// 宿主终端就在你眼前时不弹：你正看着那个框，刘海再弹一张纯属添乱
    func test宿主在前台时不弹() {
        let store = AgentWaitStore()
        store.present(notice(), frontmost: "com.apple.Terminal")
        XCTAssertNil(store.notice)
    }

    func test宿主在后台时弹() {
        let store = AgentWaitStore()
        store.present(notice(), frontmost: "com.apple.Safari")
        XCTAssertEqual(store.notice?.session, "s1")
    }

    /// 宿主在最前台，但它的窗口不在眼前（全被最小化 / 被别的窗口压住）时照常弹。
    ///
    /// 桌面版的授权框长在应用窗口**里面**：看不见窗口就等于看不见那个框，
    /// 这时候把卡吞掉，用户看到的是「它明明在等我，却什么都没提示」（大梁老师报的正是这种）
    func test宿主在前台但窗口不在最上层时照常弹() {
        let store = AgentWaitStore()
        store.present(notice(), frontmost: "com.apple.Terminal", hostWindowVisible: false)
        XCTAssertEqual(store.notice?.session, "s1")
    }

    /// 宿主没探测到（hook 走 PPID 链扑空）时照常弹：宁可多弹一张，
    /// 也不要因为探测失败把提醒整个吞掉——吞掉就等于这个功能时好时坏
    func test宿主抓空时照常弹() {
        let store = AgentWaitStore()
        store.present(notice(host: nil), frontmost: "com.apple.Terminal")
        XCTAssertNotNil(store.notice)
        store.dismiss()
        store.present(notice(host: ""), frontmost: "com.apple.Terminal")
        XCTAssertNotNil(store.notice)
    }

    func test到时自动收回() async throws {
        let store = AgentWaitStore(autoDismissAfter: 0.05)
        store.present(notice(), frontmost: nil)
        XCTAssertNotNil(store.notice)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(store.notice, "8 秒自动收回是大梁老师定的停留方式，到时必须自己走")
    }

    /// 前一张的倒计时不能把后一张一起收掉：两条挨得近时（另一家也在等），
    /// 后一张刚弹出来就被前一张的定时器抹了，用户看到的是「闪一下就没了」
    func test新的一条重置倒计时() async throws {
        let store = AgentWaitStore(autoDismissAfter: 0.12)
        store.present(notice(session: "s1"), frontmost: nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        store.present(notice(session: "s2"), frontmost: nil)

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(store.notice?.session, "s2", "旧倒计时到点了，但不该带走新的一条")

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(store.notice, "新的一条自己也要按时收回")
    }

    func test手动收回后倒计时不再回来() async throws {
        let store = AgentWaitStore(autoDismissAfter: 0.05)
        store.present(notice(), frontmost: nil)
        store.dismiss()
        XCTAssertNil(store.notice)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(store.notice)
    }

    // MARK: - 能当场拍板的那张卡

    private var tmp: URL!

    /// 造一个落在临时目录的 store：答复要真写文件，不能往用户的 Application Support 里写
    private func answerableStore() throws -> AgentWaitStore {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wait-store-\(UUID().uuidString)")
        let paths = GlowHookPaths.rooted(at: tmp.path)
        try FileManager.default.createDirectory(atPath: paths.permissionDir,
                                                withIntermediateDirectories: true)
        return AgentWaitStore(autoDismissAfter: 0.05,
                              broker: AgentPermissionBroker(paths: paths))
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    private func answerable(_ id: String, session: String = "s1",
                            host: String? = "com.apple.Terminal") -> AgentWaitNotice {
        AgentWaitNotice(
            source: .claude, session: session, host: host, project: "ProNotch",
            request: AgentPermissionRequest(
                id: id, tool: "Bash", detail: "git push", session: session, project: "ProNotch",
                options: [AgentPermissionOption(title: "不再询问", detail: "Bash(git push:*)",
                                                payload: Data("{}".utf8))]))
    }

    private func responseExists(_ store: AgentWaitStore, _ id: String) -> Bool {
        guard let tmp else { return false }
        return FileManager.default.fileExists(
            atPath: GlowHookPaths.rooted(at: tmp.path).permissionDir + "/\(id).response.json")
    }

    /// 大梁老师定的是「一直等到答复」：这张卡是个待办，不是通知。
    /// 自己消失就等于把待办悄悄扔了，而终端那头还卡着等答复
    func test能拍板的卡不自动收回() async throws {
        let store = try answerableStore()
        store.present(answerable(String(repeating: "a", count: 32)), frontmost: nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(store.notice, "自动收回会把一件还没办的事悄悄抹掉")
    }

    /// 只提醒一声的那种照旧 8 秒收回——两种卡的停留规则本来就该不同
    func test只提醒的卡照旧自动收回() async throws {
        let store = try answerableStore()
        store.present(notice(), frontmost: nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(store.notice)
    }

    /// 同时来两条很常见（两个终端各跑一个）。四个按钮的卡摞在一起是按不准的，
    /// 所以排队，答完自动换下一条
    func test第二条排队_答完自动换上() throws {
        let store = try answerableStore()
        let first = String(repeating: "a", count: 32)
        let second = String(repeating: "b", count: 32)
        store.present(answerable(first, session: "s1"), frontmost: nil)
        store.present(answerable(second, session: "s2"), frontmost: nil)
        XCTAssertEqual(store.notice?.request?.id, first)
        XCTAssertEqual(store.queued.count, 1)

        store.answer(.allowOnce)
        XCTAssertEqual(store.notice?.request?.id, second, "答完第一条该轮到第二条")
        XCTAssertTrue(store.queued.isEmpty)
        XCTAssertTrue(responseExists(store, first))
    }

    /// 只提醒一声的那种可以互相顶掉（最新那条才是此刻在等你的），
    /// 但绝不许顶掉一张能拍板的卡——那是待办
    func test提醒不能顶掉正在等拍板的卡() throws {
        let store = try answerableStore()
        let id = String(repeating: "a", count: 32)
        store.present(answerable(id), frontmost: nil)
        store.present(notice(session: "other"), frontmost: nil)
        XCTAssertEqual(store.notice?.request?.id, id)
        XCTAssertEqual(store.queued.count, 1, "提醒该排在后面，不该被丢弃")
    }

    func test同一条请求重复投递不会排两次() throws {
        let store = try answerableStore()
        let id = String(repeating: "a", count: 32)
        store.present(answerable(id), frontmost: nil)
        store.present(answerable(id), frontmost: nil)
        XCTAssertTrue(store.queued.isEmpty, "同一条请求排两次，答一次剩一张按不掉的卡")
    }

    /// 宿主就在眼前时不弹——但**不能一声不响地丢掉**：不答复它，终端也不会弹框，
    /// 整轮就那么干等到钩子超时。得先把「照旧弹终端框」写回去
    func test宿主在前台时放回终端询问() throws {
        let store = try answerableStore()
        let id = String(repeating: "a", count: 32)
        store.present(answerable(id), frontmost: "com.apple.Terminal")
        XCTAssertNil(store.notice)
        XCTAssertTrue(responseExists(store, id), "没写答复就等于把终端那一轮锁死")
    }

    /// 收窄这条规则对能拍板的卡尤其要紧：窗口不在眼前时该弹卡当场答，
    /// 而不是放回一个你根本看不到的窗口里去等着
    func test宿主在前台但窗口不在最上层时弹卡而不放回终端() throws {
        let store = try answerableStore()
        let id = String(repeating: "b", count: 32)
        store.present(answerable(id), frontmost: "com.apple.Terminal", hostWindowVisible: false)
        XCTAssertNotNil(store.notice)
        XCTAssertFalse(responseExists(store, id), "还没答就先写答复，卡上再按什么都没人听了")
    }

    /// 「打开终端」与手动收回走同一条路：先放行（终端立刻照旧弹框），再收卡
    func test手动收回也要放行() throws {
        let store = try answerableStore()
        let id = String(repeating: "a", count: 32)
        store.present(answerable(id), frontmost: nil)
        store.dismiss()
        XCTAssertNil(store.notice)
        XCTAssertTrue(responseExists(store, id))
    }

    // MARK: - 等答复时按住悬停展开

    /// 卡就垫在刘海底下，鼠标要按它的按钮必然先经过刘海。
    /// 那一下要是把刘海展开了，整块面板会盖住卡——按钮还没按到就先看不见了
    func test等答复时悬停不展开刘海() {
        let vm = NotchViewModel(notchRect: CGRect(x: 380, y: 0, width: 200, height: 38))
        let inside = CGPoint(x: vm.notchRect.midX, y: vm.notchRect.midY)
        XCTAssertTrue(vm.hoverShouldExpand(at: inside), "平时悬停照旧展开")

        vm.answerCardPending = true
        XCTAssertFalse(vm.hoverShouldExpand(at: inside), "拍板卡在等答复时展开会把卡盖住")

        vm.answerCardPending = false
        XCTAssertTrue(vm.hoverShouldExpand(at: inside), "答完就该恢复，不能一直锁着")
    }

    /// 只提醒一声的那种不拦：它 8 秒自己走，这 8 秒里刘海不给展开就像坏了
    func test只提醒的卡不拦悬停() {
        XCTAssertTrue(answerable(String(repeating: "a", count: 32)).isAnswerable)
        XCTAssertFalse(notice().isAnswerable, "没请求就没什么可答的，不该拦悬停")
    }

    // MARK: - 能力口径

    /// 中途信号靠上游给，不是我们想做就能做（实测扫本机二进制：
    /// Codex 的 notify 只有 agent-turn-complete，Grok 只有 PreToolUse）。
    /// 设置页按这个开关决定要不要显示那一块——不能对着做不到的家许诺
    func test只有Claude与Kimi支持中途提醒() {
        XCTAssertTrue(AgentKind.claude.supportsWaitNotice)
        XCTAssertTrue(AgentKind.kimi.supportsWaitNotice)
        XCTAssertFalse(AgentKind.codex.supportsWaitNotice)
        XCTAssertFalse(AgentKind.grok.supportsWaitNotice)
    }
}
