import Foundation

struct SearchResult {
    var title: String
    var snippet: String
    var url: String
}

/// 可选搜索引擎
enum SearchEngine: String, CaseIterable {
    case duckduckgo
    case tavily
    case brave

    var displayName: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo（免费）"
        case .tavily:     return "Tavily"
        case .brave:      return "Brave Search"
        }
    }
    /// 是否需要 API Key（DuckDuckGo 免费、无需）
    var needsKey: Bool { self != .duckduckgo }
}

/// 客户端联网搜索：API 普遍不带联网能力，通用做法是先搜索再把结果注入提示词。
/// 配置了 Tavily Key 优先用 Tavily 深度搜索（取页面正文），
/// 否则用 DuckDuckGo 抓取并补抓前几个结果的网页正文
enum WebSearch {
    /// 注入给模型的单条正文上限
    static let perResultCap = 1500

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"

    /// 抓正文统一走带安全策略的抓取器（复用同一个 URLSession，不必每页新建）
    private static let pageFetcher = SafeWebFetcher()

    static func search(query: String, engine: SearchEngine, key: String) async throws -> [SearchResult] {
        switch engine {
        case .tavily:     return try await tavily(query: query, key: key)
        case .brave:      return try await brave(query: query, key: key)
        case .duckduckgo: return try await duckDuckGo(query: query)
        }
    }

    // MARK: - Tavily

    private static func tavily(query: String, key: String) async throws -> [SearchResult] {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // advanced 深度搜索返回与查询更相关的内容块，raw_content 提供页面正文
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": 6,
            "search_depth": "advanced",
            "include_raw_content": true,
        ])
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
            let content = (item["content"] as? String) ?? ""
            let raw = (item["raw_content"] as? String) ?? ""
            // 正文优先用 raw_content（更完整），太短则退回相关性内容块
            let body = raw.count > content.count ? raw : content
            return SearchResult(title: title,
                                snippet: String(body.prefix(perResultCap)),
                                url: url)
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
        var results: [SearchResult] = list.prefix(6).compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            let desc = (item["description"] as? String) ?? ""
            return SearchResult(title: stripHTML(title), snippet: stripHTML(desc), url: url)
        }
        guard !results.isEmpty else {
            throw NSError(domain: "ProNotch", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "Brave 未返回结果"])
        }
        // 补抓前 3 个结果正文（Brave 摘要较短），提升注入信息量
        let fetchCount = min(3, results.count)
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in 0..<fetchCount {
                let url = results[index].url
                group.addTask { (index, await fetchPageText(url: url)) }
            }
            for await (index, text) in group {
                if let text { results[index].snippet = text }
            }
        }
        return results
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
        for (index, groups) in titles.prefix(5).enumerated() {
            guard groups.count >= 2 else { continue }
            let url = resolveDuckDuckGoURL(groups[0])
            let title = stripHTML(groups[1])
            let snippet = index < snippets.count ? stripHTML(snippets[index][0]) : ""
            guard !title.isEmpty else { continue }
            results.append(SearchResult(title: title, snippet: snippet, url: url))
        }
        guard !results.isEmpty else {
            throw NSError(domain: "ProNotch", code: -4,
                          userInfo: [NSLocalizedDescriptionKey:
                              "DuckDuckGo 未解析到结果（可能被拦截或改版），建议在设置中配置 Tavily Key"])
        }

        // 并行抓取前 3 个结果的网页正文，替换贫瘠的摘要，提升注入给模型的信息量
        let fetchCount = min(3, results.count)
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in 0..<fetchCount {
                let url = results[index].url
                group.addTask { (index, await fetchPageText(url: url)) }
            }
            for await (index, text) in group {
                if let text {
                    results[index].snippet = text
                }
            }
        }
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
