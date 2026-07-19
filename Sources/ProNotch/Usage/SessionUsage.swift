import Foundation

/// 一个任务（会话）的额度消耗快照，供额度页 Top 5 用
struct TaskUsage: Identifiable {
    let id: String              // sessionId（文件名）
    let name: String            // 对话名（Claude 首句 / Codex thread_name）
    let tokens: Int             // 有效 token（已排除缓存读）
    let percentOfTotal: Double  // 占总额度百分比 = token 占比 × 周额度已用%
}

/// 按会话统计 Agent 的 token 消耗：Claude 遍历 transcript 累加、Codex 读 session 末条。
/// 与额度数据源解耦——不管额度走官方接口还是本地估算，这里都独立算，供「每任务消耗」用。
/// 口径与 ClaudeQuotaLoader.estimateFromTranscripts 一致：排除 cache_read（缓存读千倍灌水、官方计价权重极低）。
enum SessionUsage {
    /// 近 7 天窗口（与周额度对齐）
    private static let window: TimeInterval = 7 * 86400

    struct Scanned { let id: String; let tokens: Int; let url: URL; var claudeTitle: String? = nil }

    // MARK: - Claude：~/.claude/projects/*/*.jsonl 按文件累加有效 token
    //
    // 文件级缓存（照 Codex 侧 CodexScanCache 的既有模式）：transcript 全库 GB 级，
    // 但历史文件写完就不再变，每轮真正要重读的只有活跃会话那一两个文件。
    // 缓存按 mtime+size 失效；Top 5 扫描与额度估算共用同一份解析结果
    // （此前两者各自把同一批文件整读一遍，是全 App 最大的瞬时内存/CPU 源）。

    /// transcript 单条 usage 记录。day = 原始 timestamp 前 10 位（日粒度过滤用，缺失为 nil），
    /// ts = 精确解析（5 小时活动块聚合用，解析失败为 nil）——两个消费方的过滤口径不同，都保留
    struct UsageEntry {
        let day: String?
        let ts: Date?
        let tokens: Int
    }

    private struct ClaudeScanCache { let mtime: Date; let size: Int; let entries: [UsageEntry]; let title: String? }
    nonisolated(unsafe) private static var claudeCache: [String: ClaudeScanCache] = [:]
    private static let claudeCacheLock = NSLock()
    /// 整读解析的累计次数（测试断言缓存命中用；refresh 单飞，无并发累加）
    nonisolated(unsafe) static var claudeParseCount = 0

    static func scanClaude(root: URL = defaultClaudeRoot) -> [Scanned] {
        // 按条目时间过滤（不只按文件 mtime）：断续跑数周的长会话，只算近 7 天的条目，
        // 否则一生累计参与分摊会高估老会话（与 Codex 侧同一失真）
        let cutoffDay = String(iso8601UTC.string(from: Date().addingTimeInterval(-window)).prefix(10))
        return claudeFileScans(root: root).compactMap { file in
            let sum = file.entries.lazy
                .filter { $0.day.map { $0 >= cutoffDay } ?? true }   // timestamp 缺失视为在窗内（沿旧口径）
                .reduce(0) { $0 + $1.tokens }
            guard sum > 0 else { return nil }
            return Scanned(id: file.url.deletingPathExtension().lastPathComponent, tokens: sum,
                           url: file.url, claudeTitle: titleize(file.title))
        }
    }

    static var defaultClaudeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// 近 7 天有改动的 transcript 逐文件解析结果（命中缓存零 IO）。
    /// scanClaude 与 UsageStore.estimateFromTranscripts 都走这里——
    /// 同一轮 refresh 里后调用的一方几乎全命中缓存，天然免掉第二遍整读
    static func claudeFileScans(root: URL = defaultClaudeRoot) -> [(url: URL, entries: [UsageEntry], title: String?)] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-window)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        var out: [(url: URL, entries: [UsageEntry], title: String?)] = []
        var seen: Set<String> = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let m = rv.contentModificationDate, m > cutoff else { continue }
            seen.insert(url.path)
            let size = rv.fileSize ?? 0
            claudeCacheLock.lock()
            let cached = claudeCache[url.path]
            claudeCacheLock.unlock()
            if let cached, cached.mtime == m, cached.size == size {
                out.append((url, cached.entries, cached.title))
                continue
            }
            // 变过的文件才整读（每文件一个池：整串文本与逐行 JSON 临时对象逐文件释放）
            let parsed = autoreleasepool { parseClaudeFile(url, cutoff: cutoff) }
            claudeCacheLock.lock()
            claudeCache[url.path] = ClaudeScanCache(mtime: m, size: size, entries: parsed.entries, title: parsed.title)
            claudeCacheLock.unlock()
            out.append((url, parsed.entries, parsed.title))
        }
        // mtime 滑出 7 天窗的文件不会再被枚举，顺手清缓存防无限增长
        claudeCacheLock.lock()
        claudeCache = claudeCache.filter { seen.contains($0.key) }
        claudeCacheLock.unlock()
        return out
    }

    /// 整读解析单个 transcript：有效 usage 条目 + 自定义标题（custom-title 末条最新）。
    /// 条目按解析时刻的 7 天窗做日粒度粗过滤后入缓存——窗口只向前滑，
    /// 之后任何轮次需要的条目恒为本集子集（日粒度是精确窗口的超集，消费方再精筛），缓存窗口安全
    private static func parseClaudeFile(_ url: URL, cutoff: Date) -> (entries: [UsageEntry], title: String?) {
        claudeParseCount += 1
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], nil) }
        let cutoffDay = String(iso8601UTC.string(from: cutoff).prefix(10))
        var entries: [UsageEntry] = []
        var title: String?
        for line in text.split(separator: "\n") {
            // Claude Code 的会话标题（custom-title 行，末条最新）——比首句 prompt 更像「名字」
            if line.contains("custom-title"),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               obj["type"] as? String == "custom-title",
               let t = obj["customTitle"] as? String, !t.isEmpty {
                title = t
                continue
            }
            guard line.contains("\"usage\""), line.contains("\"assistant\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  (msg["model"] as? String)?.hasPrefix("claude-") == true,   // 只算官方模型，第三方中转不耗订阅
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
                .compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
            guard tokens > 0 else { continue }
            let tsStr = obj["timestamp"] as? String
            let day = tsStr.map { String($0.prefix(10)) }
            if let day, day < cutoffDay { continue }   // 窗外老条目不入缓存（timestamp 缺失保留，沿旧口径）
            entries.append(UsageEntry(day: day, ts: tsStr.flatMap { ISO8601Flex.parse($0) }, tokens: tokens))
        }
        return (entries, title)
    }

    // MARK: - Codex：~/.codex/sessions/近 7 天/*.jsonl 读末条 token

    static func scanCodex() -> [Scanned] {
        // 按 mtime 全量枚举，不能按日期目录扫最近几天：Codex 把 rollout 文件放在
        // 「会话开始日」的目录里持续追加数月——主力长会话（实测 05/31 目录 200MB 今天还在写）
        // 按日期目录扫必漏，Top 5 就只剩边角小会话
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let cutoff = Date().addingTimeInterval(-window)
        var raw: [(scanned: Scanned, parent: String?)] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        // 每个文件一个池（return 即跳过该文件）：头尾分块读也有 MB 级临时串，逐文件释放
        for case let f as URL in en where f.pathExtension == "jsonl" {
            autoreleasepool {
            guard f.lastPathComponent.hasPrefix("rollout-"),
                  let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  m > cutoff else { return }
            let info = codexFileInfo(f)
            let cutoffDay = String(iso8601UTC.string(from: Date().addingTimeInterval(-window)).prefix(10))
            let tokens = info.buckets.filter { $0.key >= cutoffDay }.values.reduce(0, +)
            guard tokens > 0 else { return }
            raw.append((Scanned(id: f.deletingPathExtension().lastPathComponent, tokens: tokens, url: f), info.parent))
            }   // autoreleasepool
        }
        // 子代理归并到根任务：Codex Desktop 多代理把并行子代理拆成独立 rollout 文件
        // （session_meta 带 parent_thread_id）。不归并则一个任务的消耗被拆成 N 行无名子代理——
        // 实测「课程2.0」主线程 13.8M + 三个子代理各 8M，屏显却是一行 2% + 三行无名 1%
        var parentOf: [String: String] = [:]
        for (s, p) in raw { if let p, !p.isEmpty { parentOf[String(s.id.suffix(36))] = p } }
        func rootUuid(_ uuid: String) -> String {
            var u = uuid, hops = 0
            while let p = parentOf[u], hops < 5 { u = p; hops += 1 }   // 链式子代理逐级上溯，防环限深
            return u
        }
        var tokensByRoot: [String: Int] = [:]
        var repByRoot: [String: Scanned] = [:]   // 根任务的代表文件（优先根自己的，根不在窗口则用子代理的）
        for (s, _) in raw {
            let uuid = String(s.id.suffix(36))
            let r = rootUuid(uuid)
            tokensByRoot[r, default: 0] += s.tokens
            if uuid == r { repByRoot[r] = s } else if repByRoot[r] == nil { repByRoot[r] = s }
        }
        return tokensByRoot.compactMap { r, tok in
            guard let rep = repByRoot[r] else { return nil }
            if String(rep.id.suffix(36)) == r {
                return Scanned(id: rep.id, tokens: tok, url: rep.url)
            }
            // 根文件本周没动、只有子代理在跑：合成 id（后 36 位 = 根 uuid，名字仍可查 index），cwd 同子代理
            return Scanned(id: "agg-\(r)", tokens: tok, url: rep.url)
        }
    }

    /// Codex 单文件：近 7 天的有效 token。逐条 token_count 事件求和（每事件带 timestamp +
    /// last_token_usage），只累加时间窗内的事件。不能读尾部 total_token_usage 累计值——
    /// 它是「会话一生」的累计（实测单调不清零）：05/31 起的老会话近 7 天只占其累计 22%，
    /// 按一生累计分摊会把老会话高估 4.6 倍。实测 Σ每轮 last ≈ 末条累计（偏差 <1%），逐事件求和可靠。
    /// 大文件（主力会话 200MB）全量扫描的开销用 mtime+size 缓存兜住：文件没变直接复用天桶。
    private struct CodexScanCache { let mtime: Date; let size: Int; let dayTokens: [String: Int]; let parent: String? }
    nonisolated(unsafe) private static var codexCache: [String: CodexScanCache] = [:]
    private static let codexCacheLock = NSLock()

    /// 单文件信息：近 7 天天桶 + 父任务 id（缓存按 mtime+size 失效；天粒度过滤误差 ≤1 天，估算够用）
    private static func codexFileInfo(_ url: URL) -> (buckets: [String: Int], parent: String?) {
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = rv?.contentModificationDate ?? .distantPast
        let size = rv?.fileSize ?? 0
        codexCacheLock.lock()
        let cached = codexCache[url.path]
        codexCacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size {
            return (cached.dayTokens, cached.parent)
        }
        let buckets = scanCodexDayBuckets(url)
        let parent = codexParentThreadId(url)
        codexCacheLock.lock()
        codexCache[url.path] = CodexScanCache(mtime: mtime, size: size, dayTokens: buckets, parent: parent)
        codexCacheLock.unlock()
        return (buckets, parent)
    }

    /// 子代理文件的父任务 id：session_meta（首行）的 parent_thread_id；普通会话返回 nil
    private static func codexParentThreadId(_ url: URL) -> String? {
        guard let head = readHead(url, bytes: 1024 * 1024),
              let first = head.split(separator: "\n", maxSplits: 1).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let parent = payload["parent_thread_id"] as? String, !parent.isEmpty else { return nil }
        return parent
    }

    private static let iso8601UTC = ISO8601DateFormatter()

    /// 全量流式扫描：按天聚合每条 token_count 事件的有效 token（(input−cached)+output）。
    /// 分块读 + 只对含 token_count 的行做 JSON 解析，200MB 亚秒级
    private static func scanCodexDayBuckets(_ url: URL) -> [String: Int] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? fh.close() }
        let needle = Data("token_count".utf8)
        let newline = UInt8(ascii: "\n")
        var buckets: [String: Int] = [:]
        var remainder = Data()
        while let chunk = try? fh.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            var data = remainder; data.append(chunk)
            var start = data.startIndex
            while let nl = data[start...].firstIndex(of: newline) {
                let line = data[start..<nl]
                start = data.index(after: nl)
                guard line.range(of: needle) != nil,
                      let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let last = findDict(key: "last_token_usage", in: obj) else { continue }
                let input = (last["input_tokens"] as? NSNumber)?.intValue ?? 0
                let cachedIn = (last["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
                let output = (last["output_tokens"] as? NSNumber)?.intValue ?? 0
                let eff = max(0, input - cachedIn) + output
                guard eff > 0, let ts = obj["timestamp"] as? String, ts.count >= 10 else { continue }
                buckets[String(ts.prefix(10)), default: 0] += eff
            }
            remainder = Data(data[start...])
        }
        return buckets
    }

    /// 递归找指定 key 的字典（包裹层级随 Codex 版本变化，不写死路径；找特定 key，不受字典遍历顺序影响）
    private static func findDict(key: String, in obj: Any) -> [String: Any]? {
        if let d = obj as? [String: Any] {
            if let hit = d[key] as? [String: Any] { return hit }
            for v in d.values { if let r = findDict(key: key, in: v) { return r } }
        } else if let a = obj as? [Any] {
            for v in a { if let r = findDict(key: key, in: v) { return r } }
        }
        return nil
    }

    // MARK: - 缓存释放

    /// 勾选变更时释放未勾选家的解析缓存（几 MB 级的条目数组即刻归还，
    /// 后续 MemoryRelief 把空闲大块还给内核）；勾选中的家缓存保留，重开零成本
    static func clearCaches(keeping enabled: Set<AgentKind>) {
        if !enabled.contains(.claude) {
            claudeCacheLock.lock(); claudeCache = [:]; claudeCacheLock.unlock()
        }
        if !enabled.contains(.codex) {
            codexCacheLock.lock(); codexCache = [:]; codexCacheLock.unlock()
        }
    }

    // MARK: - Top 5

    /// 排序取前 count（默认 5，大梁老师定：3 条太少），
    /// 占比 = 该任务 token ÷ 该服务近 7 天总 token × 周额度已用%
    static func top(_ items: [Scanned], count: Int = 5, weekUsedPercent: Double?, source: AgentSession.Source) -> [TaskUsage] {
        let total = items.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return [] }
        let used = weekUsedPercent ?? 0
        let threadNames = source == .codex ? loadCodexThreadNames() : [:]
        return items.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id > $1.id }.prefix(count).map { item in
            let name: String
            switch source {
            case .claude:
                name = item.claudeTitle ?? titleize(firstUserPrompt(item.url)) ?? "Claude 会话"
            case .codex:
                name = threadNames[String(item.id.suffix(36))] ?? codexProjectName(item.url) ?? "Codex 会话"
            }
            return TaskUsage(id: item.id, name: name, tokens: item.tokens,
                             percentOfTotal: Double(item.tokens) / Double(total) * used)
        }
    }

    // MARK: - 对话名读取

    private static func firstUserPrompt(_ url: URL) -> String? {
        guard let head = readHead(url, bytes: 16 * 1024) else { return nil }
        for raw in head.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any] else { continue }
            var candidate: String?
            if let s = msg["content"] as? String { candidate = s }
            else if let arr = msg["content"] as? [[String: Any]] {
                for b in arr where (b["type"] as? String) == "text" {
                    if let t = b["text"] as? String { candidate = t; break }
                }
            }
            if let c = candidate, let cleaned = cleanUserPrompt(c) { return cleaned }
            // 命令封装等非真人内容：继续找下一条 user
        }
        return nil
    }

    /// 首句兜底的清洗：斜杠命令调用在 transcript 里是 XML 封装
    /// （<command-message>…</command-message><command-name>/dbs-xhs-title</command-name>…），
    /// 原样当标题就是一坨标签。抽命令名当标题（自带 /，一眼知道是哪个技能）；
    /// 抽不出的标签内容返回 nil，让调用方继续找下一条真人消息
    static func cleanUserPrompt(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard t.hasPrefix("<") else { return t }
        if let name = tagContent("command-name", in: t) ?? tagContent("command-message", in: t) {
            return name.hasPrefix("/") ? name : "/" + name
        }
        return nil
    }

    private static func tagContent(_ tag: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(tag)>"),
              let close = s.range(of: "</\(tag)>", range: open.upperBound..<s.endIndex) else { return nil }
        let inner = s[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Codex 会话的项目名（turn_context / session_meta 的 cwd）——没 thread_name 时兜底。
    /// 先尾部找 turn_context；尾部没有（超长单轮把它挤出窗口）再读头部 512KB 找 session_meta，
    /// 与 AgentSessionsStore.parseCodex 同策略——否则兜出「Codex 会话」这种无信息名字
    private static func codexProjectName(_ url: URL) -> String? {
        if let tail = readTail(url, bytes: 64 * 1024) {
            for raw in tail.split(separator: "\n").reversed() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      obj["type"] as? String == "turn_context",
                      let payload = obj["payload"] as? [String: Any],
                      let cwd = payload["cwd"] as? String, !cwd.isEmpty else { continue }
                return (cwd as NSString).lastPathComponent
            }
        }
        if let head = readHead(url, bytes: 512 * 1024) {
            for raw in head.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let type = obj["type"] as? String, type == "session_meta" || type == "turn_context",
                      let payload = obj["payload"] as? [String: Any],
                      let cwd = payload["cwd"] as? String, !cwd.isEmpty else { continue }
                return (cwd as NSString).lastPathComponent
            }
        }
        return nil
    }

    private static func loadCodexThreadNames() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
            out[id] = name
        }
        return out
    }

    private static func titleize(_ text: String?) -> String? {
        guard var t = text?.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.count > 24 { t = String(t.prefix(24)) + "…" }
        return t
    }

    // MARK: - 文件读取

    private static func readTail(_ url: URL, bytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func readHead(_ url: URL, bytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
