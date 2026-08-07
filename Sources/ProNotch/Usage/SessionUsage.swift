import Foundation

/// 一个任务（会话）的额度消耗快照，供额度页 Top 5 用
struct TaskUsage: Identifiable, Sendable {
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

    struct Scanned {
        let id: String; let tokens: Int; let url: URL; var claudeTitle: String? = nil
        /// 按天 token（"2026-08-07" → token），供额度页的用量趋势柱状图
        var daily: [String: Int] = [:]
        /// 按模型 token（"gpt-5.6-sol" → token），供「最常用模型」
        var byModel: [String: Int] = [:]
    }

    /// 一家 Agent 近 7 天的用量画像：把各会话的天桶/模型桶并起来。
    /// 百分比只回答「还能用多久」，这里补上「吃了多少、哪天吃的、被哪个模型吃的」
    struct Profile: Sendable, Equatable {
        var daily: [String: Int] = [:]
        var byModel: [String: Int] = [:]

        /// 画像的窗口天数：与额度扫描窗口同宽。往前扩会画出假柱子——
        /// 扫描按文件 mtime 过滤，7 天没动过的文件根本不读，更早的日子必然缺数
        static let windowDays = 7

        /// 窗口内合计。必须严格按 series 取，不能拿 daily 全和：
        /// mtime 过滤放行的是「文件」不是「天」，一个 7 天内动过的长会话
        /// 会把它几个月前的天桶一起带进来，那样「近 7 天」这个标签就是假的
        /// （实测 Claude 全扫 48.5M，其中只有 41.9M 落在 7 天内）
        var total: Int { series(days: Self.windowDays).reduce(0) { $0 + $1.tokens } }
        /// 今日（按本地日历）token
        var today: Int { daily[Self.dayKey(Date())] ?? 0 }
        /// 吃 token 最多的模型；并列时取名字靠前的，保证显示稳定不跳
        var topModel: String? {
            byModel.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
        }
        /// 最近 `days` 天的桶，从早到晚补齐空档（没跑的日子是 0，不是缺一根柱子）
        func series(days: Int, now: Date = Date()) -> [(day: String, tokens: Int)] {
            (0..<days).reversed().map { back in
                let key = Self.dayKey(now.addingTimeInterval(-Double(back) * 86400))
                return (key, daily[key] ?? 0)
            }
        }

        static func merge(_ items: [Scanned]) -> Profile {
            var p = Profile()
            for s in items {
                for (d, t) in s.daily { p.daily[d, default: 0] += t }
                for (m, t) in s.byModel { p.byModel[m, default: 0] += t }
            }
            return p
        }

        /// 天桶的键：transcript 里的时间戳是 UTC，这里统一按 UTC 取前 10 位，
        /// 与各家 scan 落桶的口径一致（混用本地日历会让「今日」在时区偏移时错位）
        static func dayKey(_ date: Date) -> String {
            String(iso8601UTC.string(from: date).prefix(10))
        }

        /// 模型名的展示写法：claude-sonnet-4-5-20250929 → sonnet-4-5。
        /// 只砍厂商前缀和日期后缀这两段固定噪音，其余原样保留
        /// （gpt-5.6-sol、grok-4.5-build 这类本来就短，砍了反而认不出）
        static func shortModel(_ raw: String) -> String {
            var s = raw
            if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
            if let dash = s.lastIndex(of: "-") {
                let tail = s[s.index(after: dash)...]
                if tail.count == 8, tail.allSatisfy(\.isNumber) { s = String(s[s.startIndex..<dash]) }
            }
            // 砍到只剩一串数字就说明砍过头了（名字本身没别的信息），退回原样
            return s.isEmpty || s.allSatisfy(\.isNumber) ? raw : s
        }

        /// token 数的人读写法：24500000 → 24.5M。四位数以上一律缩写，
        /// 面板宽度只有 320pt，摆不下九位数字
        static func formatTokens(_ n: Int) -> String {
            let d = Double(n)
            if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
            if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
            if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
            return "\(n)"
        }
    }

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
        /// 这条消耗归哪个模型（transcript 里本来就带，原先读完只用来过滤前缀就扔了）
        var model: String? = nil
    }

    /// 与 Codex 侧 CodexScanCache 同一个方子（那边的注释是正文，这边只记差异）：
    /// resultX = 完整行 + 末尾残行；completeX 只含完整行，是续扫种子；
    /// scannedOffset 是最后一个换行符之后的绝对偏移
    private struct ClaudeScanCache {
        let mtime: Date
        let size: Int
        let resultEntries: [UsageEntry]
        let resultTitle: String?
        let completeEntries: [UsageEntry]
        let completeTitle: String?
        let scannedOffset: UInt64
    }
    nonisolated(unsafe) private static var claudeCache: [String: ClaudeScanCache] = [:]
    private static let claudeCacheLock = NSLock()
    /// 整读解析的累计次数（测试断言缓存命中用；refresh 单飞，无并发累加）
    nonisolated(unsafe) static var claudeParseCount = 0

    static func scanClaude(root: URL = defaultClaudeRoot, since: Date? = nil) -> [Scanned] {
        // 按条目时间过滤（不只按文件 mtime）：断续跑数周的长会话，只算近 7 天的条目，
        // 否则一生累计参与分摊会高估老会话（与 Codex 侧同一失真）。
        // `since`＝额度窗口起点，语义见 scanCodex(since:)
        let cutoff = max(Date().addingTimeInterval(-window), since ?? .distantPast)
        let cutoffDay = String(iso8601UTC.string(from: cutoff).prefix(10))
        return claudeFileScans(root: root).compactMap { file in
            var sum = 0, daily: [String: Int] = [:], byModel: [String: Int] = [:]
            for e in file.entries where e.day.map({ $0 >= cutoffDay }) ?? true {   // timestamp 缺失视为在窗内（沿旧口径）
                sum += e.tokens
                if let d = e.day { daily[d, default: 0] += e.tokens }   // 无日期的条目进不了趋势图，但仍计入总量
                if let m = e.model { byModel[m, default: 0] += e.tokens }
            }
            guard sum > 0 else { return nil }
            return Scanned(id: file.url.deletingPathExtension().lastPathComponent, tokens: sum,
                           url: file.url, claudeTitle: titleize(file.title),
                           daily: daily, byModel: byModel)
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
            // stat 不走 URL.resourceValues：它把结果缓存在 URL 值里，续扫判据要新鲜（Codex 侧同教训）
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let m = attrs[.modificationDate] as? Date, m > cutoff else { continue }
            seen.insert(url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            claudeCacheLock.lock()
            let cached = claudeCache[url.path]
            claudeCacheLock.unlock()
            if let cached, cached.mtime == m, cached.size == size {
                out.append((url, cached.resultEntries, cached.resultTitle))
                continue
            }
            // transcript 是只追加的日志：变长就从上次的换行处续扫，只读新增部分。
            // 变短或同长不同 mtime（被改写）→ 全量。每文件一个池，临时对象逐文件释放
            let incremental = cached.flatMap { c -> ClaudeScanCache? in
                (size > c.size && UInt64(size) >= c.scannedOffset) ? c : nil
            }
            let parsed = autoreleasepool {
                parseClaudeFile(url, cutoff: cutoff,
                                from: incremental?.scannedOffset ?? 0,
                                seedEntries: incremental?.completeEntries ?? [],
                                seedTitle: incremental?.completeTitle)
            }
            guard let parsed else {
                if let incremental { out.append((url, incremental.resultEntries, incremental.resultTitle)) }
                continue
            }
            claudeCacheLock.lock()
            claudeCache[url.path] = parsed
            claudeCacheLock.unlock()
            out.append((url, parsed.resultEntries, parsed.resultTitle))
        }
        // mtime 滑出 7 天窗的文件不会再被枚举，顺手清缓存防无限增长
        claudeCacheLock.lock()
        claudeCache = claudeCache.filter { seen.contains($0.key) }
        claudeCacheLock.unlock()
        return out
    }

    /// 解析单个 transcript（可从换行边界续扫）：有效 usage 条目 + 自定义标题（末条最新）。
    /// 条目按解析时刻的 7 天窗做日粒度粗过滤后入缓存——窗口只向前滑，
    /// 之后任何轮次需要的条目恒为本集子集（日粒度是精确窗口的超集，消费方再精筛），缓存窗口安全。
    ///
    /// 原实现 `String(contentsOf:)` 整读 + `split(separator:)` 整串咀嚼——刘海卡顿排查时
    /// 采样 24 秒它独占一条后台核（字符串下标自耗时全场第一，2026-07-31）。
    /// 现与 Codex 侧同方：FileHandle 分块 + memchr 切行 + memmem 粗筛，
    /// 只有含 usage / custom-title 的行才拷出来解析 JSON
    private static func parseClaudeFile(_ url: URL, cutoff: Date, from startOffset: UInt64,
                                        seedEntries: [UsageEntry],
                                        seedTitle: String?) -> ClaudeScanCache? {
        claudeParseCount += 1
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        if startOffset > 0 {
            guard (try? fh.seek(toOffset: startOffset)) != nil else { return nil }
        }
        let cutoffDay = String(iso8601UTC.string(from: cutoff).prefix(10))
        var entries = seedEntries
        var title = seedTitle
        var offsetAfterLastNewline = startOffset
        var filePos = startOffset
        var remainder = Data()
        let usageNeedle = [UInt8]("\"usage\"".utf8)
        let titleNeedle = [UInt8]("custom-title".utf8)
        while let chunk = try? fh.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            filePos += UInt64(chunk.count)
            var data = remainder
            data.append(chunk)
            var consumed = 0
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return }
                usageNeedle.withUnsafeBufferPointer { un in
                    titleNeedle.withUnsafeBufferPointer { tn in
                        guard let unBase = un.baseAddress, let tnBase = tn.baseAddress else { return }
                        var lineStart = 0
                        while lineStart < buf.count,
                              let hit = memchr(base + lineStart, 0x0A, buf.count - lineStart) {
                            let nl = UnsafeRawPointer(hit) - base
                            if nl > lineStart {
                                let len = nl - lineStart
                                if memmem(base + lineStart, len, unBase, un.count) != nil
                                    || memmem(base + lineStart, len, tnBase, tn.count) != nil {
                                    consumeClaudeLine(data.subdata(in: lineStart..<nl),
                                                      cutoffDay: cutoffDay,
                                                      into: &entries, title: &title)
                                }
                            }
                            lineStart = nl + 1
                        }
                        consumed = lineStart
                    }
                }
            }
            remainder = data.subdata(in: consumed..<data.count)
            offsetAfterLastNewline = filePos - UInt64(remainder.count)
        }
        // 末尾残行只进结果，不进基底（续扫从它的开头接着读，行补全后恰好算一次）
        var resultEntries = entries
        var resultTitle = title
        consumeClaudeLine(remainder, cutoffDay: cutoffDay, into: &resultEntries, title: &resultTitle)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ClaudeScanCache(mtime: attrs?[.modificationDate] as? Date ?? .distantPast,
                               size: (attrs?[.size] as? NSNumber)?.intValue ?? 0,
                               resultEntries: resultEntries, resultTitle: resultTitle,
                               completeEntries: entries, completeTitle: title,
                               scannedOffset: offsetAfterLastNewline)
    }

    /// 单行落账。粗筛在指针环里做过了，这里按原口径解析
    private static func consumeClaudeLine(_ line: Data, cutoffDay: String,
                                          into entries: inout [UsageEntry],
                                          title: inout String?) {
        guard !line.isEmpty else { return }
        // Claude Code 的会话标题（custom-title 行，末条最新）——比首句 prompt 更像「名字」
        if line.range(of: Data("custom-title".utf8)) != nil,
           let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           obj["type"] as? String == "custom-title",
           let t = obj["customTitle"] as? String, !t.isEmpty {
            title = t
            return
        }
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              line.range(of: Data("\"assistant\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let msg = obj["message"] as? [String: Any],
              let model = msg["model"] as? String,
              model.hasPrefix("claude-"),   // 只算官方模型，第三方中转不耗订阅
              let usage = msg["usage"] as? [String: Any] else { return }
        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
            .compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
        guard tokens > 0 else { return }
        let tsStr = obj["timestamp"] as? String
        let day = tsStr.map { String($0.prefix(10)) }
        if let day, day < cutoffDay { return }   // 窗外老条目不入缓存（timestamp 缺失保留，沿旧口径）
        entries.append(UsageEntry(day: day, ts: tsStr.flatMap { ISO8601Flex.parse($0) },
                                  tokens: tokens, model: model))
    }

    /// 仅测试用：清掉 Claude 文件缓存
    static func _resetClaudeCacheForTests() {
        claudeCacheLock.lock(); claudeCache.removeAll(); claudeCacheLock.unlock()
    }

    // MARK: - Codex：~/.codex/sessions/近 7 天/*.jsonl 读末条 token

    /// `since`：额度窗口的起点（重置时刻）。Top 5 的分账公式是「token 占比 × 已用%」，
    /// 分子分母必须同一段时间——固定往前推 7 天的话，重置前的老会话也来分当前额度，
    /// 把真正花额度的会话稀释掉（大梁老师 2026-08-03「Codex 严重不准」的病根：
    /// OpenAI 的 Pro Lite 只有一个 7 天窗，7/31 22:26 才重置，而 token 侧从 7/27 起算）。
    /// 不传则维持 7 天口径（额度端点没通时的退路）
    static var defaultCodexRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    static func scanCodex(root: URL = defaultCodexRoot, since: Date? = nil) -> [Scanned] {
        // 按 mtime 全量枚举，不能按日期目录扫最近几天：Codex 把 rollout 文件放在
        // 「会话开始日」的目录里持续追加数月——主力长会话（实测 05/31 目录 200MB 今天还在写）
        // 按日期目录扫必漏，Top 5 就只剩边角小会话
        let fm = FileManager.default
        // 窗口起点取「额度重置点」与「7 天前」中较晚者：既贴额度语义，又不放大扫描范围
        let cutoff = max(Date().addingTimeInterval(-window), since ?? .distantPast)
        var raw: [(scanned: Scanned, parent: String?)] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        // 每个文件一个池（return 即跳过该文件）：头尾分块读也有 MB 级临时串，逐文件释放
        for case let f as URL in en where f.pathExtension == "jsonl" {
            autoreleasepool {
            guard f.lastPathComponent.hasPrefix("rollout-"),
                  let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  m > cutoff else { return }
            let info = codexFileInfo(f)
            // 天桶按同一个 cutoff 过滤（天粒度，重置时刻所在的那天整天计入，误差 ≤1 天）
            let cutoffDay = String(iso8601UTC.string(from: cutoff).prefix(10))
            let daily = info.buckets.filter { $0.key >= cutoffDay }
            let tokens = daily.values.reduce(0, +)
            guard tokens > 0 else { return }
            // 模型桶按全文件占比折算到窗内 token：模型桶不带日期（模型与日期在两类行上），
            // 按天精确切分要把两类行的时序也存进缓存，代价不划算——只是选「最常用的那个」，比例足够
            let all = info.buckets.values.reduce(0, +)
            let byModel = all > 0
                ? info.models.mapValues { Int((Double($0) * Double(tokens) / Double(all)).rounded()) }
                : [:]
            raw.append((Scanned(id: f.deletingPathExtension().lastPathComponent, tokens: tokens, url: f,
                                daily: daily, byModel: byModel), info.parent))
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
        var dailyByRoot: [String: [String: Int]] = [:]
        var modelsByRoot: [String: [String: Int]] = [:]
        var repByRoot: [String: Scanned] = [:]   // 根任务的代表文件（优先根自己的，根不在窗口则用子代理的）
        for (s, _) in raw {
            let uuid = String(s.id.suffix(36))
            let r = rootUuid(uuid)
            tokensByRoot[r, default: 0] += s.tokens
            for (d, t) in s.daily { dailyByRoot[r, default: [:]][d, default: 0] += t }
            for (m, t) in s.byModel { modelsByRoot[r, default: [:]][m, default: 0] += t }
            if uuid == r { repByRoot[r] = s } else if repByRoot[r] == nil { repByRoot[r] = s }
        }
        return tokensByRoot.compactMap { r, tok in
            guard let rep = repByRoot[r] else { return nil }
            let daily = dailyByRoot[r] ?? [:], models = modelsByRoot[r] ?? [:]
            if String(rep.id.suffix(36)) == r {
                return Scanned(id: rep.id, tokens: tok, url: rep.url, daily: daily, byModel: models)
            }
            // 根文件本周没动、只有子代理在跑：合成 id（后 36 位 = 根 uuid，名字仍可查 index），cwd 同子代理
            return Scanned(id: "agg-\(r)", tokens: tok, url: rep.url, daily: daily, byModel: models)
        }
    }

    /// Codex 单文件：近 7 天的有效 token。逐条 token_count 事件求和（每事件带 timestamp +
    /// last_token_usage），只累加时间窗内的事件。不能读尾部 total_token_usage 累计值——
    /// 它是「会话一生」的累计（实测单调不清零）：05/31 起的老会话近 7 天只占其累计 22%，
    /// 按一生累计分摊会把老会话高估 4.6 倍。实测 Σ每轮 last ≈ 末条累计（偏差 <1%），逐事件求和可靠。
    /// 大文件（主力会话 200MB）的开销分两层兜：
    /// - mtime+size 全等 → 直接复用 resultTokens，零 IO；
    /// - 文件**变长**了（rollout 是只追加的日志）→ 从上次的换行处**续扫**，只读新增的几 KB。
    ///   completeTokens 是「只含完整行」的基底——上次的末尾残行故意不落在里面，
    ///   续扫从残行开头接着读，行补全后恰好算一次，不重不漏；
    /// - 变短或同长不同 mtime（被改写）→ 全量重扫。
    /// 此前只有第一层，主力会话每追加一笔就 200MB 从头重扫一遍，
    /// 一整个核被 `Data.firstIndex(of:)` 吃满（2026-07-31 采样自耗时榜第一，大梁老师叫修）
    private struct CodexScanCache {
        let mtime: Date
        let size: Int
        /// 完整行聚合＋末尾残行 ＝ 对外结果
        let resultTokens: [String: Int]
        let resultModels: [String: Int]
        /// 只含完整行的聚合，续扫的种子
        let completeTokens: [String: Int]
        let completeModels: [String: Int]
        /// 完整行读到头时「当前生效的模型」——model 写在 turn_context 行、消耗写在 token_count 行，
        /// 续扫从文件中段接着读时可能一条 turn_context 都碰不到，得把它带过去
        let completeModel: String?
        /// 最后一个换行符之后的绝对偏移，续扫起点
        let scannedOffset: UInt64
        let parent: String?
    }
    nonisolated(unsafe) private static var codexCache: [String: CodexScanCache] = [:]
    private static let codexCacheLock = NSLock()

    /// 单文件信息：近 7 天天桶 + 模型桶 + 父任务 id（缓存与续扫见 CodexScanCache；
    /// 天粒度过滤误差 ≤1 天，估算够用。internal 是为了测试续扫等于全扫）
    static func codexFileInfo(_ url: URL) -> (buckets: [String: Int], models: [String: Int], parent: String?) {
        // 不走 URL.resourceValues：它会把 stat 结果缓存在 URL 值里，同一个 URL 第二次
        // 问拿到的是旧数——续扫判据（mtime+size）必须每次都是新鲜的
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        codexCacheLock.lock()
        let cached = codexCache[url.path]
        codexCacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size {
            return (cached.resultTokens, cached.resultModels, cached.parent)
        }
        // 变长且旧偏移仍在文件内 → 追加式续扫；否则全量
        let incremental = cached.flatMap { c -> CodexScanCache? in
            (size > c.size && UInt64(size) >= c.scannedOffset) ? c : nil
        }
        guard let scan = scanCodexLines(url,
                                        from: incremental?.scannedOffset ?? 0,
                                        seed: incremental?.completeTokens ?? [:],
                                        seedModels: incremental?.completeModels ?? [:],
                                        seedModel: incremental?.completeModel) else {
            return (incremental?.resultTokens ?? [:], incremental?.resultModels ?? [:], incremental?.parent)
        }
        var result = scan.complete, resultModels = scan.completeModels, tailModel = scan.currentModel
        // 活跃会话最新一笔常是无换行的末行
        consumeCodexLine(scan.tail, model: &tailModel, into: &result, models: &resultModels)
        // parent 在首行、永不变：续扫沿用，全扫才读
        let parent = incremental.map(\.parent) ?? codexParentThreadId(url)
        codexCacheLock.lock()
        codexCache[url.path] = CodexScanCache(mtime: mtime, size: size,
                                              resultTokens: result,
                                              resultModels: resultModels,
                                              completeTokens: scan.complete,
                                              completeModels: scan.completeModels,
                                              completeModel: scan.currentModel,
                                              scannedOffset: scan.offsetAfterLastNewline,
                                              parent: parent)
        codexCacheLock.unlock()
        return (result, resultModels, parent)
    }

    /// 仅测试用：清掉 Codex 文件缓存，保证用例之间互不串味
    static func _resetCodexCacheForTests() {
        codexCacheLock.lock(); codexCache.removeAll(); codexCacheLock.unlock()
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

    /// 一次扫描的产物。complete 只含完整行；tail 是末尾没换行收尾的残行，
    /// **由调用方决定**要不要算进结果——续扫的正确性全靠残行不进基底
    struct CodexLineScan {
        var complete: [String: Int]
        var completeModels: [String: Int] = [:]
        /// 完整行读到头时生效的模型（续扫种子，语义见 CodexScanCache.completeModel）
        var currentModel: String?
        var offsetAfterLastNewline: UInt64
        var tail = Data()
    }

    /// 流式扫描（可从任意换行边界续扫）：按天聚合每条 token_count 事件的
    /// 有效 token（(input−cached)+output）。
    ///
    /// 行切分用 memchr、粗筛用 memmem——原来是 `Data.firstIndex(of:)` 逐字节走
    /// Collection 抽象，每字节一次索引换算，200MB 一遍就是几十亿次；换成 libc
    /// 的指针原语后同样一遍是内存带宽级别。只有含 token_count 的行才拷出来解析 JSON
    static func scanCodexLines(_ url: URL, from startOffset: UInt64,
                               seed: [String: Int],
                               seedModels: [String: Int] = [:],
                               seedModel: String? = nil) -> CodexLineScan? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        if startOffset > 0 {
            guard (try? fh.seek(toOffset: startOffset)) != nil else { return nil }
        }
        var scan = CodexLineScan(complete: seed, completeModels: seedModels,
                                 currentModel: seedModel, offsetAfterLastNewline: startOffset)
        var filePos = startOffset
        var remainder = Data()
        let needle = [UInt8]("token_count".utf8)
        // 模型写在另一类行（turn_context）里，得一起粗筛出来，否则 token 落桶时不知道算谁的
        let modelNeedle = [UInt8]("turn_context".utf8)
        while let chunk = try? fh.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            filePos += UInt64(chunk.count)
            var data = remainder
            data.append(chunk)
            var consumed = 0
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return }
                needle.withUnsafeBufferPointer { np in
                    modelNeedle.withUnsafeBufferPointer { mp in
                        guard let npBase = np.baseAddress, let mpBase = mp.baseAddress else { return }
                        var lineStart = 0
                        while lineStart < buf.count,
                              let hit = memchr(base + lineStart, 0x0A, buf.count - lineStart) {
                            let nl = UnsafeRawPointer(hit) - base
                            if nl > lineStart {
                                let len = nl - lineStart
                                if memmem(base + lineStart, len, npBase, np.count) != nil
                                    || memmem(base + lineStart, len, mpBase, mp.count) != nil {
                                    consumeCodexLine(data.subdata(in: lineStart..<nl),
                                                     model: &scan.currentModel,
                                                     into: &scan.complete, models: &scan.completeModels)
                                }
                            }
                            lineStart = nl + 1
                        }
                        consumed = lineStart
                    }
                }
            }
            remainder = data.subdata(in: consumed..<data.count)
            scan.offsetAfterLastNewline = filePos - UInt64(remainder.count)
        }
        scan.tail = remainder
        return scan
    }

    /// 单行落桶。两类行都从这儿过：turn_context 更新「当前模型」，token_count 落天桶+模型桶。
    /// 粗筛在指针环里做过了，这里再核一次关键词；残行也能直接喂
    private static func consumeCodexLine(_ line: Data, model: inout String?,
                                         into buckets: inout [String: Int],
                                         models: inout [String: Int]) {
        guard !line.isEmpty else { return }
        // 模型换挡：rollout 里 model 只写在 turn_context，之后的每笔消耗都算它的
        if line.range(of: Data("turn_context".utf8)) != nil,
           let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           obj["type"] as? String == "turn_context",
           let payload = obj["payload"] as? [String: Any],
           let m = payload["model"] as? String, !m.isEmpty {
            model = m
            return
        }
        guard line.range(of: Data("token_count".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let last = findDict(key: "last_token_usage", in: obj) else { return }
        let input = (last["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cachedIn = (last["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (last["output_tokens"] as? NSNumber)?.intValue ?? 0
        let eff = max(0, input - cachedIn) + output
        guard eff > 0, let ts = obj["timestamp"] as? String, ts.count >= 10 else { return }
        buckets[String(ts.prefix(10)), default: 0] += eff
        if let m = model { models[m, default: 0] += eff }   // 首个 turn_context 之前的消耗归不了模型，只计入天桶
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

    // MARK: - Kimi(~/.kimi-code/sessions/<工作区>/session_<uuid>/agents/<agent>/wire.jsonl)

    static var defaultKimiRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code/sessions")
    }

    /// 逐条 usage.record 求和，口径与 Claude/Codex 一致：只算非缓存 input + output。
    /// 缓存读必须扣——实测一个 323 条记录的会话含缓存 5636 万、扣掉才 86 万，
    /// 不扣的话单个对话在榜上能显示成几千万 token，整个榜失真。
    /// 文件小（实测最大 1.9MB）故整读，不像 Codex/Grok 那样需要流式
    static func scanKimi(root: URL = defaultKimiRoot) -> [Scanned] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-window)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        // 主代理 agents/main 与子代理 agents/agent-N 各写各的 wire.jsonl，按 session_ 目录归并：
        // 同一任务的并行子代理不该在榜上占成多行（与 Codex 侧 parent_thread_id 归并同一诉求，
        // 这里天然同目录，不必上溯）
        var tokensBySession: [String: Int] = [:]
        var dailyBySession: [String: [String: Int]] = [:]
        var modelsBySession: [String: [String: Int]] = [:]
        var urlBySession: [String: URL] = [:]
        for case let url as URL in en where url.lastPathComponent == "wire.jsonl" {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  m > cutoff,
                  let sid = url.pathComponents.last(where: { $0.hasPrefix("session_") }) else { continue }
            let f = kimiFileTokens(url, cutoff: cutoff)
            guard f.sum > 0 else { continue }
            tokensBySession[sid, default: 0] += f.sum
            for (d, t) in f.daily { dailyBySession[sid, default: [:]][d, default: 0] += t }
            for (mm, t) in f.byModel { modelsBySession[sid, default: [:]][mm, default: 0] += t }
            // 代表文件优先取主代理的（拿标题/项目名时更靠谱）
            if urlBySession[sid] == nil || url.pathComponents.contains("main") { urlBySession[sid] = url }
        }
        return tokensBySession.compactMap { sid, tok in
            urlBySession[sid].map {
                Scanned(id: sid, tokens: tok, url: $0,
                        daily: dailyBySession[sid] ?? [:], byModel: modelsBySession[sid] ?? [:])
            }
        }
    }

    private static func kimiFileTokens(_ url: URL, cutoff: Date) -> (sum: Int, daily: [String: Int], byModel: [String: Int]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (0, [:], [:]) }
        var sum = 0, daily: [String: Int] = [:], byModel: [String: Int] = [:]
        for line in text.split(separator: "\n") where line.contains("usage.record") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "usage.record",
                  let u = obj["usage"] as? [String: Any] else { continue }
            // time 为毫秒时间戳；缺失视为在窗内（沿 Claude 侧口径）
            var day: String?
            if let ms = (obj["time"] as? NSNumber)?.doubleValue {
                let at = Date(timeIntervalSince1970: ms / 1000)
                if at < cutoff { continue }
                day = Profile.dayKey(at)
            }
            let inOther = (u["inputOther"] as? NSNumber)?.intValue ?? 0
            let out = (u["output"] as? NSNumber)?.intValue ?? 0
            let eff = inOther + out
            guard eff > 0 else { continue }
            sum += eff
            if let day { daily[day, default: 0] += eff }
            // model 与消耗写在同一条记录里（形如 "kimi-code/k3"），去掉厂商前缀只留模型名
            if let m = obj["model"] as? String, !m.isEmpty {
                byModel[String(m.split(separator: "/").last ?? Substring(m)), default: 0] += eff
            }
        }
        return (sum, daily, byModel)
    }

    // MARK: - Grok(~/.grok/sessions/<项目>/<会话 uuid>/updates.jsonl)

    static var defaultGrokRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/sessions")
    }

    /// turn_completed 事件带整轮 usage 汇总（numTurns/modelCalls 随之给出），逐条求和。
    /// 踩过两个坑，都会算出看着「合理」实则错的数：
    /// ① 不能用 _meta.totalTokens——那是上下文窗口占用（同一会话实测 55049），
    ///    turn_completed.usage 才是真实消耗（901657），差 16 倍且低估方向不易察觉；
    /// ② 同一会话 uuid 会出现在多个项目目录下（实测有），按目录累加等于同一笔算两次，
    ///    故按 uuid 取记录最全的一份而非求和。
    /// 单文件实测可达 56MB，必须流式分块读（整读会成为 App 最大瞬时分配源）
    static func scanGrok(root: URL = defaultGrokRoot) -> [Scanned] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-window)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        var best: [String: (scan: GrokFileScan, url: URL)] = [:]
        for case let url as URL in en where url.lastPathComponent == "updates.jsonl" {
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let m = rv.contentModificationDate, m > cutoff else { continue }
            let sid = url.deletingLastPathComponent().lastPathComponent
            let scan = grokFileTokens(url, mtime: m, size: rv.fileSize ?? 0, cutoff: cutoff)
            guard scan.sum > 0, best[sid]?.scan.sum ?? -1 < scan.sum else { continue }
            best[sid] = (scan, url)
        }
        return best.map {
            Scanned(id: $0.key, tokens: $0.value.scan.sum, url: $0.value.url,
                    daily: $0.value.scan.daily, byModel: $0.value.scan.byModel)
        }
    }

    struct GrokFileScan { var sum = 0; var daily: [String: Int] = [:]; var byModel: [String: Int] = [:] }
    private struct GrokScanCache { let mtime: Date; let size: Int; let scan: GrokFileScan }
    nonisolated(unsafe) private static var grokCache: [String: GrokScanCache] = [:]
    private static let grokCacheLock = NSLock()

    /// 流式扫描单个 updates.jsonl（照 Codex 侧同款：分块读 + 只对含关键词的行做 JSON 解析），
    /// 结果按 mtime+size 缓存——历史会话写完就不再变，每轮真正要重读的只有活跃那一两个
    private static func grokFileTokens(_ url: URL, mtime: Date, size: Int, cutoff: Date) -> GrokFileScan {
        grokCacheLock.lock()
        let cached = grokCache[url.path]
        grokCacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size { return cached.scan }

        var out = GrokFileScan()
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            let needle = Data("turn_completed".utf8)
            let newline = UInt8(ascii: "\n")
            var remainder = Data()
            func consume(_ line: Data) {
                guard line.range(of: needle) != nil,
                      let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let update = (obj["params"] as? [String: Any])?["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "turn_completed",
                      let u = update["usage"] as? [String: Any] else { return }
                // 外层 timestamp 为秒级；缺失视为在窗内
                var day: String?
                if let ts = (obj["timestamp"] as? NSNumber)?.doubleValue {
                    let at = Date(timeIntervalSince1970: ts)
                    if at < cutoff { return }
                    day = Profile.dayKey(at)
                }
                let input = (u["inputTokens"] as? NSNumber)?.intValue ?? 0
                let cachedRead = (u["cachedReadTokens"] as? NSNumber)?.intValue ?? 0
                let output = (u["outputTokens"] as? NSNumber)?.intValue ?? 0
                let eff = max(0, input - cachedRead) + output
                guard eff > 0 else { return }
                out.sum += eff
                if let day { out.daily[day, default: 0] += eff }
                // Grok 自己就按模型拆好了（usage.modelUsage）；同口径重算一遍各模型的有效 token
                if let byModel = u["modelUsage"] as? [String: [String: Any]] {
                    for (name, mu) in byModel {
                        let i = (mu["inputTokens"] as? NSNumber)?.intValue ?? 0
                        let c = (mu["cachedReadTokens"] as? NSNumber)?.intValue ?? 0
                        let o = (mu["outputTokens"] as? NSNumber)?.intValue ?? 0
                        let e = max(0, i - c) + o
                        if e > 0 { out.byModel[name, default: 0] += e }
                    }
                }
            }
            while let chunk = try? fh.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                autoreleasepool {
                    var data = remainder; data.append(chunk)
                    var start = data.startIndex
                    while let nl = data[start...].firstIndex(of: newline) {
                        consume(data[start..<nl])
                        start = data.index(after: nl)
                    }
                    remainder = Data(data[start...])
                }
            }
            consume(remainder)   // 末行没有换行结尾时，最后一条记录只在这里——漏掉的正是最新那笔
        }
        grokCacheLock.lock()
        grokCache[url.path] = GrokScanCache(mtime: mtime, size: size, scan: out)
        grokCacheLock.unlock()
        return out
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
        if !enabled.contains(.grok) {
            grokCacheLock.lock(); grokCache = [:]; grokCacheLock.unlock()
        }
    }

    // MARK: - Top 5

    /// 排序取前 count（默认 5，大梁老师定：3 条太少），
    /// 占比 = 该任务 token ÷ 该服务近 7 天总 token × 周额度已用%
    static func top(_ items: [Scanned], count: Int = 5, weekUsedPercent: Double?, source: AgentKind) -> [TaskUsage] {
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
            case .kimi:
                name = titleize(kimiFirstPrompt(item.url)) ?? "Kimi 会话"
            case .grok:
                name = titleize(grokTitle(item.url)) ?? "Grok 会话"
            }
            return TaskUsage(id: item.id, name: name, tokens: item.tokens,
                             percentOfTotal: Double(item.tokens) / Double(total) * used)
        }
    }

    // MARK: - 对话名读取

    /// Kimi 对话名：首条 turn.prompt 的文本（input 是 [{type,text}] 数组，结构同 Grok 的 user）。
    /// 读 256KB 而非 64KB——首条 prompt 前面压着 llm.tools_snapshot（全量工具定义，几十 KB）
    private static func kimiFirstPrompt(_ url: URL) -> String? {
        guard let head = readHead(url, bytes: 256 * 1024) else { return nil }
        for raw in head.split(separator: "\n") where raw.contains("turn.prompt") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  obj["type"] as? String == "turn.prompt",
                  let input = obj["input"] as? [[String: Any]],
                  let text = input.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            else { continue }
            if let clean = cleanUserPrompt(text) { return clean }
        }
        return nil
    }

    /// Grok 对话名：同目录 summary.json 的 session_summary；实测 Grok 不自动命名、该字段多为空，
    /// 故回退 chat_history 首句 prompt（与监控台同口径）
    private static func grokTitle(_ updatesURL: URL) -> String? {
        let dir = updatesURL.deletingLastPathComponent()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("summary.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["session_summary"] as? String, !s.isEmpty { return s }
        guard let head = readHead(dir.appendingPathComponent("chat_history.jsonl"), bytes: 16 * 1024) else { return nil }
        for raw in head.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  let content = obj["content"] as? [[String: Any]],
                  let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            else { continue }
            if let clean = cleanUserPrompt(text) { return clean }
        }
        return nil
    }

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
