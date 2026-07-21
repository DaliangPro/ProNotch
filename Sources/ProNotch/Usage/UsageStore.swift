import Foundation
import Security

/// AI 编码工具额度：一个限额窗口的状态
struct QuotaWindow: Sendable {
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
struct ServiceQuota: Sendable {
    var plan: String?            // 订阅计划名
    var account: String?         // 账号标识（多账号切换时确认数据归属）
    var primary: QuotaWindow?    // 5 小时窗
    var secondary: QuotaWindow?  // 7 天窗
    var dataAt: Date?            // 数据时间（源文件里最后一条记录的时间）
    var error: String?           // 拿不到数据时的原因
    var topTasks: [TaskUsage] = []   // 近 7 天最耗额度的前 5 个任务（占总额度%）
}

/// 一轮刷新拉回来的全部额度数据（不可变快照，跨线程只传值）
struct UsageSnapshot: Sendable {
    var codex: ServiceQuota?
    var claude: ServiceQuota?
    var grok: ServiceQuota?
    var kimi: ServiceQuota?
    /// 键含来源：四家的 UUID 空间彼此独立，裸 ID 作键会让撞上同一 UUID 的两家互相覆盖
    var sessionTokens: [AgentSessionKey: Int] = [:]
}

/// 额度数据的来源。抽成协议是为了让"迟到结果"可测：
/// 测试里换成可控延迟的 loader，就能构造"A 还在拉、B 已被取消"这种时序
protocol UsageLoading: Sendable {
    func load(enabled: Set<AgentKind>) async -> UsageSnapshot
}

/// 生产实现：按勾选并发拉四家额度 + 扫会话 token
struct ProductionUsageLoader: UsageLoading {
    func load(enabled: Set<AgentKind>) async -> UsageSnapshot {
        let cx = enabled.contains(.codex) ? await CodexQuotaLoader.load() : nil
        let cl = enabled.contains(.claude) ? await ClaudeQuotaLoader.load() : nil
        let gr = enabled.contains(.grok) ? await GrokQuotaLoader.load() : nil
        let km = enabled.contains(.kimi) ? await KimiQuotaLoader.load() : nil
        // 每会话 token 统计（与额度数据源解耦）；Top 5 占比锚定周额度已用%（无周窗则退 5 小时窗）
        let claudeSessions = enabled.contains(.claude) ? SessionUsage.scanClaude() : []
        let codexSessions = enabled.contains(.codex) ? SessionUsage.scanCodex() : []
        let kimiSessions = enabled.contains(.kimi) ? SessionUsage.scanKimi() : []
        let grokSessions = enabled.contains(.grok) ? SessionUsage.scanGrok() : []
        let claudeTop = SessionUsage.top(claudeSessions,
            weekUsedPercent: cl?.secondary?.usedPercent ?? cl?.primary?.usedPercent, source: .claude)
        let codexTop = SessionUsage.top(codexSessions,
            weekUsedPercent: cx?.secondary?.usedPercent ?? cx?.primary?.usedPercent, source: .codex)
        let kimiTop = SessionUsage.top(kimiSessions,
            weekUsedPercent: km?.secondary?.usedPercent ?? km?.primary?.usedPercent, source: .kimi)
        let grokTop = SessionUsage.top(grokSessions,
            weekUsedPercent: gr?.secondary?.usedPercent ?? gr?.primary?.usedPercent, source: .grok)
        return UsageSnapshot(
            codex: cx.map { q in var q = q; q.topTasks = codexTop; return q },
            claude: cl.map { q in var q = q; q.topTasks = claudeTop; return q },
            grok: gr.map { q in var q = q; q.topTasks = grokTop; return q },
            kimi: km.map { q in var q = q; q.topTasks = kimiTop; return q },
            sessionTokens: Self.tokenTable([
                (.claude, claudeSessions), (.codex, codexSessions),
                (.kimi, kimiSessions), (.grok, grokSessions),
            ]))
    }

    /// 归并四家的每会话 token。同一家内同键重复（Codex 子代理聚合后可能出现）取和，
    /// 跨家因为键含来源不会相遇
    static func tokenTable(_ groups: [(AgentKind, [SessionUsage.Scanned])]) -> [AgentSessionKey: Int] {
        var table: [AgentSessionKey: Int] = [:]
        for (source, scanned) in groups {
            for item in scanned {
                table[AgentSessionKey(source: source, rawID: item.id), default: 0] += item.tokens
            }
        }
        return table
    }
}

/// 额度页数据源：读本机 Claude Code / Codex CLI 的会话文件取实时额度。
/// - Codex：session JSONL 里带官方返回的 rate_limits（used_percent/resets_at），精确；
/// - Claude：优先 OAuth 用量接口（凭据在则精确），否则按 transcript 的 token 用量本地估算（标注 ≈）。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codex: ServiceQuota?
    @Published private(set) var claude: ServiceQuota?
    @Published private(set) var grok: ServiceQuota?
    @Published private(set) var kimi: ServiceQuota?
    /// 会话键 → 有效 token（Agent 会话页用）。键含来源，两家撞上同一 UUID 也不会互相覆盖
    @Published private(set) var sessionTokens: [AgentSessionKey: Int] = [:]
    @Published private(set) var refreshing = false
    private var lastRefresh: Date = .distantPast
    private let loader: UsageLoading
    /// 刷新代际。每启动一轮 +1，结果回来时对不上就丢——
    /// 否则用户刚取消勾选 Claude，上一轮在途的结果照样把 Claude 数据写回来
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    /// 在途刷新期间又来了强制刷新：记下来，这轮一结束立刻补跑。
    /// 直接丢弃会让「勾选变更后立即重拉」整个失效
    private var pendingForce = false

    init(loader: UsageLoading = ProductionUsageLoader()) {
        self.loader = loader
        // 设置页勾选变更 → 立即清掉取消家的数据与缓存、重拉新勾家；平时刷新自然按勾选走
        NotificationCenter.default.addObserver(
            forName: .proNotchAgentSelectionChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAgentSelection() }
        }
    }

    /// 按 AgentKind 取额度快照（UI 层按勾选遍历渲染用）；无额度能力的家恒 nil
    func quota(for kind: AgentKind) -> ServiceQuota? {
        switch kind {
        case .claude: return claude
        case .codex: return codex
        case .grok: return grok
        case .kimi: return kimi
        }
    }

    /// 勾选变更即时生效：取消的家数据置空、解析缓存释放；新勾的家马上拉一轮。
    /// 关键是先 `cancelRefresh()`——在途那轮是按旧勾选集拉的，
    /// 让它跑完再写结果，等于把刚取消的家又填回界面
    func applyAgentSelection() {
        let enabled = AgentKind.enabledSet()
        if !enabled.contains(.claude) { claude = nil }
        if !enabled.contains(.codex) { codex = nil }
        if !enabled.contains(.grok) { grok = nil }
        if !enabled.contains(.kimi) { kimi = nil }
        SessionUsage.clearCaches(keeping: enabled)
        MemoryRelief.relieveSoon()
        cancelRefresh()
        start(enabled: enabled)
    }

    /// 取消在途刷新：代际前进（迟到结果自动作废）、任务取消、`refreshing` 复位。
    /// 复位这一步不能漏——被取消的任务不会再走到收尾分支，漏了就永远卡在"刷新中"
    func cancelRefresh() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        pendingForce = false
        refreshing = false
    }

    /// 顺带刷新（Agent 页心跳专用，5 分钟节流）：那边 8 秒一跳只为拿每会话 token 消耗，
    /// 走 refresh() 会被 30 秒节流放行，等于停在 Agent 页就每 30 秒给 Kimi/Grok 各来一次
    /// token 交换——比额度栏自己的定时还密。token 消耗是慢变量，跟兜底同频足够
    func refreshIncidental() {
        guard Date().timeIntervalSince(lastRefresh) > 300 else { return }
        refresh()
    }

    /// 刷新（30 秒节流，force 忽略节流）。文件扫描在后台线程，主线程只收结果。
    /// 只处理勾选的 Agent（每家总开关）：未勾选家不发请求、不扫它的任何文件
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 30 else { return }
        guard !refreshing else {
            // 撞上在途刷新：强制刷新排队等这轮结束，普通刷新直接跳过（本来就是节流触发的）
            if force { pendingForce = true }
            return
        }
        start(enabled: AgentKind.enabledSet())   // 主线程取快照，整轮全程用同一份
    }

    private func start(enabled: Set<AgentKind>) {
        lastRefresh = Date()
        refreshing = true
        generation &+= 1
        let gen = generation
        // Task 继承 MainActor 隔离：loader.load 是 nonisolated async，会自动跳去后台跑，
        // 回来后 apply 天然在主线程，不必再 MainActor.run 套一层
        refreshTask = Task { [weak self, loader] in
            let snapshot = await loader.load(enabled: enabled)
            self?.apply(snapshot, generation: gen, enabled: enabled)
        }
    }

    /// 结果落地。三道校验都过才写 UI：代际未变、任务未取消、勾选集与出发时一致
    private func apply(_ snapshot: UsageSnapshot, generation gen: UInt64, enabled: Set<AgentKind>) {
        defer { finish(generation: gen) }
        guard gen == generation, !Task.isCancelled, enabled == AgentKind.enabledSet() else { return }
        // 再按勾选过一遍：loader 是外部实现，不能假定它一定尊重了 enabled
        codex = enabled.contains(.codex) ? snapshot.codex : nil
        claude = enabled.contains(.claude) ? snapshot.claude : nil
        grok = enabled.contains(.grok) ? snapshot.grok : nil
        kimi = enabled.contains(.kimi) ? snapshot.kimi : nil
        sessionTokens = snapshot.sessionTokens
        // 扫描是全 App 最大的瞬时分配源（transcript 全库 GB 级），
        // 收尾把 libmalloc 攒下的空闲大块还给系统，压常驻 footprint
        MemoryRelief.relieveSoon()
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
}

// MARK: - Grok：读 ~/.grok CLI 日志里的 creditUsagePercent（周额度）

enum GrokQuotaLoader {
    /// 额度获取两条路，主路调接口、兜底读日志：
    /// ① 读 ~/.grok/auth.json 的 access token 调 /v1/billing?format=credits——grok CLI 自己就是
    ///    这么拿的，实时准确。这是「刷新」按钮真正生效的前提。
    /// ② token 过期（有效期 6 小时）或网络不通 → 退回读 ~/.grok/logs/unified.jsonl 的最新快照。
    ///
    /// 曾经只有 ②，于是「刷新额度」实为空操作：日志只在用户跑 grok 时才写，不用 grok 点多少次
    /// 数字都不动。实测抓到过日志停在 46%、接口实为 50% 的偏差。
    /// 套餐名（subscriptionTier）接口不返回，仍从日志取——它极少变，日志里的够用。
    static func load() async -> ServiceQuota {
        let fromLog = loadFromLog()
        guard var live = await fetchLive() else { return fromLog }
        live.plan = live.plan ?? fromLog.plan
        return live
    }

    /// 调 /v1/billing 拿实时额度；无凭证/已过期/请求失败一律返回 nil 交给日志兜底
    private static func fetchLive() async -> ServiceQuota? {
        guard let token = accessToken(),
              let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let used = firstDouble(key: "creditUsagePercent", in: obj),
              let end = firstString(key: "billingPeriodEnd", in: obj).flatMap({ ISO8601Flex.parse($0) })
        else { return nil }
        var q = ServiceQuota()
        q.dataAt = Date()   // 接口现取现用，就是「刚刚」
        q.primary = QuotaWindow(usedPercent: used, usedTokens: nil, resetsAt: end,
                                windowMinutes: 10080, isEstimate: false)
        return q
    }

    /// 从 auth.json 取未过期的 access token。顶层键形如 "https://auth.x.ai::<client_id>"（含账号 uuid，
    /// 不可写死）→ 遍历取第一个有效的。过期的直接跳过，省一次注定 401 的请求
    private static func accessToken() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for (_, v) in obj {
            guard let entry = v as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { continue }
            if let exp = entry["expires_at"] as? String,
               let d = ISO8601Flex.parse(exp), d <= Date() { continue }   // 已过期，跳过
            return key
        }
        return nil
    }

    /// 兜底：读日志最新快照（原逻辑）
    private static func loadFromLog() -> ServiceQuota {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/logs/unified.jsonl")
        guard let tail = readTail(log, bytes: 1_500_000) else {
            return ServiceQuota(error: "未取到 Grok 额度（接口未通，本地也无日志）")
        }
        // 找最新一条「billing: fetched credits config」(含 billingPeriodEnd)。
        // 关键坑：新计费周期额度充足时，config 里【没有】creditUsagePercent 字段——grok 只在消耗到
        // 一定量后才写它。若按该字段筛行，就只会翻到上周期用满 100% 的旧记录、永远显示错的。
        // 改用 billingPeriodEnd 定位最新 config；creditUsagePercent 缺失即视为「已用 0%」
        var used: Double = 0, resetAt: Date?, tier: String?, dataTs: Date?
        for line in tail.split(separator: "\n").reversed() where line.contains("billingPeriodEnd") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
            used = firstDouble(key: "creditUsagePercent", in: obj) ?? 0
            resetAt = firstString(key: "billingPeriodEnd", in: obj).flatMap { ISO8601Flex.parse($0) }
            tier = firstString(key: "subscriptionTier", in: obj)
            dataTs = firstString(key: "ts", in: obj).flatMap { ISO8601Flex.parse($0) }
            break
        }
        guard resetAt != nil else { return ServiceQuota(error: "Grok 暂无额度记录，用一次 grok 即可") }
        // 日志是上一周期的旧快照，且接口也没拿到（多半登录过期）→ 宁可报错也不展示过期数据。
        // 跑一次 grok 两件事一起解决：刷新登录态、写入新周期日志
        if let r = resetAt, r <= Date() {
            return ServiceQuota(plan: tier, error: "登录可能已过期，用一次 grok 即可刷新")
        }
        var q = ServiceQuota()
        q.plan = tier
        q.dataAt = dataTs ?? Date()   // 数据时间 = 日志真实时刻，不把过期数据伪装成「刚刚」
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

// MARK: - Kimi Code：CLI 内置 managed-usage 同款接口（零配置，凭据就在本地）

enum KimiQuotaLoader {
    /// 从 CLI 二进制逆向出的官方链路（packages/oauth/src/managed-usage.ts，未暴露成命令）：
    /// 1. `~/.kimi-code/credentials/kimi-code.json` 的 refresh_token 换临时 access_token
    ///    （POST auth.kimi.com/api/oauth/token）。服务端轮换发新但不废旧——CLI 自己 18 天不写回
    ///    照样能刷（实证）；我们拿到的新 token 只在内存用完即弃，绝不写盘，不影响 CLI 登录。
    /// 2. GET api.kimi.com/coding/v1/usages 带 Bearer → usage（周窗）+ limits[]（5 小时窗）。
    static let tokenEndpoint = "https://auth.kimi.com/api/oauth/token"
    static let usageEndpoint = "https://api.kimi.com/coding/v1/usages"
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"   // CLI 官方 device-code flow client

    static func load() async -> ServiceQuota {
        let cred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        guard let data = try? Data(contentsOf: cred),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = obj["refresh_token"] as? String, !refreshToken.isEmpty else {
            return ServiceQuota(error: "未登录 Kimi CLI，在终端运行 kimi login")
        }
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
        ]
        guard let url = URL(string: tokenEndpoint), let body = comps.percentEncodedQuery else {
            return ServiceQuota(error: "接口地址异常")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        guard let (tokData, tokResp) = try? await URLSession.shared.data(for: req),
              let tokCode = (tokResp as? HTTPURLResponse)?.statusCode else {
            return ServiceQuota(error: "无法连接 Kimi 认证服务")
        }
        guard tokCode == 200,
              let tokObj = try? JSONSerialization.jsonObject(with: tokData) as? [String: Any],
              let access = tokObj["access_token"] as? String, !access.isEmpty else {
            return ServiceQuota(error: tokenError(code: tokCode, body: tokData))
        }
        guard let uurl = URL(string: usageEndpoint) else { return ServiceQuota(error: "接口地址异常") }
        var ureq = URLRequest(url: uurl)
        ureq.timeoutInterval = 10
        ureq.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        ureq.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (udata, uresp) = try? await URLSession.shared.data(for: ureq),
              let ucode = (uresp as? HTTPURLResponse)?.statusCode else {
            return ServiceQuota(error: "无法连接 Kimi 用量服务")
        }
        guard ucode == 200,
              let uobj = try? JSONSerialization.jsonObject(with: udata) as? [String: Any] else {
            return ServiceQuota(error: "Kimi 接口返回异常（HTTP \(ucode)）")
        }
        return parse(uobj) ?? ServiceQuota(error: "Kimi 返回了无法识别的数据结构")
    }

    /// token 刷新失败的归因（纯函数，可测）：非 200 一律报「登录已过期」会骗人白跑一趟——
    /// 限流和服务端故障重登多少次都是红的，登完还红只会让人以为是 ProNotch 坏了。
    /// 只有服务端明确说凭证不认（400 invalid_grant / 401）才该让用户去 kimi login
    static func tokenError(code: Int, body: Data) -> String {
        let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { $0?["error"] as? String }
        switch code {
        case 429:
            return "Kimi 接口限流，稍后自动重试"
        case 500...599:
            return "Kimi 服务暂时不可用（HTTP \(code)）"
        case 200:
            return "Kimi 认证返回了无法识别的数据结构"
        case 400, 401, 403:
            return "Kimi 登录已过期，在终端重新 kimi login"
        default:
            // 认不出的状态码别硬扣「登录过期」的帽子，把码报出来更有助于排查
            return reason.map { "Kimi 认证被拒（\($0)）" } ?? "Kimi 认证失败（HTTP \(code)）"
        }
    }

    /// 解析响应（纯函数，可测）。实测结构（2026-07）：
    /// `usage{limit,used,remaining,resetTime}` 是周窗总量，`limits[].window{duration,timeUnit}+detail`
    /// 是滚动窗（现为 300 分钟）；数值全是字符串（"100"），resetTime 带 6 位微秒
    static func parse(_ obj: [String: Any]) -> ServiceQuota? {
        var windows: [QuotaWindow] = []
        if let w = window(from: obj["usage"] as? [String: Any], minutes: 10080) { windows.append(w) }
        for lim in obj["limits"] as? [[String: Any]] ?? [] {
            let minutes = windowMinutes(lim["window"] as? [String: Any]) ?? 300
            if let w = window(from: (lim["detail"] as? [String: Any]) ?? lim, minutes: minutes) {
                windows.append(w)
            }
        }
        guard !windows.isEmpty else { return nil }
        var q = ServiceQuota()
        q.dataAt = Date()
        if let user = obj["user"] as? [String: Any],
           let member = user["membership"] as? [String: Any],
           let level = member["level"] as? String, !level.isEmpty {
            q.plan = planName(level)
        }
        windows.sort { $0.windowMinutes < $1.windowMinutes }
        q.primary = windows.first
        q.secondary = windows.count > 1 ? windows.last : nil
        return q
    }

    /// 档位枚举 → 官方套餐名（kimi.com 四档 Explorer / Moderato / Allegretto / Allegro）。
    /// 官方没给对照表，实证一条记一条：INTERMEDIATE = Allegretto（大梁老师账号核实，2026-07）；
    /// 没见过的枚举值按首字母大写原样露出，不猜
    private static func planName(_ level: String) -> String {
        let raw = level.replacingOccurrences(of: "LEVEL_", with: "")
        if raw == "INTERMEDIATE" { return "Allegretto" }
        return raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
    }

    /// 一个窗口：limit + used（缺则 limit−remaining 补出）；limit 非正视为无效
    private static func window(from d: [String: Any]?, minutes: Int) -> QuotaWindow? {
        guard let d, let limit = intValue(d["limit"]), limit > 0 else { return nil }
        let used = intValue(d["used"]) ?? intValue(d["remaining"]).map { limit - $0 }
        guard let u = used else { return nil }
        let resets = (d["resetTime"] as? String).flatMap { parseResetTime($0) }
        return QuotaWindow(usedPercent: Double(u) / Double(limit) * 100, usedTokens: nil,
                           resetsAt: resets, windowMinutes: minutes, isEstimate: false)
    }

    private static func windowMinutes(_ w: [String: Any]?) -> Int? {
        guard let w, let dur = intValue(w["duration"]) else { return nil }
        let unit = w["timeUnit"] as? String ?? ""
        if unit.contains("MINUTE") { return dur }
        if unit.contains("HOUR") { return dur * 60 }
        if unit.contains("DAY") { return dur * 1440 }
        return max(1, dur / 60)   // 无单位按秒兜底
    }

    /// "2026-07-23T15:30:47.920838Z"：ISO8601DateFormatter 只认 3 位小数，微秒截断（CLI 同款处理）
    static func parseResetTime(_ s: String) -> Date? {
        if let d = ISO8601Flex.parse(s) { return d }
        guard s.hasSuffix("Z"), let dot = s.firstIndex(of: ".") else { return nil }
        let frac = s[s.index(after: dot)..<s.index(before: s.endIndex)]
        return ISO8601Flex.parse("\(s[..<dot]).\(frac.prefix(3))Z")
    }

    /// 接口的数值字段既出现过字符串 "100" 也可能是数字，两种都收
    private static func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
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
        let root = SessionUsage.defaultClaudeRoot
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return ServiceQuota(error: "未找到 Claude Code 数据（~/.claude/projects）")
        }
        // 条目来自 SessionUsage 的文件级缓存（mtime+size 失效）：只有变过的文件才重读，
        // 且与 Top 5 扫描共享同一份解析结果——此前两边各把 GB 级全库整读一遍。
        // 口径不变：只算官方 claude- 模型；不含 cache_read（缓存读千倍灌水，
        // 实测 7 天 3.1G vs 不含 121M，且官方计价权重极低）
        var entries: [(ts: Date, tokens: Int)] = []   // 近 7 天全部用量点
        for file in SessionUsage.claudeFileScans() {
            for e in file.entries {
                guard let ts = e.ts, ts > weekAgo else { continue }   // 精确窗口过滤（缓存是日粒度超集）
                entries.append((ts, e.tokens))
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
