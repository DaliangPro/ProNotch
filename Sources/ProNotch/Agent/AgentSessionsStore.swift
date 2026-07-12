import AppKit

/// 一个本机 Agent 会话(Claude Code / Codex)的快照,供刘海「Agent」页做卡片
struct AgentSession: Identifiable {
    enum Source {
        case claude, codex
        var label: String { self == .claude ? "Claude" : "Codex" }
    }
    enum State {
        case running       // 文件正被写入,一轮进行中
        case maybeWaiting  // 停在工具调用未收尾——可能在等你确认,也可能是长任务
        case idle          // 一轮已收尾,等你开启下一轮
    }
    let id: String
    let source: Source
    let projectPath: String
    let model: String?
    let lastActivity: Date
    let lastMessage: String?
    let state: State
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

/// Agent 页数据源:扫描 ~/.claude/projects 与 ~/.codex/sessions 的会话文件列出近期会话。
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

    nonisolated static let recentWindow: TimeInterval = 48 * 3600   // 只列 48 小时内活动过的会话
    nonisolated static let maxCount = 12

    /// 刷新(10 秒节流,force 忽略节流);扫描在后台线程,主线程只收结果
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 10 else { return }
        guard !refreshing else { return }
        refreshing = true
        lastRefresh = Date()
        Task.detached(priority: .utility) {
            let all = Self.scanClaude() + Self.scanCodex()
            // 「可能在等你」置顶,其余按最后活动倒序
            func rank(_ s: AgentSession.State) -> Int {
                switch s { case .maybeWaiting: return 0; case .running: return 1; case .idle: return 2 }
            }
            let sorted = all.sorted {
                rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state)
                                                 : $0.lastActivity > $1.lastActivity
            }
            let top = Array(sorted.prefix(Self.maxCount))
            await MainActor.run { [weak self] in
                self?.sessions = top
                self?.refreshing = false
            }
        }
    }

    // MARK: - Claude Code(~/.claude/projects/<项目>/<sessionId>.jsonl)

    private nonisolated static func scanClaude() -> [AgentSession] {
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
                            state: state(mtime: mtime, inTurn: inTurn))
    }

    // MARK: - Codex(~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    private nonisolated static func scanCodex() -> [AgentSession] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let cutoff = Date().addingTimeInterval(-recentWindow)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy/MM/dd"
        var out: [AgentSession] = []
        for back in 0..<3 {   // 48h 窗口至多跨 3 个日期目录
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let dir = root.appendingPathComponent(fmt.string(from: day))
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > cutoff else { continue }
                if let s = parseCodex(file: f, mtime: mtime) { out.append(s) }
            }
        }
        return out
    }

    private nonisolated static func parseCodex(file: URL, mtime: Date) -> AgentSession? {
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
                            state: state(mtime: mtime, inTurn: started && !completed))
    }

    // MARK: - 共用

    /// 回合中 + 2 分钟内有写入 = 运行中(工具执行间隙不落盘,窗口必须宽);
    /// 回合中 + 2~30 分钟没动静 = 可能在等你;
    /// 悬空超 30 分钟 = 被中断/弃掉的会话(kill 掉的回合尾部同样悬空),按空闲处理不再打扰
    private nonisolated static func state(mtime: Date, inTurn: Bool) -> AgentSession.State {
        guard inTurn else { return .idle }
        let age = Date().timeIntervalSince(mtime)
        if age < 120 { return .running }
        return age < 30 * 60 ? .maybeWaiting : .idle
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
