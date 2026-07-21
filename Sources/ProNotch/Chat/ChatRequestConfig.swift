import Foundation

/// 一次请求用的不可变配置快照。
///
/// 发消息是个长事务：查询改写 → 联网搜索 → 流式回复，中间可能过好几十秒。
/// 原先这条链路上的每一步都现读 Store 的 `baseURL` / `apiKey` / `model`，
/// 用户中途切一次 Provider，后半段就会拿 B 的端点发 A 的对话、带 B 的 Key——
/// 轻则报 401，重则把 A 的对话内容送到 B 的服务商那里。
///
/// 快照在 `send()` 开头生成一次，之后整条链路只认它。
struct ChatRequestConfig: Sendable, Equatable {
    let providerID: UUID
    let baseURL: String
    let apiKey: String
    let model: String
    let searchEngine: SearchEngine
    let searchKey: String

    var isConfigured: Bool { !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty }

    /// 对话端点：已带 /chat/completions 直接用；带 /v1 补 /chat/completions；否则补 /v1/chat/completions
    func chatCompletionsURL() throws -> URL {
        try Self.normalize(baseURL: baseURL, appending: "chat/completions")
    }

    /// 模型列表端点（GET /v1/models）
    static func modelsURL(baseURL: String) throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespaces)
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.hasSuffix("/chat/completions") {
            raw = String(raw.dropLast("/chat/completions".count))
        }
        if !raw.hasSuffix("/v1") { raw += "/v1" }
        return try makeURL(raw + "/models")
    }

    private static func normalize(baseURL: String, appending path: String) throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespaces)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.hasSuffix("/" + path) {
            raw += raw.hasSuffix("/v1") ? "/" + path : "/v1/" + path
        }
        return try makeURL(raw)
    }

    private static func makeURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme != nil else {
            throw NSError(domain: "ProNotch", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "API 地址无效: \(raw)"])
        }
        try EndpointPolicy.validateUserAPIEndpoint(url)   // 明文 HTTP 发公网直接在这拦掉
        return url
    }
}
