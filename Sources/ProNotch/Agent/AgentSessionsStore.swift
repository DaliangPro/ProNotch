import AppKit

/// 一个本机 Agent 会话(Claude Code / Codex / Kimi Code)的快照,供刘海「Agent」页做卡片。
/// 来源直接用 `AgentKind`(supportsSessions 的家),标签/品牌色都从那份定义取
struct AgentSession: Identifiable, Sendable {
    enum State: Sendable {
        case waiting       // hook 实锤:一轮刚结束、球已回到你手里——唯一的醒目「该你了」来源
        case running       // 文件 2 分钟内在写:确实活着在跑
        case idle          // 其余:空闲、已收尾、或被 kill 中断的死会话——都不打扰

        /// 需要你关注(橙点呼吸、置顶):只认 hook 实锤的「该你了」。
        /// 不再靠文件猜「可能在等你」——它分不清真等待和被 kill 的死会话,会误报关掉的会话
        var needsAttention: Bool { self == .waiting }
    }
    let id: String
    let source: AgentKind
    let projectPath: String
    let model: String?
    let lastActivity: Date
    let lastMessage: String?
    var title: String?     // 对话名:Codex thread_name / Claude 会话标题(custom-title,兜底首句 prompt);nil 时卡片用项目名兜底
    var state: State       // 文件扫描给初值,hook 事件在 rebuild 时可覆盖为 .waiting
    var hostBundleID: String? = nil   // hook 带来的宿主 App bundle id,点卡跳转用;nil=还没收到过 hook
    var projectName: String { (projectPath as NSString).lastPathComponent }
    /// 跨模块查表的唯一身份：hook 事件、宿主映射、每会话 token 都认它
    var key: AgentSessionKey { AgentSessionKey(source: source, rawID: id) }
}

/// 会话扫描的来源。抽成协议是为了让"迟到结果"可测：
/// 测试里换成可控延迟的扫描器，就能构造"旧扫描还在跑、勾选已经变了"这种时序
protocol AgentSessionScanning: Sendable {
    func scan(enabled: Set<AgentKind>) async -> [AgentSession]
}

/// 生产实现：按勾选扫四家的会话文件
struct ProductionAgentSessionScanner: AgentSessionScanning {
    func scan(enabled: Set<AgentKind>) async -> [AgentSession] {
        (enabled.contains(.claude) ? AgentSessionsStore.scanClaude() : [])
        + (enabled.contains(.codex) ? AgentSessionsStore.scanCodex() : [])
        + (enabled.contains(.kimi) ? AgentSessionsStore.scanKimi() : [])
        + (enabled.contains(.grok) ? AgentSessionsStore.scanGrok() : [])
    }
}

/// Agent 页数据源:扫描四家的会话文件列出近期会话
/// (~/.claude/projects、~/.codex/sessions、~/.kimi-code/sessions、~/.grok/sessions)。
/// 性能红线:transcript 可达几十 MB,只读尾部 64KB(Codex 另读首 8KB 取 meta),绝不整读。
/// 状态判定(2026-07 实测):两家都没有「等待批准」的落盘事件,
/// - Claude:最后一行是 assistant 且 content 含 tool_use = 悬空(等确认或工具执行中);
/// - Codex:task_started 无配对 task_complete = 悬空;
/// - 文件几秒内刚被写入 = 运行中。悬空且不再写入 → 标「可能在等你」。
@MainActor
final class AgentSessionsStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var refreshing = false
    private var lastRefresh = Date.distantPast
    private let scanner: AgentSessionScanning
    /// 扫描代际。每启动一轮 +1，结果回来时对不上就丢——
    /// 否则用户刚取消勾选某家，上一轮在途的扫描照样把那家的卡片列回来
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    /// 在途扫描期间又来了强制刷新（hook 事件是高频来源）：记下来，这轮结束立刻补跑
    private var pendingForce = false
    private var rawSessions: [AgentSession] = []       // 文件扫描原始结果(带文件推断态),hook 事件在其上叠加
    // hook 事件与宿主映射一律以 AgentSessionKey(来源 + 规范化 ID) 为键。
    // 原先是裸字符串键 + `id == key || id.hasSuffix(key)` 模糊比对：Codex 的 hook 只报
    // 裸 thread-id、文件名却是 `rollout-<日期>-<uuid>`，才不得不后缀匹配——
    // 而后缀匹配跨不了来源，Claude 的 uuid 完全可能命中 Codex 的文件名。规范化后是精确相等
    private var turnEndedAt: [AgentSessionKey: Date] = [:]       // 「轮结束」事件时间(30 分钟过期,for「该你了」)
    private var hostBySession: [AgentSessionKey: String] = [:]   // 宿主 App bundle id;持久化、跨重启保留,点卡跳转用
    private static let hostStoreKey = "agentHostBySession"

    nonisolated static let recentWindow: TimeInterval = 48 * 3600   // 只列 48 小时内活动过的会话
    nonisolated static let maxCount = 12

    init(scanner: AgentSessionScanning = ProductionAgentSessionScanner()) {
        self.scanner = scanner
        // 恢复持久化的宿主映射:上次运行采集到的 host 仍可用于跳转,不必等本次再轮结束一次
        hostBySession = Self.decodeHosts(UserDefaults.standard.dictionary(forKey: Self.hostStoreKey) as? [String: String])
        // 设置页 Agent 勾选变更 → 立即重扫,取消家的卡片马上从监控台消失
        NotificationCenter.default.addObserver(
            forName: .proNotchAgentSelectionChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAgentSelection() }
        }
    }

    /// 勾选变更：先作废在途那轮（它是按旧勾选集扫的），再立刻按新勾选重扫
    func applyAgentSelection() {
        cancelRefresh()
        start(enabled: AgentKind.enabledSet())
    }

    /// 取消在途扫描：代际前进、任务取消、`refreshing` 复位。
    /// 复位不能漏——被取消的任务不会走到收尾分支，漏了就永远卡在"刷新中"
    func cancelRefresh() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        pendingForce = false
        refreshing = false
    }

    /// 刷新(10 秒节流,force 忽略节流);扫描在后台线程,主线程叠加 hook 事件后收结果。
    /// 只扫勾选的家(设置 → Agent 每家总开关):未勾选家不读它的任何会话文件
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 10 else { return }
        guard !refreshing else {
            // 撞上在途扫描：强制刷新排队等这轮结束。hook 事件正是走这条路，
            // 直接丢弃会让「一轮刚结束」的最新摘要拉不回来
            if force { pendingForce = true }
            return
        }
        start(enabled: AgentKind.enabledSet())   // 主线程取快照,整轮全程用同一份
    }

    private func start(enabled: Set<AgentKind>) {
        refreshing = true
        lastRefresh = Date()
        generation &+= 1
        let gen = generation
        refreshTask = Task { [weak self, scanner] in
            let raw = await scanner.scan(enabled: enabled)
            self?.apply(raw, generation: gen, enabled: enabled)
        }
    }

    /// 结果落地。三道校验都过才写 UI：代际未变、任务未取消、勾选集与出发时一致
    private func apply(_ raw: [AgentSession], generation gen: UInt64, enabled: Set<AgentKind>) {
        defer { finish(generation: gen) }
        guard gen == generation, !Task.isCancelled, enabled == AgentKind.enabledSet() else { return }
        // 再按勾选滤一遍：scanner 是外部实现，不能假定它一定尊重了 enabled
        rawSessions = raw.filter { enabled.contains($0.source) }
        rebuild()
    }

    /// 收尾。旧代际的任务不许碰 `refreshing`——那是新任务的状态了
    private func finish(generation gen: UInt64) {
        guard gen == generation else { return }
        refreshing = false
        refreshTask = nil
        if pendingForce {
            pendingForce = false
            start(enabled: AgentKind.enabledSet())
        }
    }

    /// hook 实时事件:某会话一轮刚结束(Claude Stop / Codex agent-turn-complete)→ 立刻标「该你了」,
    /// 不等文件扫描那 ~2 分钟。session = Claude 的 session_id 或 Codex 的 thread-id
    func markTurnEnded(session: String, source: AgentKind, host: String?) {
        guard !session.isEmpty else { return }
        let key = AgentSessionKey(source: source, rawID: session)
        turnEndedAt[key] = Date()
        if let host, !host.isEmpty {
            hostBySession[key] = host
            UserDefaults.standard.set(Self.encodeHosts(hostBySession), forKey: Self.hostStoreKey)   // 持久化,下次启动仍能跳
        }
        rebuild()              // 会话已在列表 → 即时点亮
        refresh(force: true)   // 顺带重扫,拿最新摘要 / 新会话
    }

    /// 点卡跳转:切到该会话所在的宿主 App(终端/IDE);没有 hook 报过宿主则回退到该 Agent 桌面版
    func activate(_ session: AgentSession) {
        // 点卡即已读:清掉这张卡的「该你了」事件、橙灯立刻灭（你点它 = 去处理了）
        turnEndedAt[session.key] = nil
        rebuild()
        let host = session.hostBundleID
        let desktop = session.source.appBundleID   // 无桌面版的家（Kimi）为 nil，只靠 hook 报的宿主
        let ws = NSWorkspace.shared
        // 用 openApplication(activates:true) 前置——macOS Sonoma 起,后台 App(无 Dock 图标)
        // 直接 NSRunningApplication.activate() 常被系统忽略;openApplication 等价「点 Dock 图标」,系统放行。
        // 只到 App 级:官方 App 单窗口 + 内部切换对话,外部程序无法定位到具体对话
        for bid in [host, desktop].compactMap({ $0 }) {
            if let url = ws.urlForApplication(withBundleIdentifier: bid) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.openApplication(at: url, configuration: cfg, completionHandler: nil)
                return
            }
        }
    }

    /// 用最新的 hook 事件在文件态之上叠加,重排并截断
    private func rebuild() {
        let now = Date()
        turnEndedAt = turnEndedAt.filter { now.timeIntervalSince($0.value) < 30 * 60 }   // 「该你了」事件 30 分钟过期(host 不随之过期,长期保留供跳转)
        let merged = rawSessions.map { s -> AgentSession in
            var s = s
            // hook 事件不比文件最后活动旧(容差 5 秒,Stop 后可能还在写最后一条消息)→ 确定「该你了」;
            // 用户之后又发消息(mtime 远晚于 hook)则条件不成立,回到文件推断态
            if let t = hookTime(for: s), t >= s.lastActivity.addingTimeInterval(-5) {
                s.state = .waiting
            }
            s.hostBundleID = hookHost(for: s)   // 收到过 hook 的会话带上宿主,供跳转
            return s
        }
        func rank(_ st: AgentSession.State) -> Int {
            switch st { case .waiting: return 0; case .running: return 1; case .idle: return 2 }
        }
        let sorted = merged.sorted {
            rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state)
                                             : $0.lastActivity > $1.lastActivity
        }
        // 名额按来源各算：全局共用名额时，重度使用一家（整天 Claude）会把另一家全部挤出列表
        sessions = AgentKind.allCases.flatMap { kind in
            Array(sorted.filter { $0.source == kind }.prefix(Self.maxCount))
        }
    }

    /// 匹配 hook 事件：规范化之后是精确相等，不再做后缀猜测
    private func hookTime(for s: AgentSession) -> Date? { turnEndedAt[s.key] }
    private func hookHost(for s: AgentSession) -> String? { hostBySession[s.key] }

    /// 该会话已知的宿主 App bundle id（hook 曾抓对并持久化过的）——供 host 偶发抓空时复用，
    /// 不盲目回退桌面版：Claudian/SDK 起的 claude 进程有时没挂在 Obsidian 进程链下、detect_host 抓空
    func knownHost(for session: String, source: AgentKind) -> String? {
        guard !session.isEmpty else { return nil }
        return hostBySession[AgentSessionKey(source: source, rawID: session)]
    }

    // MARK: - 宿主映射的持久化编码

    nonisolated static func encodeHosts(_ hosts: [AgentSessionKey: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: hosts.map { ($0.key.storageKey, $0.value) })
    }

    /// 旧版本存的是不带来源的裸 ID，认不出来就丢：这张表只是跳转用的便利缓存，
    /// 下次 hook 事件就能补回来，不值得为它猜来源、猜错反而把跳转指到别家 App
    nonisolated static func decodeHosts(_ raw: [String: String]?) -> [AgentSessionKey: String] {
        var out: [AgentSessionKey: String] = [:]
        for (k, v) in raw ?? [:] {
            if let key = AgentSessionKey(storageKey: k) { out[key] = v }
        }
        return out
    }

    // MARK: - Claude Code(~/.claude/projects/<项目>/<sessionId>.jsonl)

    fileprivate nonisolated static func scanClaude() -> [AgentSession] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let cutoff = Date().addingTimeInterval(-recentWindow)
        var out: [AgentSession] = []
        for proj in projects {
            guard (try? proj.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > cutoff else { continue }
                if let s = parseClaude(file: f, mtime: mtime) { out.append(s) }
            }
        }
        return out
    }

    private nonisolated static func parseClaude(file: URL, mtime: Date) -> AgentSession? {
        guard let tail = readTail(file, bytes: 64 * 1024) else { return nil }
        let lines = tail.split(separator: "\n")
        var cwd: String?, model: String?, lastText: String?, lastPrompt: String?
        // 回合状态看最后一条 user/assistant 行(跳过 system/mode 等杂项):
        // user(prompt 或工具结果)= 模型接着跑;assistant 含 tool_use = 工具调用中;assistant 纯文本 = 一轮收尾
        var inTurn = false, turnRowSeen = false
        for raw in lines.reversed() {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if !turnRowSeen, type == "user" || type == "assistant" {
                turnRowSeen = true
                if type == "user" {
                    inTurn = true
                } else if let msg = obj["message"] as? [String: Any],
                          let content = msg["content"] as? [[String: Any]] {
                    inTurn = content.contains { $0["type"] as? String == "tool_use" }
                }
            }
            if cwd == nil { cwd = obj["cwd"] as? String }
            if type == "assistant", let msg = obj["message"] as? [String: Any] {
                if model == nil { model = msg["model"] as? String }
                if lastText == nil, let content = msg["content"] as? [[String: Any]],
                   let t = content.last(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
                    let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { lastText = clean }
                }
            }
            if lastPrompt == nil, type == "last-prompt" { lastPrompt = obj["lastPrompt"] as? String }
            if cwd != nil, model != nil, lastText != nil, turnRowSeen { break }
        }
        guard let cwd else { return nil }   // 尾部 64KB 连 cwd 都没有 = 非会话文件,跳过
        return AgentSession(id: file.deletingPathExtension().lastPathComponent,
                            source: .claude, projectPath: cwd, model: model,
                            lastActivity: mtime,
                            lastMessage: summarize(lastText ?? lastPrompt),
                            title: titleize(claudeCustomTitle(file) ?? claudeHeadTitle(file)),
                            state: state(mtime: mtime, inTurn: inTurn))
    }

    // MARK: - Codex(~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    fileprivate nonisolated static func scanCodex() -> [AgentSession] {
        // 按 mtime 全量枚举，不能按日期目录扫最近几天：Codex 把 rollout 文件放在
        // 「会话开始日」的目录里持续追加数月——实测 05/31 目录里 200MB 的主力会话今天还在写，
        // 按日期目录扫必漏这类长命会话（2026-07-14 大梁老师报「Agent 页看不到 Codex」）。
        // 枚举只 stat 不读内容，目录量级为「用过的天数」，开销可忽略
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let cutoff = Date().addingTimeInterval(-recentWindow)
        let threadNames = loadCodexThreadNames()   // session_index.jsonl 的对话名,一次读入
        var out: [AgentSession] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard f.lastPathComponent.hasPrefix("rollout-"),
                  let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime > cutoff else { continue }
            if let s = parseCodex(file: f, mtime: mtime, threadNames: threadNames) { out.append(s) }
        }
        return out
    }

    private nonisolated static func parseCodex(file: URL, mtime: Date, threadNames: [String: String]) -> AgentSession? {
        // 子代理文件不单独成卡:Codex 多代理把并行子代理拆成独立 rollout(session_meta 带
        // parent_thread_id),它们是父任务的内部执行体——无对话名、无 hook 事件,列出来全是无名噪音卡
        if let head = readHead(file, bytes: 1024 * 1024),
           let first = head.split(separator: "\n", maxSplits: 1).first,
           let obj = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
           obj["type"] as? String == "session_meta",
           let payload = obj["payload"] as? [String: Any],
           let parent = payload["parent_thread_id"] as? String, !parent.isEmpty {
            return nil
        }
        // 元信息优先从尾部拿:session_meta 首行带完整系统指令、可达几十 KB,
        // 头部小窗口读取必被截断(实测 74MB rollout 因此整个被丢);turn_context 每轮都写、尾部大概率有
        var cwd: String?, model: String?, lastMsg: String?
        var started = false, completed = false
        if let tail = readTail(file, bytes: 64 * 1024) {
            for raw in tail.split(separator: "\n").reversed() {
                guard let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { continue }
                let ptype = payload["type"] as? String
                if obj["type"] as? String == "turn_context" {
                    cwd = cwd ?? payload["cwd"] as? String
                    model = model ?? payload["model"] as? String
                }
                if !started, !completed {
                    if ptype == "task_complete" { completed = true }
                    else if ptype == "task_started" { started = true }
                }
                if lastMsg == nil, ptype == "agent_message" {
                    lastMsg = (payload["message"] as? String) ?? (payload["last_agent_message"] as? String)
                }
            }
        }
        // 尾部没有 turn_context(超长单轮)→ 头部 512KB 兜底找 session_meta / turn_context
        if cwd == nil, let head = readHead(file, bytes: 512 * 1024) {
            for raw in head.split(separator: "\n") {
                guard let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { continue }
                switch obj["type"] as? String {
                case "session_meta", "turn_context":
                    cwd = cwd ?? payload["cwd"] as? String
                    model = model ?? payload["model"] as? String
                default: break
                }
                if cwd != nil { break }
            }
        }
        guard let cwd else { return nil }
        return AgentSession(id: file.deletingPathExtension().lastPathComponent,
                            source: .codex, projectPath: cwd, model: model,
                            lastActivity: mtime,
                            lastMessage: summarize(lastMsg),
                            title: threadNames[String(file.deletingPathExtension().lastPathComponent.suffix(36))],
                            state: state(mtime: mtime, inTurn: started && !completed))
    }

    // MARK: - Kimi Code(~/.kimi-code/sessions/<workspace>/session_<id>/)

    /// 每个会话一个目录:state.json(标题/更新时间) + agents/main/wire.jsonl(事件流)。
    /// 全局索引 session_index.jsonl 给出 sessionId → sessionDir → workDir,不必递归枚举。
    /// 轮边界(实测 2026-07):turn.prompt=轮开始;usageScope=="turn" 的 usage.record
    /// 或 turn.cancel=轮收尾——尾部倒扫先遇到谁定 inTurn
    fileprivate nonisolated static func scanKimi() -> [AgentSession] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let index = home.appendingPathComponent(".kimi-code/session_index.jsonl")
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-recentWindow)
        var out: [AgentSession] = []
        for raw in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let dir = obj["sessionDir"] as? String,
                  let workDir = obj["workDir"] as? String else { continue }
            let wire = URL(fileURLWithPath: dir).appendingPathComponent("agents/main/wire.jsonl")
            guard let mtime = (try? wire.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime > cutoff else { continue }
            if let s = parseKimi(sessionId: sid, dir: dir, workDir: workDir, wire: wire, mtime: mtime) {
                out.append(s)
            }
        }
        return out
    }

    private nonisolated static func parseKimi(sessionId: String, dir: String, workDir: String,
                                              wire: URL, mtime: Date) -> AgentSession? {
        // 标题从 state.json 拿(Kimi 自动命名,含中文标题);文件仅几百字节
        var title: String?
        let stateURL = URL(fileURLWithPath: dir).appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateURL),
           let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = st["title"] as? String
        }
        // 尾部倒扫定轮态与模型;wire.jsonl 事件行普遍较短,64KB 覆盖充足
        var inTurn = false, model: String?, lastPrompt: String?
        if let tail = readTail(wire, bytes: 64 * 1024) {
            var settled = false
            for raw in tail.split(separator: "\n").reversed() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if !settled {
                    if type == "turn.prompt" { inTurn = true; settled = true }
                    else if type == "turn.cancel" { settled = true }
                    else if type == "usage.record", obj["usageScope"] as? String == "turn" { settled = true }
                }
                if model == nil, type == "usage.record" { model = obj["model"] as? String }
                if lastPrompt == nil, type == "turn.prompt",
                   let input = obj["input"] as? [[String: Any]] {
                    // 用户最近的提问作卡片摘要(Kimi 的 assistant 文本嵌在 loop 事件深处,不值得深挖)
                    lastPrompt = input.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                }
                if settled, model != nil, lastPrompt != nil { break }
            }
        }
        return AgentSession(id: sessionId,
                            source: .kimi, projectPath: workDir, model: model,
                            lastActivity: mtime,
                            lastMessage: summarize(lastPrompt),
                            title: titleize(title),
                            state: state(mtime: mtime, inTurn: inTurn))
    }

    // MARK: - Grok(~/.grok/sessions/<URL 编码的项目路径>/<会话 uuid>/)

    /// 每个会话一个目录:summary.json(元信息) + chat_history.jsonl(对话)。
    /// 目录名是 URL 编码的项目路径,但不必解码——summary.json 的 info.cwd 就是原路径。
    /// 轮边界(实测 2026-07-20):尾部倒扫,最后一条 user = 模型还在跑;assistant = 一轮收尾
    fileprivate nonisolated static func scanGrok() -> [AgentSession] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".grok/sessions")
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let cutoff = Date().addingTimeInterval(-recentWindow)
        var out: [AgentSession] = []
        for proj in projects {
            // 项目层还混着 prompt_history.jsonl 等散文件与 session_search.sqlite,只进目录
            guard (try? proj.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let dirs = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for d in dirs {
                guard (try? d.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let chat = d.appendingPathComponent("chat_history.jsonl")
                guard let mtime = (try? chat.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > cutoff else { continue }
                if let s = parseGrok(dir: d, chat: chat, mtime: mtime) { out.append(s) }
            }
        }
        return out
    }

    private nonisolated static func parseGrok(dir: URL, chat: URL, mtime: Date) -> AgentSession? {
        // 元信息全在 summary.json(几百字节,整读无压力):项目路径 / 模型 / 会话名
        var cwd: String?, model: String?, summary: String?
        if let data = try? Data(contentsOf: dir.appendingPathComponent("summary.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cwd = (obj["info"] as? [String: Any])?["cwd"] as? String
            model = obj["current_model_id"] as? String
            summary = obj["session_summary"] as? String
        }
        guard let cwd else { return nil }   // 没有 summary.json / 无 cwd = 非会话目录,跳过
        // 尾部倒扫定轮态与末条回复。user 的 content 是 [{type,text}] 数组、assistant 是纯字符串
        var inTurn = false, lastText: String?
        if let tail = readTail(chat, bytes: 64 * 1024) {
            var settled = false
            for raw in tail.split(separator: "\n").reversed() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if !settled, type == "user" || type == "assistant" {
                    settled = true
                    inTurn = (type == "user")   // 最后一条是用户发言 = 模型还没回完,正在跑
                }
                if lastText == nil, type == "assistant", let c = obj["content"] as? String {
                    let clean = c.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { lastText = clean }
                }
                if settled, lastText != nil { break }
            }
        }
        // session_summary 实测多为空(Grok 不自动命名)→ 回退首句 prompt
        let name = (summary?.isEmpty == false) ? summary : grokHeadTitle(chat)
        return AgentSession(id: dir.lastPathComponent,
                            source: .grok, projectPath: cwd, model: model,
                            lastActivity: mtime,
                            lastMessage: summarize(lastText),
                            title: titleize(name),
                            state: state(mtime: mtime, inTurn: inTurn))
    }

    /// 会话名兜底:取首条 user prompt,与 Claude 的 headTitle 同思路。
    /// system 提示词占开头约 4KB,16KB 窗口足够读到首条 user
    private nonisolated static func grokHeadTitle(_ chat: URL) -> String? {
        guard let head = readHead(chat, bytes: 16 * 1024) else { return nil }
        for raw in head.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  let content = obj["content"] as? [[String: Any]],
                  let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            else { continue }
            if let clean = SessionUsage.cleanUserPrompt(text) { return clean }
        }
        return nil
    }

    // MARK: - 共用

    /// Claude 会话标题：custom-title 行随改名/自动命名反复写，取最后一条（实测距末尾 0–31KB，
    /// 512KB 窗口余量充足）。用字节标记从后往前定位、只解析命中的那一行——
    /// 不能在主解析循环里顺带抓：主循环凑齐 cwd/model 等字段后几行内就 break，走不到标题行
    private nonisolated static func claudeCustomTitle(_ file: URL) -> String? {
        guard let tail = readTail(file, bytes: 512 * 1024),
              let hit = tail.range(of: "\"type\":\"custom-title\"", options: .backwards) else { return nil }
        let lineStart = tail[..<hit.lowerBound].lastIndex(of: "\n").map(tail.index(after:)) ?? tail.startIndex
        let lineEnd = tail[hit.upperBound...].firstIndex(of: "\n") ?? tail.endIndex
        guard let obj = try? JSONSerialization.jsonObject(with: Data(tail[lineStart..<lineEnd].utf8)) as? [String: Any],
              let t = obj["customTitle"] as? String, !t.isEmpty else { return nil }
        return t
    }

    /// 尾部窗口没有 custom-title 时的头部兜底：头 16KB 内优先找早期的 custom-title
    /// （自动命名多发生在首轮回复后，常落在头部），仍没有才退回首句 user prompt
    private nonisolated static func claudeHeadTitle(_ file: URL) -> String? {
        guard let head = readHead(file, bytes: 16 * 1024) else { return nil }
        var prompt: String?
        for raw in head.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.isEmpty { return t }
            case "user" where prompt == nil:
                guard let msg = obj["message"] as? [String: Any] else { continue }
                var candidate: String?
                if let s = msg["content"] as? String { candidate = s }
                else if let arr = msg["content"] as? [[String: Any]] {
                    for b in arr where (b["type"] as? String) == "text" {
                        if let t = b["text"] as? String { candidate = t; break }
                    }
                }
                // 斜杠命令封装抽命令名（/xxx）；抽不出的标签杂讯保持 nil → 继续找下一条真人消息
                prompt = candidate.flatMap { SessionUsage.cleanUserPrompt($0) }
            default: break
            }
        }
        return prompt
    }

    /// Codex 对话名映射：~/.codex/session_index.jsonl 的 id → thread_name（一次读入）
    private nonisolated static func loadCodexThreadNames() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
            out[id] = name
        }
        return out
    }

    /// 对话名清洗：去换行、trim、超 40 字截断
    private nonisolated static func titleize(_ text: String?) -> String? {
        guard var t = text?.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.count > 40 { t = String(t.prefix(40)) + "…" }
        return t
    }

    /// 只有「回合进行中 且 2 分钟内真的在写」= 运行中;其余一律 idle(不打扰)。
    /// 「停下等你」的醒目提醒交给 hook 的 .waiting——被 kill 中断的死会话没 hook 事件,自然沉默,
    /// 不再靠文件猜「可能在等你」(那分不清真等待和被中断,会误报你已经关掉的会话)
    private nonisolated static func state(mtime: Date, inTurn: Bool) -> AgentSession.State {
        guard inTurn, Date().timeIntervalSince(mtime) < 120 else { return .idle }
        return .running
    }

    private nonisolated static func summarize(_ text: String?) -> String? {
        guard var t = text?.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.count > 120 { t = String(t.prefix(120)) + "…" }
        return t
    }

    /// 只读文件尾部 bytes 字节(大 transcript 防整读);截断处可能砍在多字节中间,用容错解码
    private nonisolated static func readTail(_ url: URL, bytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func readHead(_ url: URL, bytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
