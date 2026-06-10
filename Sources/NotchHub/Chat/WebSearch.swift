import Foundation

struct SearchResult {
    let title: String
    let snippet: String
    let url: String
}

/// 客户端联网搜索：API 普遍不带联网能力，通用做法是先搜索再把结果注入提示词。
/// 配置了 Tavily Key 优先用 Tavily（稳定），否则用 DuckDuckGo 网页抓取（免费）
enum WebSearch {
    static func search(query: String, tavilyKey: String) async throws -> [SearchResult] {
        let key = tavilyKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            return try await tavily(query: query, key: key)
        }
        return try await duckDuckGo(query: query)
    }

    // MARK: - Tavily

    private static func tavily(query: String, key: String) async throws -> [SearchResult] {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": 5,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "NotchHub", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Tavily HTTP \(http.statusCode) \(detail.prefix(150))"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["results"] as? [[String: Any]] else {
            throw NSError(domain: "NotchHub", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Tavily 返回格式异常"])
        }
        return list.compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            return SearchResult(title: title,
                                snippet: (item["content"] as? String) ?? "",
                                url: url)
        }
    }

    // MARK: - DuckDuckGo（网页抓取，零配置但稳定性一般）

    private static func duckDuckGo(query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "NotchHub", code: -3,
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
            throw NSError(domain: "NotchHub", code: -4,
                          userInfo: [NSLocalizedDescriptionKey:
                              "DuckDuckGo 未解析到结果（可能被拦截或改版），建议在设置中配置 Tavily Key"])
        }
        return results
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
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
