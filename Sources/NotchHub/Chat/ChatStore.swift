import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var content: String
    /// 该回复参考的联网搜索结果条数（nil 表示未联网）
    var searchResultCount: Int? = nil
}

/// AI 对话数据源：OpenAI 兼容接口 + SSE 流式输出。
/// 会话仅存内存（面板收起保留，应用重启清空）；设置持久化到 UserDefaults。
@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published var errorText: String?

    @Published private(set) var baseURL: String
    @Published private(set) var apiKey: String
    @Published private(set) var model: String

    // 表单草稿与对话输入框内容放在 Store 而非视图状态，
    // 面板收起（视图销毁）后重新展开不丢失
    @Published var draftBaseURL: String
    @Published var draftAPIKey: String
    @Published var draftModel: String
    @Published var draftMessage = ""
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var fetchingModels = false
    @Published var fetchError: String?

    /// 联网搜索开关（切换即持久化）
    @Published var webSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "chatWebSearchEnabled") }
    }
    /// Tavily 搜索 Key（选填；为空时用内置 DuckDuckGo 抓取）
    @Published private(set) var tavilyKey: String
    @Published var draftTavilyKey: String
    @Published private(set) var isSearching = false

    private var streamTask: Task<Void, Never>?

    var isConfigured: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    init() {
        let defaults = UserDefaults.standard
        let savedURL = defaults.string(forKey: "chatBaseURL") ?? ""
        let savedKey = defaults.string(forKey: "chatAPIKey") ?? ""
        let savedModel = defaults.string(forKey: "chatModel") ?? ""
        baseURL = savedURL
        apiKey = savedKey
        model = savedModel
        draftBaseURL = savedURL
        draftAPIKey = savedKey
        draftModel = savedModel
        let savedTavily = defaults.string(forKey: "chatTavilyKey") ?? ""
        tavilyKey = savedTavily
        draftTavilyKey = savedTavily
        webSearchEnabled = defaults.bool(forKey: "chatWebSearchEnabled")
    }

    /// 把表单草稿提交为正式设置并持久化
    func saveSettings() {
        baseURL = draftBaseURL.trimmingCharacters(in: .whitespaces)
        apiKey = draftAPIKey.trimmingCharacters(in: .whitespaces)
        model = draftModel.trimmingCharacters(in: .whitespaces)
        tavilyKey = draftTavilyKey.trimmingCharacters(in: .whitespaces)
        draftBaseURL = baseURL
        draftAPIKey = apiKey
        draftModel = model
        draftTavilyKey = tavilyKey
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: "chatBaseURL")
        defaults.set(apiKey, forKey: "chatAPIKey")
        defaults.set(model, forKey: "chatModel")
        defaults.set(tavilyKey, forKey: "chatTavilyKey")
        print("[NotchHub] 已保存 AI 设置，端点: \((try? endpointURL())?.absoluteString ?? "无效")")
    }

    /// 用草稿里的地址和 Key 拉取可用模型列表
    func fetchModels() {
        guard !fetchingModels else { return }
        fetchingModels = true
        fetchError = nil
        let url = draftBaseURL
        let key = draftAPIKey
        Task { [weak self] in
            do {
                let models = try await Self.fetchAvailableModels(baseURL: url, apiKey: key)
                guard let self else { return }
                self.availableModels = models
                // 模型栏为空时自动填入第一个，少点一次
                if self.draftModel.trimmingCharacters(in: .whitespaces).isEmpty,
                   let first = models.first {
                    self.draftModel = first
                }
                print("[NotchHub] 获取到 \(models.count) 个模型")
            } catch {
                self?.fetchError = error.localizedDescription
            }
            self?.fetchingModels = false
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, isConfigured else { return }
        errorText = nil
        messages.append(ChatMessage(role: .user, content: trimmed))
        let history = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        messages.append(ChatMessage(role: .assistant, content: ""))
        isStreaming = true
        streamTask = Task { [weak self] in
            await self?.run(question: trimmed, history: history)
        }
    }

    /// 完整一轮：可选联网搜索（查询改写 → 搜索 → 结果注入最后一条用户消息）→ 流式请求
    private func run(question: String, history: [[String: String]]) async {
        var payload = history
        if webSearchEnabled {
            isSearching = true
            do {
                // 先让模型把口语化问题（含上下文指代）改写成搜索词，失败则用原话
                let query = await rewriteQuery(history: history) ?? question
                let results = try await WebSearch.search(query: query, tavilyKey: tavilyKey)
                if !results.isEmpty {
                    payload[payload.count - 1]["content"] =
                        Self.augmentedPrompt(question: question, results: results)
                    setLastAssistantSearchCount(results.count)
                    print("[NotchHub] 联网搜索返回 \(results.count) 条结果")
                }
            } catch is CancellationError {
                isSearching = false
                cancelBeforeStream()
                return
            } catch let error as URLError where error.code == .cancelled {
                isSearching = false
                cancelBeforeStream()
                return
            } catch {
                // 搜索失败不阻断对话，降级为直接回答
                errorText = "联网搜索失败（已不带搜索结果直接回答）：\(error.localizedDescription)"
                print("[NotchHub] 联网搜索失败: \(error.localizedDescription)")
            }
            isSearching = false
            if Task.isCancelled {
                cancelBeforeStream()
                return
            }
        }
        await stream(payload: payload)
    }

    private func cancelBeforeStream() {
        isStreaming = false
        if let last = messages.last, last.role == .assistant, last.content.isEmpty {
            messages.removeLast()
        }
        print("[NotchHub] 已在搜索阶段停止")
    }

    private func setLastAssistantSearchCount(_ count: Int) {
        if let index = messages.indices.last, messages[index].role == .assistant {
            messages[index].searchResultCount = count
        }
    }

    private static func augmentedPrompt(question: String, results: [SearchResult]) -> String {
        var lines = [
            "今天是\(currentDateText())。以下是针对用户问题的联网搜索结果，请据此回答：",
            "- 综合多个来源的信息作答，互相矛盾时交叉比对并说明分歧",
            "- 引用具体信息时标注来源序号，如 [1][3]",
            "- 区分信息的时间，避免把旧信息当成最新动态",
            "- 搜索结果不足以回答时明确说明，再基于自身知识谨慎补充",
            "- 用用户提问的语言回答，直接给出答案，不要复述搜索结果原文",
            "",
            "搜索结果：",
        ]
        for (index, result) in results.enumerated() {
            lines.append("[\(index + 1)] \(result.title)")
            if !result.snippet.isEmpty {
                lines.append(result.snippet)
            }
            lines.append("来源: \(result.url)")
            lines.append("")
        }
        lines.append("用户问题：\(question)")
        return lines.joined(separator: "\n")
    }

    private static func currentDateText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: Date())
    }

    /// 用同一个模型做非流式查询改写：把口语化问题与上下文指代还原成搜索词
    private func rewriteQuery(history: [[String: String]]) async -> String? {
        var payload: [[String: String]] = [[
            "role": "system",
            "content": "你是搜索查询改写器。今天是\(Self.currentDateText())。"
                + "根据对话上下文与用户最新一条消息，生成一条最适合搜索引擎的简洁查询词"
                + "（补全上下文中的指代对象，保留关键实体与时间限定）。"
                + "只输出查询词本身，不要解释、不要引号。",
        ]]
        payload += history.suffix(6)
        do {
            let raw = try await completeOnce(payload: payload)
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'「」"))
            guard !cleaned.isEmpty, cleaned.count <= 60, !cleaned.contains("\n") else {
                return nil
            }
            print("[NotchHub] 搜索查询改写: \(cleaned)")
            return cleaned
        } catch {
            print("[NotchHub] 查询改写失败，改用原话搜索: \(error.localizedDescription)")
            return nil
        }
    }

    /// 非流式单次补全，供查询改写等轻量内部任务使用
    private func completeOnce(payload: [[String: String]]) async throws -> String {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": payload,
            "stream": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "NotchHub", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "HTTP \(http.statusCode) \(detail.prefix(150))"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "NotchHub", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "非流式返回格式异常"])
        }
        return content
    }

    func stopStreaming() {
        streamTask?.cancel()
    }

    func clearConversation() {
        stopStreaming()
        messages = []
        errorText = nil
    }

    /// 拉取服务端可用模型列表（GET /v1/models，OpenAI 兼容）。
    /// 用表单当场填写的地址和 Key，不要求先保存
    static func fetchAvailableModels(baseURL: String, apiKey: String) async throws -> [String] {
        var raw = baseURL.trimmingCharacters(in: .whitespaces)
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.hasSuffix("/chat/completions") {
            raw = String(raw.dropLast("/chat/completions".count))
        }
        if !raw.hasSuffix("/v1") { raw += "/v1" }
        raw += "/models"
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw NSError(domain: "NotchHub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "API 地址无效: \(raw)"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespaces))",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "NotchHub", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "HTTP \(http.statusCode) \(detail.prefix(200))"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            throw NSError(domain: "NotchHub", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "返回格式不是 OpenAI 模型列表"])
        }
        let ids = list.compactMap { $0["id"] as? String }.sorted()
        guard !ids.isEmpty else {
            throw NSError(domain: "NotchHub", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "服务端未返回任何模型"])
        }
        return ids
    }

    // MARK: - 私有

    /// 端点规范化：已带 /chat/completions 直接用；带 /v1 补 /chat/completions；
    /// 否则补 /v1/chat/completions
    private func endpointURL() throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespaces)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.hasSuffix("/chat/completions") {
            raw += raw.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
        }
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw NSError(domain: "NotchHub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "API 地址无效: \(raw)"])
        }
        return url
    }

    private func stream(payload: [[String: String]]) async {
        defer {
            isStreaming = false
            streamTask = nil
        }
        do {
            var request = URLRequest(url: try endpointURL())
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": payload,
                "stream": true,
            ])

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 4096 { break }
                }
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "NotchHub", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey:
                                  "HTTP \(http.statusCode) \(detail.prefix(200))"])
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if json == "[DONE]" { break }
                guard let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String,
                      !content.isEmpty else { continue }
                appendToLastAssistant(content)
            }
            print("[NotchHub] AI 回复完成（\(messages.last?.content.count ?? 0) 字符）")
        } catch is CancellationError {
            print("[NotchHub] AI 回复已停止")
        } catch let error as URLError where error.code == .cancelled {
            print("[NotchHub] AI 回复已停止")
        } catch {
            errorText = error.localizedDescription
            // 失败时移除空的占位回复
            if let last = messages.last, last.role == .assistant, last.content.isEmpty {
                messages.removeLast()
            }
            print("[NotchHub] AI 请求失败: \(error.localizedDescription)")
        }
    }

    private func appendToLastAssistant(_ chunk: String) {
        guard let last = messages.indices.last,
              messages[last].role == .assistant else { return }
        messages[last].content += chunk
    }
}
