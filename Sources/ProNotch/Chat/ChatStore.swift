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
    /// 随消息发送的截图附件（JPEG 数据；「截图问 AI」入口写入）
    var imageData: Data? = nil
}

/// AI 闪问数据源：OpenAI 兼容接口 + SSE 流式输出。
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
    /// 搜索引擎选择（duckduckgo / tavily / brave）与各自的 Key
    @Published private(set) var searchEngine: String
    @Published var draftSearchEngine: String
    @Published private(set) var tavilyKey: String
    @Published var draftTavilyKey: String
    @Published private(set) var braveKey: String
    @Published var draftBraveKey: String
    @Published private(set) var isSearching = false
    /// 设置表单显隐（顶行入口与页面内容两处共用）
    @Published var showSettings = false
    /// 待发送的截图附件（JPEG；随下一条用户消息发出后清空）
    @Published var draftAttachment: Data?
    /// 输入框聚焦信号（截图问 AI 唤入时 +1，视图侧聚焦）
    @Published var focusInputTick = 0

    /// API 连通状态（顶行状态灯）
    enum ConnectivityState {
        case unknown
        case checking
        case ok
        case failed(String)
    }

    @Published private(set) var connectivity: ConnectivityState = .unknown
    private var lastConnectivityCheck: Date = .distantPast

    /// 联网搜索测试结果（联网搜索卡的状态灯）
    enum SearchTestState {
        case unknown
        case testing
        case ok(Int)
        case failed(String)
    }
    @Published private(set) var searchTest: SearchTestState = .unknown

    private var streamTask: Task<Void, Never>?

    var isConfigured: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    init() {
        let defaults = UserDefaults.standard
        Self.migrateKeysToKeychainIfNeeded()
        let savedURL = defaults.string(forKey: "chatBaseURL") ?? ""
        let savedModel = defaults.string(forKey: "chatModel") ?? ""
        baseURL = savedURL
        model = savedModel
        draftBaseURL = savedURL
        draftModel = savedModel
        // Key 先取测试参数域（-chatAPIKey 等，迁移后 UserDefaults 只剩这一来源）；
        // 真实 Key 在钥匙串里，同步读会在重签后的首启弹授权框并阻塞主线程（历史启动卡死根源），
        // 改为 init 后台回填（毫秒级完成）
        let testKey = defaults.string(forKey: "chatAPIKey") ?? ""
        apiKey = testKey
        draftAPIKey = testKey
        let testTavily = defaults.string(forKey: "chatTavilyKey") ?? ""
        tavilyKey = testTavily
        draftTavilyKey = testTavily
        let testBrave = defaults.string(forKey: "chatBraveKey") ?? ""
        braveKey = testBrave
        draftBraveKey = testBrave
        let savedEngine = defaults.string(forKey: "chatSearchEngine") ?? SearchEngine.duckduckgo.rawValue
        searchEngine = savedEngine
        draftSearchEngine = savedEngine
        webSearchEnabled = defaults.bool(forKey: "chatWebSearchEnabled")
        loadKeysFromKeychain()
    }

    /// 后台线程读取钥匙串回填三个 Key：不阻塞主线程，重签后首启的授权弹框也不再卡住刘海出现。
    /// 测试参数域已注入的值优先，不覆盖
    private func loadKeysFromKeychain() {
        Task.detached(priority: .userInitiated) {
            let api = KeychainStore.read("chatAPIKey") ?? ""
            let tavily = KeychainStore.read("chatTavilyKey") ?? ""
            let brave = KeychainStore.read("chatBraveKey") ?? ""
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.apiKey.isEmpty { self.apiKey = api; self.draftAPIKey = api }
                if self.tavilyKey.isEmpty { self.tavilyKey = tavily; self.draftTavilyKey = tavily }
                if self.braveKey.isEmpty { self.braveKey = brave; self.draftBraveKey = brave }
            }
        }
    }

    /// 历史版本把 Key 明文存在 UserDefaults：首次启动搬进钥匙串并抹掉明文
    private static func migrateKeysToKeychainIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let persisted = UserDefaults.standard.persistentDomain(forName: bundleID)
        else { return }
        for account in ["chatAPIKey", "chatTavilyKey"] {
            if let legacy = persisted[account] as? String, !legacy.isEmpty {
                KeychainStore.save(legacy, account: account)
                UserDefaults.standard.removeObject(forKey: account)
                print("[ProNotch] \(account) 已从明文配置迁入钥匙串")
            }
        }
    }

    /// 把表单草稿提交为正式设置并持久化
    func saveSettings() {
        baseURL = draftBaseURL.trimmingCharacters(in: .whitespaces)
        apiKey = draftAPIKey.trimmingCharacters(in: .whitespaces)
        model = draftModel.trimmingCharacters(in: .whitespaces)
        tavilyKey = draftTavilyKey.trimmingCharacters(in: .whitespaces)
        braveKey = draftBraveKey.trimmingCharacters(in: .whitespaces)
        searchEngine = draftSearchEngine
        draftBaseURL = baseURL
        draftAPIKey = apiKey
        draftModel = model
        draftTavilyKey = tavilyKey
        draftBraveKey = braveKey
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: "chatBaseURL")
        defaults.set(model, forKey: "chatModel")
        defaults.set(searchEngine, forKey: "chatSearchEngine")
        // Key 只进钥匙串，不落明文配置
        KeychainStore.save(apiKey, account: "chatAPIKey")
        KeychainStore.save(tavilyKey, account: "chatTavilyKey")
        KeychainStore.save(braveKey, account: "chatBraveKey")
        print("[ProNotch] 已保存 AI 设置，端点: \((try? endpointURL())?.absoluteString ?? "无效")")
        checkConnectivity(force: true)
    }

    /// 连通检测：拉一次模型列表（不消耗 token）。60 秒内不重复，force 强制
    func checkConnectivity(force: Bool = false) {
        guard isConfigured else {
            connectivity = .unknown
            return
        }
        if case .checking = connectivity { return }
        if !force, Date().timeIntervalSince(lastConnectivityCheck) < 60 { return }
        lastConnectivityCheck = Date()
        connectivity = .checking
        let url = baseURL
        let key = apiKey
        Task { [weak self] in
            do {
                _ = try await Self.fetchAvailableModels(baseURL: url, apiKey: key)
                self?.connectivity = .ok
                print("[ProNotch] API 连通检测: 正常")
            } catch {
                self?.connectivity = .failed(error.localizedDescription)
                print("[ProNotch] API 连通检测失败: \(error.localizedDescription)")
            }
        }
    }

    /// 用表单里当前选的引擎 + Key 真跑一次搜索，验证搜索链路
    func testSearch() {
        if case .testing = searchTest { return }
        searchTest = .testing
        let engine = SearchEngine(rawValue: draftSearchEngine) ?? .duckduckgo
        let key: String
        switch engine {
        case .tavily:     key = draftTavilyKey
        case .brave:      key = draftBraveKey
        case .duckduckgo: key = ""
        }
        Task { [weak self] in
            do {
                let results = try await WebSearch.search(query: "OpenAI 最新消息", engine: engine, key: key)
                self?.searchTest = .ok(results.count)
                print("[ProNotch] 搜索测试: \(results.count) 条")
            } catch {
                self?.searchTest = .failed(error.localizedDescription)
                print("[ProNotch] 搜索测试失败: \(error.localizedDescription)")
            }
        }
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
                print("[ProNotch] 获取到 \(models.count) 个模型")
            } catch {
                self?.fetchError = error.localizedDescription
            }
            self?.fetchingModels = false
        }
    }

    /// 「截图问 AI」入口：压缩截图挂为待发附件，并请求输入框聚焦
    func attachScreenshot(_ image: NSImage) {
        draftAttachment = Self.jpegAttachment(from: image)
        focusInputTick += 1
    }

    /// 消息 → OpenAI 载荷：带图的用「文本+image_url(data URI)」parts 数组（视觉模型格式），纯文本保持字符串
    private static func payloadEntry(for m: ChatMessage) -> [String: Any] {
        guard let data = m.imageData else {
            return ["role": m.role.rawValue, "content": m.content]
        }
        return ["role": m.role.rawValue, "content": [
            ["type": "text", "text": m.content],
            ["type": "image_url",
             "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]],
        ]]
    }

    /// 替换消息内容里的文本（联网搜索注入用）：parts 数组只改 text 部分，保留图片
    private static func replacingText(in content: Any?, with text: String) -> Any {
        guard var parts = content as? [[String: Any]] else { return text }
        for i in parts.indices where (parts[i]["type"] as? String) == "text" { parts[i]["text"] = text }
        return parts
    }

    /// 截图附件压缩：长边 ≤1400、JPEG 0.82——视觉模型足够看清，且控制请求体积
    nonisolated private static func jpegAttachment(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let k = min(1, 1400 / max(w, h))
        if k >= 1 { return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) }
        let tw = Int(w * k), th = Int(h * k)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, isConfigured else { return }
        errorText = nil
        let attachment = draftAttachment
        draftAttachment = nil
        messages.append(ChatMessage(role: .user, content: trimmed, imageData: attachment))
        let history = messages.map(Self.payloadEntry)
        messages.append(ChatMessage(role: .assistant, content: ""))
        isStreaming = true
        streamTask = Task { [weak self] in
            await self?.run(question: trimmed, history: history)
        }
    }

    /// 完整一轮：可选联网搜索（查询改写 → 搜索 → 结果注入最后一条用户消息）→ 流式请求
    private func run(question: String, history: [[String: Any]]) async {
        var payload = history
        if webSearchEnabled {
            isSearching = true
            do {
                // 先让模型把口语化问题（含上下文指代）改写成搜索词，失败则用原话
                let query = await rewriteQuery(history: history) ?? question
                let engine = SearchEngine(rawValue: searchEngine) ?? .duckduckgo
                let searchKey: String
                switch engine {
                case .tavily:     searchKey = tavilyKey
                case .brave:      searchKey = braveKey
                case .duckduckgo: searchKey = ""
                }
                let results = try await WebSearch.search(query: query, engine: engine, key: searchKey)
                if !results.isEmpty {
                    payload[payload.count - 1]["content"] = Self.replacingText(
                        in: payload[payload.count - 1]["content"],
                        with: Self.augmentedPrompt(question: question, results: results))
                    setLastAssistantSearchCount(results.count)
                    print("[ProNotch] 联网搜索返回 \(results.count) 条结果")
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
                print("[ProNotch] 联网搜索失败: \(error.localizedDescription)")
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
        print("[ProNotch] 已在搜索阶段停止")
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
    private func rewriteQuery(history: [[String: Any]]) async -> String? {
        var payload: [[String: String]] = [[
            "role": "system",
            "content": "你是搜索查询改写器。今天是\(Self.currentDateText())。"
                + "根据对话上下文与用户最新一条消息，生成一条最适合搜索引擎的简洁查询词"
                + "（补全上下文中的指代对象，保留关键实体与时间限定）。"
                + "只输出查询词本身，不要解释、不要引号。",
        ]]
        // 视觉消息投影成纯文本（改写模型不需要看图）
        payload += history.suffix(6).map { entry -> [String: String] in
            let role = entry["role"] as? String ?? "user"
            if let text = entry["content"] as? String { return ["role": role, "content": text] }
            let text = ((entry["content"] as? [[String: Any]]) ?? [])
                .compactMap { $0["text"] as? String }.joined()
            return ["role": role, "content": text + "（附截图）"]
        }
        do {
            let raw = try await completeOnce(payload: payload)
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'「」"))
            guard !cleaned.isEmpty, cleaned.count <= 60, !cleaned.contains("\n") else {
                return nil
            }
            print("[ProNotch] 搜索查询改写: \(cleaned)")
            return cleaned
        } catch {
            print("[ProNotch] 查询改写失败，改用原话搜索: \(error.localizedDescription)")
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
            throw NSError(domain: "ProNotch", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "HTTP \(http.statusCode) \(detail.prefix(150))"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "ProNotch", code: -2,
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
            throw NSError(domain: "ProNotch", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "API 地址无效: \(raw)"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespaces))",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ProNotch", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "HTTP \(http.statusCode) \(detail.prefix(200))"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            throw NSError(domain: "ProNotch", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "返回格式不是 OpenAI 模型列表"])
        }
        let ids = list.compactMap { $0["id"] as? String }.sorted()
        guard !ids.isEmpty else {
            throw NSError(domain: "ProNotch", code: -3,
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
            throw NSError(domain: "ProNotch", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "API 地址无效: \(raw)"])
        }
        return url
    }

    private func stream(payload: [[String: Any]]) async {
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
                throw NSError(domain: "ProNotch", code: http.statusCode,
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
            print("[ProNotch] AI 回复完成（\(messages.last?.content.count ?? 0) 字符）")
            // 真实对话成功是最可靠的连通证据，顺带刷新状态灯
            connectivity = .ok
        } catch is CancellationError {
            print("[ProNotch] AI 回复已停止")
        } catch let error as URLError where error.code == .cancelled {
            print("[ProNotch] AI 回复已停止")
        } catch {
            errorText = error.localizedDescription
            // 失败时移除空的占位回复
            if let last = messages.last, last.role == .assistant, last.content.isEmpty {
                messages.removeLast()
            }
            // 关键：本次带图的 user 消息若发送失败，去掉它的图片（保留文字）——否则这条 image_url 会
            // 永久留在历史，之后每次请求都重发它、被不支持图片的模型反复 400，会话彻底卡死。
            if let idx = messages.indices.last, messages[idx].role == .user, messages[idx].imageData != nil {
                messages[idx].imageData = nil
                errorText = "图片发送失败，当前模型可能不支持图片：\(error.localizedDescription)"
            }
            print("[ProNotch] AI 请求失败: \(error.localizedDescription)")
            // 状态灯不因单次请求失败就常红——单次失败（尤其 400 请求内容问题，如图片不支持）不代表
            // 连接坏了。用轻量 GET /models 探测真实连通来定灯色：连接正常自动转绿，真断了才保持红。
            checkConnectivity(force: true)
        }
    }

    private func appendToLastAssistant(_ chunk: String) {
        guard let last = messages.indices.last,
              messages[last].role == .assistant else { return }
        messages[last].content += chunk
    }
}
