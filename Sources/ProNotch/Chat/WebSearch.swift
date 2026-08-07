import Foundation

/// 一条搜索结果。**相关片段与页面正文分两个字段存**，不许互相顶掉。
///
/// 原先只有一个 `snippet`，Tavily 那路写成 `raw.count > content.count ? raw : content`——
/// 整页原文几乎永远比相关片段长，于是「按你的问题排出来的那几块」**永远被扔掉**，
/// 留下的是网页从头 1500 字符（导航、页头、开场白）。模型手上没有一句冲着问题来的，
/// 这正是大梁老师说的「联网搜索没跟回答融合」（2026-07-29 查明）。
struct SearchResult {
    var title: String
    var url: String
    /// 与问题最相关的片段。Tavily 的 `content`（advanced 深度下是按查询相关度排出的块）；
    /// DDG / Brave 则是搜索引擎自己的摘要——那也是冲着查询词来的，同样算相关片段
    var highlights: String = ""
    /// 页面正文。Tavily 的 `raw_content`，或 DDG / Brave 路线我们自己抓的
    var body: String = ""
    /// 发布时间。只有 Tavily 的 `topic: news` 会给，用来让模型分辨新旧
    var published: String?
}

/// 可选搜索引擎
enum SearchEngine: String, CaseIterable {
    case duckduckgo
    case tavily
    case brave
    /// 博查：国内索引。前三家都是海外系，中文网页、论坛、公众号覆盖天然弱
    ///（大梁老师 2026-08-03 问「会不会是搜索渠道的问题」——查证属实）
    case bocha

    var displayName: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo（免费）"
        case .tavily:     return "Tavily（英文强）"
        case .brave:      return "Brave Search"
        case .bocha:      return "博查（中文强）"
        }
    }
    /// 是否需要 API Key（DuckDuckGo 免费、无需）
    var needsKey: Bool { self != .duckduckgo }

    /// 中文索引强不强。自动分流按这个分两派：中文问题优先中文强的那家
    var strongInChinese: Bool { self == .bocha }

    /// 查询里有没有中文（含日韩）。有＝中文问题。
    ///
    /// **判据是「有没有」，不是「占多少」**——比例法被真实用例证伪了：
    /// 逐字符量下来，「macOS NSWindow orderFrontRegardless 用法」中文只占 5.7%
    ///（一个英文标识符顶几十个字符），「SwiftUI LazyVStack 为什么会卡顿」占 26%，
    /// 而它们都是铁打的中文问题。阈值从 50% 一路降到 20% 仍然漏判，
    /// 说明比例这个维度本身就不对。
    ///
    /// 反向也成立：英文问题里根本不会冒出汉字。所以「出现即判定」既准又稳。
    /// 判错的代价还不对称——中文问题误送海外索引＝拿不到中文垂直站；
    /// 英文问题误送国内索引顶多结果稍逊。纯函数，可测
    static func isChineseQuery(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,     // 中日韩统一表意文字
             0x3400...0x4DBF,     // 扩展 A
             0x3040...0x30FF,     // 日文假名
             0xAC00...0xD7AF:     // 韩文
            return true
        default:
            return false
        }
    }
}

/// 客户端联网搜索：API 普遍不带联网能力，通用做法是先搜索再把结果注入提示词。
/// 配置了 Tavily Key 优先用 Tavily 深度搜索（取页面正文），
/// 否则用 DuckDuckGo 抓取并补抓前几个结果的网页正文
enum WebSearch {
    /// 单条结果的正文上限。
    ///
    /// 原为 1500——一篇文章的开头一段而已，真正的答案（数字、日期、结论）通常在中后部，
    /// 全被切掉。抬到 6000 是量级上的修正，总量另有预算封顶（见 `totalBodyBudget`）
    static let perResultCap = 6000

    /// 所有来源的正文合计上限。相关片段不占这个预算（它们短且最有价值，一律全给）。
    /// 排在后面的来源预算用尽就只留相关片段
    static let totalBodyBudget = 24000

    /// 进提示词的来源条数上限。
    ///
    /// 3 条查询 × 8 条结果去重后可能剩二十几个来源，光相关片段（每条最多 1500 字符）
    /// 就三万多字符，叠上正文预算会把请求撑到几万 token——闪问要的是快，
    /// 预填时间会直接体现成「问完要等好久」。8 条来源已远超此前实际可用的 3 条
    static let maxDocuments = 8

    /// 一次问题最多拆几条查询。Tavily 官方建议复杂问题拆子查询分别发
    /// （"Break complex queries into sub-queries. Send separate focused requests"），
    /// 但每条都要花 credits，所以由改写器按问题复杂度决定，上限卡在这儿
    static let maxQueries = 3

    /// 每条查询取几条结果（Tavily 上限 20）。原为 6，多查询合并去重后仍需足量候选
    static let resultsPerQuery = 8

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"

    /// 抓正文统一走带安全策略的抓取器（复用同一个 URLSession，不必每页新建）
    private static let pageFetcher = SafeWebFetcher()

    /// 一条查询。`timeRange` 为 day/week/month/year 之一（Tavily 支持，其余引擎忽略），
    /// `news` 为真时用 Tavily 的新闻源（带发布日期元数据，问「最新」时更准）
    static func search(query: String, engine: SearchEngine, key: String,
                       timeRange: String? = nil, news: Bool = false) async throws -> [SearchResult] {
        switch engine {
        case .tavily:     return try await tavily(query: query, key: key, timeRange: timeRange, news: news)
        case .brave:      return try await brave(query: query, key: key)
        case .bocha:      return try await bocha(query: query, key: key, timeRange: timeRange)
        case .duckduckgo: return try await duckDuckGo(query: query)
        }
    }

    /// 一条查询 + 它该走哪个渠道。
    ///
    /// 渠道**按每条查询各判各的**，不跟着整句问题走（2026-08-07 改）：
    /// 大梁老师问「千问办公和 QoderWork 有什么区别」，整句含中文会被判成中文问题、
    /// 整轮锁死走国内索引，可拆出来的 `QoderWork` 是纯英文产品名，
    /// 本该交给英文强的那家。一句话里两种语言的名字凑一起，在技术与产品话题里是常态
    struct PlannedQuery: Equatable {
        let query: String
        let engine: SearchEngine
        let key: String

        init(query: String, engine: SearchEngine, key: String) {
            self.query = query
            self.engine = engine
            self.key = key
        }
    }

    /// 多条查询并行搜、按 URL 去重、交错合并。每条走各自的渠道。
    ///
    /// Tavily 官方对复杂问题的建议就是拆子查询分别发，而不是把多个话题塞进一条查询词。
    /// 合并用**交错**而不是简单拼接：每条查询的头名依次排在前面，
    /// 这样任何一个子问题都不会因为排在后面而被正文预算耗尽后砍掉。
    ///
    /// 单条查询失败不拖垮整轮（某个子查询限流也还有别的结果可用）；
    /// 全部失败才抛出——把第一条的错误交回去，让用户看到真实原因
    static func searchMany(_ queries: [PlannedQuery],
                           timeRange: String? = nil, news: Bool = false) async throws -> [SearchResult] {
        let plan = Array(queries.prefix(maxQueries)).filter { !$0.query.isEmpty }
        guard !plan.isEmpty else { return [] }
        if plan.count == 1 {
            return try await search(query: plan[0].query, engine: plan[0].engine, key: plan[0].key,
                                    timeRange: timeRange, news: news)
        }
        var buckets = [Int: [SearchResult]]()
        var failures = [Error]()
        await withTaskGroup(of: (Int, Result<[SearchResult], Error>).self) { group in
            for (i, q) in plan.enumerated() {
                group.addTask {
                    do { return (i, .success(try await search(query: q.query, engine: q.engine, key: q.key,
                                                             timeRange: timeRange, news: news))) }
                    catch { return (i, .failure(error)) }
                }
            }
            for await (i, outcome) in group {
                switch outcome {
                case .success(let list): buckets[i] = list
                case .failure(let error): failures.append(error)
                }
            }
        }
        guard !buckets.isEmpty else {
            if let first = failures.first { throw first }
            return []
        }
        return interleave(buckets, order: plan.indices)
    }

    /// URL 归一化，只为去重：去掉 scheme 与末尾斜杠——http/https、带不带斜杠都算同一页。
    /// 不动大小写：路径在多数服务器上是区分大小写的，一并小写会把两个不同页面误判成一个
    static func canonicalURL(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"^https?://"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? raw : s
    }

    /// 交错合并并按 URL 去重（同一页被多条查询同时命中很常见）
    static func interleave(_ buckets: [Int: [SearchResult]], order: some Sequence<Int>) -> [SearchResult] {
        let keys = Array(order)
        let depth = keys.compactMap { buckets[$0]?.count }.max() ?? 0
        var seen = Set<String>()
        var merged: [SearchResult] = []
        for rank in 0..<depth {
            for key in keys {
                guard let list = buckets[key], rank < list.count else { continue }
                let item = list[rank]
                guard seen.insert(canonicalURL(item.url)).inserted else { continue }
                merged.append(item)
            }
        }
        return merged
    }

    // MARK: - Tavily

    private static func tavily(query: String, key: String,
                               timeRange: String?, news: Bool) async throws -> [SearchResult] {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // advanced：content 字段变成「按查询相关度排出来的块」（chunks_per_source 上限 3，
        // 每块 500 字符）；raw_content 另给整页正文。两者都要，见 SearchResult 的注释。
        // markdown 而非纯文本：标题层级与表格能保住结构，模型更好读
        var body: [String: Any] = [
            "query": query,
            "max_results": resultsPerQuery,
            "search_depth": "advanced",
            "chunks_per_source": 3,
            "include_raw_content": "markdown",
        ]
        // 时效过滤是官方给的参数，此前一直没传——问「最新」也会翻出几年前的页面。
        // news 主题还会附带发布日期，让模型自己分辨新旧
        if let timeRange, !timeRange.isEmpty { body["time_range"] = timeRange }
        if news { body["topic"] = "news" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ProNotch", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Tavily HTTP \(http.statusCode) \(detail.prefix(150))"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["results"] as? [[String: Any]] else {
            throw NSError(domain: "ProNotch", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Tavily 返回格式异常"])
        }
        return list.compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            // content 与 raw_content **各存各的**，不再二选一：
            // content 是按查询排出来的相关块（短但全中要害），raw_content 是整页正文
            // （长但从头开始）。原先「谁长用谁」等于永远丢掉相关块
            return SearchResult(
                title: title,
                url: url,
                highlights: (item["content"] as? String) ?? "",
                body: String(((item["raw_content"] as? String) ?? "").prefix(perResultCap)),
                published: item["published_date"] as? String)
        }
    }

    // MARK: - Brave Search

    private static func brave(query: String, key: String) async throws -> [SearchResult] {
        let token = key.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            throw NSError(domain: "ProNotch", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "请先在设置里填写 Brave Search API Key"])
        }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "6"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Subscription-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ProNotch", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Brave HTTP \(http.statusCode) \(detail.prefix(150))"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = object["web"] as? [String: Any],
              let list = web["results"] as? [[String: Any]] else {
            throw NSError(domain: "ProNotch", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Brave 返回格式异常"])
        }
        var results: [SearchResult] = list.prefix(resultsPerQuery).compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            // 搜索引擎的摘要本就是冲着查询词来的，算作相关片段；正文另抓
            return SearchResult(title: stripHTML(title), url: url,
                                highlights: stripHTML((item["description"] as? String) ?? ""),
                                published: item["age"] as? String)
        }
        guard !results.isEmpty else {
            throw NSError(domain: "ProNotch", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "Brave 未返回结果"])
        }
        await fillBodies(&results)
        return results
    }

    /// 博查 Web Search：国内索引 + AI 摘要。
    ///
    /// 契约（2026-08-03 查证）：POST https://api.bochaai.com/v1/web-search，
    /// Bearer 认证，body {query, freshness, summary, count}；
    /// 返回 data.webPages.value[]，每条 {name, url, siteName, snippet, summary, datePublished}。
    /// summary 是它自己生成的 AI 摘要（比 snippet 长且冲着查询来），当相关片段用；
    /// 正文仍由我们自己抓（与 Brave/DDG 同一条路）
    private static func bocha(query: String, key: String,
                              timeRange: String?) async throws -> [SearchResult] {
        let token = key.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            throw NSError(domain: "ProNotch", code: -8,
                          userInfo: [NSLocalizedDescriptionKey: "请先在设置里填写博查 API Key"])
        }
        var request = URLRequest(url: URL(string: "https://api.bochaai.com/v1/web-search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "freshness": bochaFreshness(timeRange),
            "summary": true,              // 要 AI 摘要：比一行 snippet 有料得多
            "count": resultsPerQuery,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ProNotch", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "博查 HTTP \(http.statusCode) \(detail.prefix(150))"])
        }
        // 结果层级两种写法都认：外面裹不裹 data 各家网关不一，认死一种会白丢结果
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ProNotch", code: -9,
                          userInfo: [NSLocalizedDescriptionKey: "博查返回格式异常"])
        }
        let root = (object["data"] as? [String: Any]) ?? object
        guard let pages = root["webPages"] as? [String: Any],
              let list = pages["value"] as? [[String: Any]] else {
            throw NSError(domain: "ProNotch", code: -9,
                          userInfo: [NSLocalizedDescriptionKey: "博查返回格式异常"])
        }
        var results: [SearchResult] = list.prefix(resultsPerQuery).compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            let title = (item["name"] as? String) ?? (item["siteName"] as? String) ?? url
            // summary（AI 摘要）优先，没有才退 snippet——两者都是冲着查询来的相关片段
            let summary = (item["summary"] as? String) ?? ""
            let snippet = (item["snippet"] as? String) ?? ""
            return SearchResult(title: stripHTML(title), url: url,
                                highlights: stripHTML(summary.isEmpty ? snippet : summary),
                                published: item["datePublished"] as? String)
        }
        guard !results.isEmpty else {
            throw NSError(domain: "ProNotch", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "博查未返回结果"])
        }
        await fillBodies(&results)
        return results
    }

    /// 规划器给的 day/week/month/year 翻成博查的 freshness 词表（纯函数，可测）
    static func bochaFreshness(_ timeRange: String?) -> String {
        switch timeRange {
        case "day":   return "oneDay"
        case "week":  return "oneWeek"
        case "month": return "oneMonth"
        case "year":  return "oneYear"
        default:      return "noLimit"
        }
    }

    /// 给前几条补抓页面正文（Brave / DDG / 博查只给摘要，光靠它模型没料可用）。
    /// 抓失败不影响该条——相关片段仍在，只是少了正文
    private static func fillBodies(_ results: inout [SearchResult]) async {
        let count = min(4, results.count)
        var fetched = [Int: String]()
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in 0..<count {
                let url = results[index].url
                group.addTask { (index, await fetchPageText(url: url)) }
            }
            for await (index, text) in group {
                if let text { fetched[index] = text }
            }
        }
        for (index, text) in fetched { results[index].body = text }
    }

    // MARK: - DuckDuckGo（网页抓取，零配置但稳定性一般）

    private static func duckDuckGo(query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ProNotch", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "DuckDuckGo 返回无法解码"])
        }

        let titles = matches(in: html,
            pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#)
        let snippets = matches(in: html,
            pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#)

        var results: [SearchResult] = []
        for (index, groups) in titles.prefix(resultsPerQuery).enumerated() {
            guard groups.count >= 2 else { continue }
            let url = resolveDuckDuckGoURL(groups[0])
            let title = stripHTML(groups[1])
            let highlights = index < snippets.count ? stripHTML(snippets[index][0]) : ""
            guard !title.isEmpty else { continue }
            results.append(SearchResult(title: title, url: url, highlights: highlights))
        }
        guard !results.isEmpty else {
            throw NSError(domain: "ProNotch", code: -4,
                          userInfo: [NSLocalizedDescriptionKey:
                              "DuckDuckGo 未解析到结果（可能被拦截或改版），建议在设置中配置 Tavily Key"])
        }

        await fillBodies(&results)
        return results
    }

    /// 抓取网页并提取纯文本正文（尽力而为，失败返回 nil 保留原摘要）。
    ///
    /// URL 来自搜索引擎结果——属于外部可影响的输入，所以抓取前必须过 `SafeWebFetcher`
    /// 的地址判定、重定向复检、大小上限与内容类型白名单，不能直接丢给 URLSession
    static func fetchPageText(url: String, fetcher: SafeWebFetcher = pageFetcher) async -> String? {
        guard let pageURL = URL(string: url) else { return nil }
        guard let text = try? await fetcher.fetchText(url: pageURL, cap: perResultCap),
              !text.isEmpty else { return nil }   // 失败只降级为搜索摘要，不打断整轮对话
        return text
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<script[\s\S]*?</script>"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<style[\s\S]*?</style>"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#,
                                         with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"\s+"#,
                                         with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DDG 链接是跳转包装（/l/?uddg=真实地址），解出真实 URL
    private static func resolveDuckDuckGoURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return raw
        }
        return uddg
    }

    /// 返回每个匹配的捕获组数组
    private static func matches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }
        }
    }

    private static func stripHTML(_ html: String) -> String {
        decodeEntities(
            html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
