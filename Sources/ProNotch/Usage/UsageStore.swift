import Foundation
import Security

/// AI 编码工具额度：一个限额窗口的状态
struct QuotaWindow {
    var usedPercent: Double?     // 已用百分比（nil=未知）
    var usedTokens: Int?         // 已用 token 数（Claude 估算路线用）
    var resetsAt: Date?          // 窗口重置时间
    var windowMinutes: Int       // 窗口长度（300=5小时，10080=7天）
    var isEstimate: Bool         // true=本地估算（非官方数字）

    /// 窗口时长显示名，按真实分钟数生成——服务商改窗口（如 Codex 取消 5 小时窗只留周额度）标签自动跟上
    var label: String {
        if windowMinutes >= 1440 { return "\(windowMinutes / 1440) 天" }
        if windowMinutes >= 60 { return "\(windowMinutes / 60) 小时" }
        return "\(windowMinutes) 分钟"
    }
}

/// 一个服务（Claude Code / Codex）的额度快照
struct ServiceQuota {
    var plan: String?            // 订阅计划名
    var account: String?         // 账号标识（多账号切换时确认数据归属）
    var primary: QuotaWindow?    // 5 小时窗
    var secondary: QuotaWindow?  // 7 天窗
    var dataAt: Date?            // 数据时间（源文件里最后一条记录的时间）
    var error: String?           // 拿不到数据时的原因
}

/// 额度页数据源：读本机 Claude Code / Codex CLI 的会话文件取实时额度。
/// - Codex：session JSONL 里带官方返回的 rate_limits（used_percent/resets_at），精确；
/// - Claude：优先 OAuth 用量接口（凭据在则精确），否则按 transcript 的 token 用量本地估算（标注 ≈）。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codex: ServiceQuota?
    @Published private(set) var claude: ServiceQuota?
    @Published private(set) var grok: ServiceQuota?
    @Published private(set) var refreshing = false
    private var lastRefresh: Date = .distantPast

    /// 刷新（30 秒节流，force 忽略节流）。文件扫描在后台线程，主线程只收结果
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 30 else { return }
        guard !refreshing else { return }
        lastRefresh = Date()
        refreshing = true
        Task.detached(priority: .utility) {
            let cx = await CodexQuotaLoader.load()
            let cl = await ClaudeQuotaLoader.load()
            let gr = await GrokQuotaLoader.load()
            await MainActor.run { [weak self] in
                self?.codex = cx
                self?.claude = cl
                self?.grok = gr
                self?.refreshing = false
            }
        }
    }
}

// MARK: - Grok：读 ~/.grok CLI 日志里的 creditUsagePercent（周额度）

enum GrokQuotaLoader {
    /// grok CLI 把用量记在 ~/.grok/logs/unified.jsonl：每次刷新写一条含
    /// creditUsagePercent / billingPeriodEnd / subscriptionTier。读尾部取最新一条即可，不必调 API。
    static func load() async -> ServiceQuota {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/logs/unified.jsonl")
        guard let tail = readTail(log, bytes: 1_500_000) else {
            return ServiceQuota(error: "未找到 Grok 日志（~/.grok/logs）")
        }
        var used: Double?, resetAt: Date?, tier: String?
        for line in tail.split(separator: "\n").reversed() where line.contains("creditUsagePercent") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
            if used == nil, let d = firstDouble(key: "creditUsagePercent", in: obj) { used = d }
            if resetAt == nil, let s = firstString(key: "billingPeriodEnd", in: obj) { resetAt = ISO8601Flex.parse(s) }
            if tier == nil, let s = firstString(key: "subscriptionTier", in: obj) { tier = s }
            if used != nil { break }
        }
        guard let used else { return ServiceQuota(error: "Grok 暂无额度记录，用一次 grok 即可") }
        var q = ServiceQuota()
        q.plan = tier
        q.dataAt = Date()
        q.primary = QuotaWindow(usedPercent: used, usedTokens: nil, resetsAt: resetAt,
                                windowMinutes: 10080, isEstimate: false)   // 周额度窗
        return q
    }

    private static func readTail(_ url: URL, bytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 递归找某 key 的 Double / String（credit 与 tier 在同一行的不同子对象里）
    private static func firstDouble(key: String, in obj: Any) -> Double? {
        if let d = obj as? [String: Any] {
            if let n = d[key] as? NSNumber { return n.doubleValue }
            for v in d.values { if let r = firstDouble(key: key, in: v) { return r } }
        } else if let a = obj as? [Any] {
            for v in a { if let r = firstDouble(key: key, in: v) { return r } }
        }
        return nil
    }
    private static func firstString(key: String, in obj: Any) -> String? {
        if let d = obj as? [String: Any] {
            if let s = d[key] as? String { return s }
            for v in d.values { if let r = firstString(key: key, in: v) { return r } }
        } else if let a = obj as? [Any] {
            for v in a { if let r = firstString(key: key, in: v) { return r } }
        }
        return nil
    }
}

// MARK: - Codex：读最新 session 的官方 rate_limits

enum CodexQuotaLoader {
    static func load() async -> ServiceQuota {
        // 首选官方实时端点：当前登录账号的准确额度（多账号 cc-switch 切换也不串号）。
        // 实测同机 session 历史混着多个账号的 rate_limits（7 天窗同日 2%→16%→1% 跳变），
        // 只有官方端点能保证「数字属于当前账号且是此刻的」
        if let q = await fetchOfficialUsage() { return q }
        // 降级（离线/token 失效）：session 记录里只取本次登录之后的——auth.json 的修改时间
        // 即上次登录/切号时间，之前的记录可能属于别的账号
        return loadFromSessions()
    }

    /// ChatGPT 官方用量端点（Codex Web 同源）：auth.json 的 access_token 直接查
    private static func fetchOfficialUsage() async -> ServiceQuota? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (body, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rl = json["rate_limit"] as? [String: Any] else { return nil }
        var q = ServiceQuota()
        q.plan = json["plan_type"] as? String
        q.account = json["email"] as? String
        q.dataAt = Date()
        if let p = rl["primary_window"] as? [String: Any] { q.primary = officialWindow(p) }
        if let s = rl["secondary_window"] as? [String: Any] { q.secondary = officialWindow(s) }
        guard q.primary != nil || q.secondary != nil else { return nil }
        return q
    }

    private static func officialWindow(_ d: [String: Any]) -> QuotaWindow {
        QuotaWindow(usedPercent: (d["used_percent"] as? NSNumber)?.doubleValue,
                    usedTokens: nil,
                    resetsAt: (d["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    windowMinutes: ((d["limit_window_seconds"] as? NSNumber)?.intValue ?? 18000) / 60,
                    isEstimate: false)
    }

    private static func loadFromSessions() -> ServiceQuota {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".codex/sessions")
        guard let latest = latestSessionFile(root) else {
            return ServiceQuota(error: "未找到 Codex 会话数据（~/.codex/sessions）")
        }
        guard let hit = lastRateLimits(in: latest) else {
            return ServiceQuota(error: "最近会话里没有额度记录")
        }
        // 记录早于上次登录/切号（auth.json 修改时间）→ 可能是别的账号的数字，宁缺毋滥
        let authMtime = (try? home.appendingPathComponent(".codex/auth.json")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let ts = hit.timestamp, let am = authMtime, ts < am {
            return ServiceQuota(error: "切换账号后暂无额度记录，用一次 Codex 即可")
        }
        var q = ServiceQuota()
        q.plan = hit.limits["plan_type"] as? String
        q.dataAt = hit.timestamp
        if let p = hit.limits["primary"] as? [String: Any] { q.primary = window(p) }
        if let s = hit.limits["secondary"] as? [String: Any] { q.secondary = window(s) }
        return q
    }

    private static func window(_ d: [String: Any]) -> QuotaWindow {
        QuotaWindow(usedPercent: (d["used_percent"] as? NSNumber)?.doubleValue,
                    usedTokens: nil,
                    resetsAt: (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    windowMinutes: (d["window_minutes"] as? NSNumber)?.intValue ?? 300,
                    isEstimate: false)
    }

    /// sessions/YYYY/MM/DD/rollout-*.jsonl：目录名可排序，从最新日期目录往回找最近修改的文件
    private static func latestSessionFile(_ root: URL) -> URL? {
        let fm = FileManager.default
        func sortedDesc(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        for y in sortedDesc(root) where y.hasDirectoryPath {
            for m in sortedDesc(y) where m.hasDirectoryPath {
                for d in sortedDesc(m) where d.hasDirectoryPath {
                    let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                        .filter { $0.pathExtension == "jsonl" }
                        .sorted { (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast) }
                    // 最新文件可能刚建还没写入 rate_limits，多备两个候选
                    if !files.isEmpty { return files.first }
                }
            }
        }
        return nil
    }

    private static func mtime(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 从文件尾部往前找最后一条 rate_limits 记录（只读末尾 256KB，会话文件可能很大）
    private static func lastRateLimits(in url: URL) -> (limits: [String: Any], timestamp: Date?)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readLen: UInt64 = min(size, 256 * 1024)
        try? fh.seek(toOffset: size - readLen)
        guard let data = try? fh.read(upToCount: Int(readLen)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = findDict(key: "rate_limits", in: obj) else { continue }
            let ts = (obj["timestamp"] as? String).flatMap { ISO8601Flex.parse($0) }
            return (limits, ts ?? mtime(url))
        }
        return nil
    }

    /// 递归找嵌套字典里的某个键（rate_limits 的包裹层级随 Codex 版本变化，不写死路径）
    private static func findDict(key: String, in obj: Any) -> [String: Any]? {
        guard let dict = obj as? [String: Any] else { return nil }
        if let hit = dict[key] as? [String: Any] { return hit }
        for v in dict.values {
            if let hit = findDict(key: key, in: v) { return hit }
        }
        return nil
    }
}

// MARK: - Claude：OAuth 接口优先，降级为 transcript 本地估算

enum ClaudeQuotaLoader {
    static func load() async -> ServiceQuota {
        // 路线 A：claude.ai 官方额度端点（用 Claude 桌面端的会话 cookie）——和客户端看到的分毫不差
        if let q = await fetchWebUsage() {
            return q
        }
        // 路线 B：Claude Code CLI 的 OAuth 用量接口（凭据可读时）
        if let token = oauthToken(), var q = await fetchOAuthUsage(token) {
            q.plan = q.plan ?? planName()
            return q
        }
        // 路线 C：本地估算（无桌面端 / 未授权钥匙串时兜底）
        var q = estimateFromTranscripts()
        if q.error == nil { q.account = accountEmail() }
        return q
    }

    /// 路线 A：解密 CCD 的 claude.ai sessionKey → 调 /api/organizations/{org}/usage，
    /// 返回 five_hour/seven_day 的 utilization（官方口径百分比）
    private static func fetchWebUsage() async -> ServiceQuota? {
        guard let org = organizationUUID(),
              let cookies = CCDCookieReader.claudeAICookies(),
              let url = URL(string: "https://claude.ai/api/organizations/\(org)/usage") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        var cookie = "sessionKey=\(cookies.sessionKey)"
        if let cf = cookies.cfClearance { cookie += "; cf_clearance=\(cf)" }
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Claude/1.0 Chrome/120 Electron/28 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ d: [String: Any]?, minutes: Int) -> QuotaWindow? {
            guard let d else { return nil }
            let pct = (d["utilization"] as? NSNumber)?.doubleValue
            let resets = (d["resets_at"] as? String).flatMap { ISO8601Flex.parse($0) }
            return QuotaWindow(usedPercent: pct, usedTokens: nil, resetsAt: resets, windowMinutes: minutes, isEstimate: false)
        }
        var q = ServiceQuota()
        q.primary = window(obj["five_hour"] as? [String: Any], minutes: 300)
        q.secondary = window(obj["seven_day"] as? [String: Any], minutes: 10080)
        q.plan = planName()
        q.account = accountEmail()
        q.dataAt = Date()
        guard q.primary != nil || q.secondary != nil else { return nil }
        return q
    }

    private static func organizationUUID() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        return account["organizationUuid"] as? String
    }

    private static func accountEmail() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    /// 已知的凭据位置逐个试：credentials 文件 → 钥匙串
    private static func oauthToken() -> String? {
        let credURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        for service in ["Claude Code-credentials", "Claude Code"] {
            if let raw = KeychainStore.readService(service),
               let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let oauth = obj["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func fetchOAuthUsage(_ token: String) async -> ServiceQuota? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ d: [String: Any]?, minutes: Int) -> QuotaWindow? {
            guard let d else { return nil }
            let pct = (d["utilization"] as? NSNumber)?.doubleValue
            let resets = (d["resets_at"] as? String).flatMap { ISO8601Flex.parse($0) }
            return QuotaWindow(usedPercent: pct, usedTokens: nil, resetsAt: resets, windowMinutes: minutes, isEstimate: false)
        }
        var q = ServiceQuota()
        q.primary = window(obj["five_hour"] as? [String: Any], minutes: 300)
        q.secondary = window(obj["seven_day"] as? [String: Any], minutes: 10080)
        q.dataAt = Date()
        guard q.primary != nil || q.secondary != nil else { return nil }
        return q
    }

    private static func planName() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        let tier = (account["organizationRateLimitTier"] as? String) ?? (account["organizationType"] as? String) ?? ""
        if tier.contains("max_20") { return "Max 20x" }
        if tier.contains("max_5") || tier.contains("claude_max") { return "Max 5x" }
        if tier.contains("pro") { return "Pro" }
        return nil
    }

    /// Claude 桌面端的官方用量采样（打开用量面板时每 5 分钟记一条 fh=5小时窗%、sd=7天窗%）
    private struct CCDSample { let t: TimeInterval; let fh: Double?; let sd: Double? }

    private static func ccdSamples() -> [CCDSample] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]] else { return [] }
        return samples.compactMap { s in
            guard let t = (s["t"] as? NSNumber)?.doubleValue,
                  let u = s["u"] as? [String: Any] else { return nil }
            return CCDSample(t: t / 1000,
                             fh: (u["fh"] as? NSNumber)?.doubleValue,
                             sd: (u["sd"] as? NSNumber)?.doubleValue)
        }.sorted { $0.t < $1.t }
    }

    /// 校准系数（%/token）：把官方采样时刻回放到 transcript 的 5h 块累计上，
    /// ratio=官方fh%÷该刻块tokens。实测同账号 46 个样本 ratio 稳定在中位数 ±40% 内，
    /// 取中位数把实时块 tokens 换算成百分比——官方口径按模型加权成本，纯 token 基线不可行
    private static func calibratedRatio(_ samples: [CCDSample], entries: [(ts: Date, tokens: Int)]) -> Double? {
        var ratios: [Double] = []
        var bs: TimeInterval?; var btok = 0; var last: TimeInterval?
        var si = 0
        func consumeSamples(upTo t: TimeInterval) {
            while si < samples.count, samples[si].t <= t {
                let s = samples[si]; si += 1
                guard let fh = s.fh, fh >= 5 else { continue }              // 小百分比噪声大，不进校准
                if let b = bs, s.t < b + 18000, btok > 10000 {              // 样本落在当时的 5h 块内
                    ratios.append(fh / Double(btok))
                }
            }
        }
        for e in entries {
            let t = e.ts.timeIntervalSince1970
            consumeSamples(upTo: t)
            if let b = bs, let l = last, t < b + 18000, t - l < 18000 { btok += e.tokens }
            else { bs = (t / 3600).rounded(.down) * 3600; btok = e.tokens }
            last = t
        }
        consumeSamples(upTo: .greatestFiniteMagnitude)
        guard ratios.count >= 3 else { return nil }
        return ratios.sorted()[ratios.count / 2]
    }

    /// 本地路线：transcript 按 ccusage 的 5 小时活动块口径聚合 + 桌面端官方采样融合。
    /// 5h 窗三级：官方样本 ≤45 分钟直接用 → 陈旧则用校准系数把实时块 tokens 换算成 ≈百分比
    /// → 无采样文件退回纯 token 数。7d 窗：官方样本 ≤3 天直接用（变化慢，标 ≈），否则 token 总量
    private static func estimateFromTranscripts() -> ServiceQuota {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        var entries: [(ts: Date, tokens: Int)] = []   // 近 7 天全部用量点
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ServiceQuota(error: "未找到 Claude Code 数据（~/.claude/projects）")
        }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  m > weekAgo else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                // 粗筛降成本：只有带 usage 的 assistant 行才 JSON 解析
                guard line.contains("\"usage\""), line.contains("\"assistant\"") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let tsStr = obj["timestamp"] as? String,
                      let ts = ISO8601Flex.parse(tsStr), ts > weekAgo,
                      let msg = obj["message"] as? [String: Any],
                      (msg["model"] as? String)?.hasPrefix("claude-") == true,   // 只算官方模型，第三方中转不耗订阅额度
                      let usage = msg["usage"] as? [String: Any] else { continue }
                // 不含 cache_read：缓存读千倍灌水（实测 7 天 3.1G vs 不含 121M），且官方计价权重极低
                let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
                    .compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
                if tokens > 0 { entries.append((ts, tokens)) }
            }
        }
        guard !entries.isEmpty else {
            return ServiceQuota(plan: planName(), error: "近 7 天没有使用记录")
        }
        entries.sort { $0.ts < $1.ts }
        // 5 小时活动块（ccusage 口径）：块起点=首条消息 floor 到整点，超窗或断档 5h 即开新块
        var blockStart: Date?
        var blockTokens = 0
        var lastTs: Date?
        for e in entries {
            if let s = blockStart, let l = lastTs,
               e.ts < s.addingTimeInterval(5 * 3600), e.ts.timeIntervalSince(l) < 5 * 3600 {
                blockTokens += e.tokens
            } else {
                blockStart = floorToHour(e.ts)
                blockTokens = e.tokens
            }
            lastTs = e.ts
        }
        var q = ServiceQuota()
        q.plan = planName()
        q.dataAt = entries.last?.ts
        let samples = ccdSamples()
        let inBlock = blockStart.map { now < $0.addingTimeInterval(5 * 3600) } ?? false
        let resets = inBlock ? blockStart?.addingTimeInterval(5 * 3600) : nil
        let curTokens = inBlock ? blockTokens : 0
        // 5 小时窗三级
        if let last = samples.last, let fh = last.fh, now.timeIntervalSince1970 - last.t < 45 * 60 {
            q.primary = QuotaWindow(usedPercent: fh, usedTokens: curTokens,
                                    resetsAt: resets, windowMinutes: 300, isEstimate: false)
        } else if let ratio = calibratedRatio(samples, entries: entries) {
            q.primary = QuotaWindow(usedPercent: min(99, Double(curTokens) * ratio),
                                    usedTokens: curTokens,
                                    resetsAt: resets, windowMinutes: 300, isEstimate: true)
        } else {
            q.primary = QuotaWindow(usedPercent: nil, usedTokens: curTokens,
                                    resetsAt: resets, windowMinutes: 300, isEstimate: true)
        }
        // 7 天窗：官方样本 3 天内直接用（周窗变化慢仍有参考值，非当刻数据标 ≈）
        if let sdSample = samples.last(where: { $0.sd != nil }), let sd = sdSample.sd,
           now.timeIntervalSince1970 - sdSample.t < 3 * 86400 {
            q.secondary = QuotaWindow(usedPercent: sd, usedTokens: nil, resetsAt: nil,
                                      windowMinutes: 10080,
                                      isEstimate: now.timeIntervalSince1970 - sdSample.t > 45 * 60)
        } else {
            q.secondary = QuotaWindow(usedPercent: nil,
                                      usedTokens: entries.reduce(0) { $0 + $1.tokens },
                                      resetsAt: nil, windowMinutes: 10080, isEstimate: true)
        }
        return q
    }

    private static func floorToHour(_ d: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d)
        return Calendar.current.date(from: c) ?? d
    }
}

/// 兼容带毫秒与不带毫秒两种 ISO8601（Claude/Codex 的 timestamp 都有出现）
enum ISO8601Flex {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func parse(_ s: String) -> Date? { frac.date(from: s) ?? plain.date(from: s) }
}

extension KeychainStore {
    /// 按任意 service 名读通用密码（Claude Code OAuth 凭据探测用）
    static func readService(_ service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
