import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id = UUID()
    let role: Role
    var content: String
    /// 该回复参考的联网搜索结果条数（nil 表示未联网）
    var searchResultCount: Int? = nil
    /// 随消息发送的截图附件（JPEG 数据；「截图问 AI」入口写入）
    var imageData: Data? = nil

    /// 落盘只存文字与搜索条数：图片附件体积大且历史图片不需要重发，重启即弃
    private enum CodingKeys: String, CodingKey {
        case id, role, content, searchResultCount
    }
}

/// 一段对话（侧栏一行）：标题取首条用户消息开头，列表按最近更新排序
struct ChatConversation: Identifiable, Codable {
    var id = UUID()
    var title = ""
    var messages: [ChatMessage] = []
    var updatedAt = Date()
}

/// 一套 API 配置（大梁老师定）：DeepSeek 一套、Claude 一套……各自独立的 URL/Key/模型，可切换。
/// Key 不落这里（体积小但仍属敏感），存钥匙串，账号见 keychainAccount；首套沿用旧账号 chatAPIKey 兼容历史数据
struct APIProvider: Identifiable, Codable {
    var id = UUID()
    var name: String
    var baseURL: String
    var model: String
    var customModels: [String] = []
    var fetchedModels: [String] = []
    var keychainAccount: String
}

/// AI 闪问数据源：OpenAI 兼容接口 + SSE 流式输出。
/// 多会话、可切换，落盘到 App Support/ProNotch/chat-conversations.json（图片附件不落盘）；
/// 设置持久化到 UserDefaults。
@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [ChatConversation] = []
    @Published private(set) var currentID: UUID?
    /// 正在流式写入的会话：用户切走后回复继续写回原会话，不串台
    @Published private(set) var streamingConvID: UUID?

    /// 当前会话的消息（原单会话代码的读写入口，落到 conversations 上）
    var messages: [ChatMessage] {
        get { conversations.first(where: { $0.id == currentID })?.messages ?? [] }
        set {
            guard let i = conversations.firstIndex(where: { $0.id == currentID }) else { return }
            conversations[i].messages = newValue
        }
    }
    @Published private(set) var isStreaming = false
    @Published var errorText: String?

    @Published private(set) var baseURL: String
    @Published private(set) var apiKey: String
    @Published private(set) var model: String

    /// 多套 API 配置与当前选中（大梁老师定）。上面 baseURL/apiKey/model 是「当前套」的运行时投影
    @Published private(set) var providers: [APIProvider] = []
    @Published private(set) var currentProviderID = UUID()

    // 表单草稿与对话输入框内容放在 Store 而非视图状态，
    // 面板收起（视图销毁）后重新展开不丢失
    @Published var draftName = ""
    @Published var draftBaseURL: String
    @Published var draftAPIKey: String
    @Published var draftModel: String
    @Published var draftMessage = ""
    @Published private(set) var availableModels: [String] = []
    /// 手动添加的模型（大梁老师定）：服务端 /models 只回一个或不可用时，自己补
    @Published private(set) var customModels: [String] = []
    @Published private(set) var fetchingModels = false
    @Published var fetchError: String?

    /// 联网搜索开关（切换即持久化）
    @Published var webSearchEnabled: Bool {
        didSet { env.defaults.set(webSearchEnabled, forKey: "chatWebSearchEnabled") }
    }
    /// 搜索引擎选择（duckduckgo / tavily / brave）与各自的 Key
    @Published private(set) var searchEngine: String
    @Published var draftSearchEngine: String
    @Published private(set) var tavilyKey: String
    @Published var draftTavilyKey: String
    @Published private(set) var braveKey: String
    @Published var draftBraveKey: String
    @Published private(set) var isSearching = false
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

    /// 系统依赖边界（配置存储、钥匙串、网络、落盘路径）。生产用 `.production`，测试注入内存实现
    let env: ChatEnvironment

    /// Provider 身份/配置代际：切换、新增、删除、保存设置都 +1。
    /// 异步任务出发前记下它，回来前比一次——不一致说明用户已经改过配置，结果作废
    private(set) var providerRevision: UInt64 = 0

    /// 当前 Provider 的不可变快照（含搜索引擎与对应 Key）
    func currentRequestConfig() -> ChatRequestConfig {
        let engine = SearchEngine(rawValue: searchEngine) ?? .duckduckgo
        let key: String
        switch engine {
        case .tavily:     key = tavilyKey
        case .brave:      key = braveKey
        case .duckduckgo: key = ""
        }
        return ChatRequestConfig(providerID: currentProviderID, baseURL: baseURL,
                                 apiKey: apiKey, model: model,
                                 searchEngine: engine, searchKey: key)
    }

    /// 异步结果回来时是否还该采纳：Provider 没换人、配置没改过
    private func isStillCurrent(_ providerID: UUID, _ revision: UInt64) -> Bool {
        providerID == currentProviderID && revision == providerRevision
    }

    var isConfigured: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    init(env: ChatEnvironment = .production) {
        self.env = env
        let defaults = env.defaults
        Self.migrateKeysToKeychainIfNeeded(env: env)
        let savedURL = defaults.string(forKey: PrefKey.chatBaseURL) ?? ""
        let savedModel = defaults.string(forKey: PrefKey.chatModel) ?? ""
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
        // 模型列表持久化：右上角切换器不用每次先点「获取模型」
        availableModels = defaults.stringArray(forKey: "chatAvailableModels") ?? []
        customModels = defaults.stringArray(forKey: "chatCustomModels") ?? []
        loadProviders()   // 建/载多套配置，并用当前套覆盖上面的运行时字段
        loadConversations()
        loadKeysFromKeychain()
    }

    // MARK: - 多套 API 配置

    /// 启动载入配置：无存档则把现有单套迁成第一套（Key 原地复用旧账号，零风险）
    private func loadProviders() {
        let defaults = env.defaults
        if let data = defaults.data(forKey: "chatProviders"),
           let list = try? JSONDecoder().decode([APIProvider].self, from: data), !list.isEmpty {
            providers = list
        } else {
            providers = [APIProvider(name: Self.inferName(from: baseURL),
                                     baseURL: baseURL, model: model,
                                     customModels: customModels, fetchedModels: availableModels,
                                     keychainAccount: "chatAPIKey")]
            persistProviders()
        }
        if let s = defaults.string(forKey: "chatCurrentProviderID"), let uid = UUID(uuidString: s),
           providers.contains(where: { $0.id == uid }) {
            currentProviderID = uid
        } else {
            currentProviderID = providers[0].id
        }
        applyCurrentProviderToFields()
    }

    /// 把当前套的 URL/模型/模型列表载入运行时字段与草稿（不含 Key，Key 走钥匙串后台读）
    private func applyCurrentProviderToFields() {
        guard let p = providers.first(where: { $0.id == currentProviderID }) else { return }
        baseURL = p.baseURL
        model = p.model
        draftName = p.name
        draftBaseURL = p.baseURL
        draftModel = p.model
        customModels = p.customModels
        availableModels = p.fetchedModels
    }

    /// 当前套的钥匙串账号（Key 读写都认它）
    private var currentKeychainAccount: String {
        providers.first(where: { $0.id == currentProviderID })?.keychainAccount ?? "chatAPIKey"
    }

    /// 从 URL 域名猜配置名：api.deepseek.com → Deepseek；空则「默认」
    private static func inferName(from url: String) -> String {
        let host = URLComponents(string: url)?.host ?? URL(string: url)?.host ?? ""
        let parts = host.split(separator: ".")
        if parts.count >= 2 { return parts[parts.count - 2].capitalized }
        if !host.isEmpty { return host }
        return url.isEmpty ? "默认" : "自定义"
    }

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            env.defaults.set(data, forKey: "chatProviders")
        }
        env.defaults.set(currentProviderID.uuidString, forKey: "chatCurrentProviderID")
    }

    /// 把当前运行时的模型态写回当前套存档（切模型/加删模型/拉到列表后调用）
    private func syncCurrentProviderModels() {
        guard let i = providers.firstIndex(where: { $0.id == currentProviderID }) else { return }
        providers[i].model = model
        providers[i].customModels = customModels
        providers[i].fetchedModels = availableModels
        persistProviders()
    }

    /// 切换到某套配置：载入其 URL/模型，后台读它的 Key，重测连通
    func activateProvider(_ id: UUID) {
        guard id != currentProviderID, providers.contains(where: { $0.id == id }) else { return }
        currentProviderID = id
        providerRevision += 1
        applyCurrentProviderToFields()
        apiKey = ""
        draftAPIKey = ""
        connectivity = .unknown
        fetchError = nil
        let account = currentKeychainAccount
        let keys = env.keychainSlice
        let revision = providerRevision
        persistProviders()
        Task.detached(priority: .userInitiated) {
            let k = keys.read(account)
            await MainActor.run { [weak self] in
                // 期间又切走（或配置被改）则弃：A 的 Key 绝不能落到 B 头上
                guard let self, self.isStillCurrent(id, revision) else { return }
                self.apiKey = k
                self.draftAPIKey = k
                if self.isConfigured { self.checkConnectivity(force: true) }
            }
        }
    }

    /// 新增一套空配置并切过去；当前已是空壳则复用，不堆空配置
    func addProvider() {
        if let cur = providers.first(where: { $0.id == currentProviderID }),
           cur.baseURL.isEmpty, cur.model.isEmpty {
            return
        }
        let p = APIProvider(name: "新配置", baseURL: "", model: "",
                            keychainAccount: "chatAPIKey-\(UUID().uuidString)")
        providers.append(p)
        // 直接切过去（activateProvider 有「同 id 不切」保护，先落库再切）
        persistProviders()
        currentProviderID = p.id
        providerRevision += 1
        applyCurrentProviderToFields()
        apiKey = ""
        draftAPIKey = ""
        connectivity = .unknown
        fetchError = nil
        persistProviders()
    }

    /// 删除一套配置（至少保留一套）：连带清掉它的钥匙串 Key，删的是当前套则切到第一套
    func deleteProvider(_ id: UUID) {
        guard providers.count > 1 else { return }
        if let p = providers.first(where: { $0.id == id }) {
            env.deleteKey(p.keychainAccount)
        }
        let wasCurrent = id == currentProviderID
        providers.removeAll { $0.id == id }
        persistProviders()
        if wasCurrent, let first = providers.first {
            currentProviderID = first.id
            providerRevision += 1
            applyCurrentProviderToFields()
            apiKey = ""
            draftAPIKey = ""
            connectivity = .unknown
            let account = currentKeychainAccount
            let keys = env.keychainSlice
            let newID = first.id
            let revision = providerRevision
            Task.detached(priority: .userInitiated) {
                let k = keys.read(account)
                await MainActor.run { [weak self] in
                    // 删完接着切到别套时，这份迟到的回填不能覆盖当前套
                    guard let self, self.isStillCurrent(newID, revision) else { return }
                    self.apiKey = k
                    self.draftAPIKey = k
                    if self.isConfigured { self.checkConnectivity(force: true) }
                }
            }
        }
    }

    // MARK: - 多会话管理

    /// 侧栏顺序：最近更新在前
    var sortedConversations: [ChatConversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var currentIndex: Int? {
        conversations.firstIndex(where: { $0.id == currentID })
    }

    /// 启动加载历史会话；首次运行或文件损坏则从一个空会话开始
    private func loadConversations() {
        if let data = try? Data(contentsOf: env.conversationsURL),
           let list = try? JSONDecoder().decode([ChatConversation].self, from: data) {
            conversations = list
        }
        currentID = sortedConversations.first?.id
        ensureCurrentConversation()
    }

    /// 兜底：currentID 悬空时补一个空会话（删光、历史损坏都会走到）
    private func ensureCurrentConversation() {
        guard !conversations.contains(where: { $0.id == currentID }) else { return }
        let conv = ChatConversation()
        conversations.append(conv)
        currentID = conv.id
    }

    func newConversation() {
        errorText = nil
        // 当前已是空会话就复用，避免侧栏攒一堆空「新对话」
        if let cur = conversations.first(where: { $0.id == currentID }), cur.messages.isEmpty { return }
        let conv = ChatConversation()
        conversations.append(conv)
        currentID = conv.id
        persistConversations()
    }

    func selectConversation(_ id: UUID) {
        guard id != currentID, conversations.contains(where: { $0.id == id }) else { return }
        currentID = id
        errorText = nil   // 错误条属于上一个会话的现场，切走即清
    }

    func deleteConversation(_ id: UUID) {
        if streamingConvID == id { stopStreaming() }
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = sortedConversations.first?.id }
        ensureCurrentConversation()
        persistConversations()
    }

    /// 落盘时机：发消息、流结束、建删会话——流式逐字阶段不写盘
    private func persistConversations() {
        let list = conversations
        let url = env.conversationsURL
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(list).write(to: url, options: .atomic)
            } catch {
                print("[ProNotch] 会话历史落盘失败: \(error.localizedDescription)")
            }
        }
    }

    /// 在流式写入目标会话上就地改动（用户可能已切去别的会话）
    private func withStreamingConv(_ body: (inout [ChatMessage]) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == streamingConvID }) else { return }
        body(&conversations[i].messages)
    }

    /// 后台线程读取钥匙串回填三个 Key：不阻塞主线程，重签后首启的授权弹框也不再卡住刘海出现。
    /// 测试参数域已注入的值优先，不覆盖
    private func loadKeysFromKeychain() {
        let account = currentKeychainAccount   // 当前套的账号（首套=chatAPIKey）
        let keys = env.keychainSlice
        Task.detached(priority: .userInitiated) {
            let api = keys.read(account)
            let tavily = keys.read("chatTavilyKey")
            let brave = keys.read("chatBraveKey")
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.apiKey.isEmpty { self.apiKey = api; self.draftAPIKey = api }
                if self.tavilyKey.isEmpty { self.tavilyKey = tavily; self.draftTavilyKey = tavily }
                if self.braveKey.isEmpty { self.braveKey = brave; self.draftBraveKey = brave }
            }
        }
    }

    /// 历史版本把 Key 明文存在 UserDefaults：首次启动搬进钥匙串并抹掉明文。
    ///
    /// 抹明文的前提是钥匙串**读回校验通过**——原先写完不看返回值就 `removeObject`，
    /// 钥匙串锁定或 ACL 拒绝时明文和密文同时没了，Key 直接丢失
    @discardableResult
    private static func migrateKeysToKeychainIfNeeded(env: ChatEnvironment) -> KeychainMigrationReport {
        guard let domain = env.plaintextDomain else { return KeychainMigrationReport() }
        let report = KeychainMigrator(keychain: env.keychain, currentService: env.keychainService)
            .migratePlaintextKeys(KeychainStore.legacyAccounts, in: env.defaults, domain: domain)
        for account in report.migrated {
            print("[ProNotch] \(account) 已从明文配置迁入钥匙串")
        }
        for (account, error) in report.failed {
            print("[ProNotch] \(account) 迁入钥匙串失败（明文已保留，下次启动重试）: \(error)")
        }
        return report
    }

    /// 把表单草稿提交为正式设置并持久化
    func saveSettings() {
        baseURL = draftBaseURL.trimmingCharacters(in: .whitespaces)
        apiKey = draftAPIKey.trimmingCharacters(in: .whitespaces)
        model = draftModel.trimmingCharacters(in: .whitespaces)
        tavilyKey = draftTavilyKey.trimmingCharacters(in: .whitespaces)
        braveKey = draftBraveKey.trimmingCharacters(in: .whitespaces)
        searchEngine = draftSearchEngine
        providerRevision += 1   // 端点/Key/模型都可能变，在途的异步结果一律作废
        draftBaseURL = baseURL
        draftAPIKey = apiKey
        draftModel = model
        draftTavilyKey = tavilyKey
        draftBraveKey = braveKey
        let defaults = env.defaults
        defaults.set(baseURL, forKey: PrefKey.chatBaseURL)
        defaults.set(model, forKey: PrefKey.chatModel)
        defaults.set(searchEngine, forKey: "chatSearchEngine")
        // 写回当前套配置存档（名称、URL、模型、模型列表），Key 存这套自己的钥匙串账号
        let account = currentKeychainAccount
        if let i = providers.firstIndex(where: { $0.id == currentProviderID }) {
            let trimmedName = draftName.trimmingCharacters(in: .whitespaces)
            providers[i].name = trimmedName.isEmpty ? Self.inferName(from: baseURL) : trimmedName
            providers[i].baseURL = baseURL
            providers[i].model = model
            providers[i].fetchedModels = availableModels
            providers[i].customModels = customModels
            draftName = providers[i].name
            persistProviders()
        }
        // Key 只进钥匙串，不落明文配置
        env.saveKey(apiKey, account: account)
        env.saveKey(tavilyKey, account: "chatTavilyKey")
        env.saveKey(braveKey, account: "chatBraveKey")
        print("[ProNotch] 已保存 AI 设置，端点: \((try? currentRequestConfig().chatCompletionsURL())?.absoluteString ?? "无效")")
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
        let providerID = currentProviderID
        let revision = providerRevision
        let transport = env.transport
        Task { [weak self] in
            do {
                let models = try await Self.fetchAvailableModels(
                    baseURL: url, apiKey: key, transport: transport)
                guard let self, self.isStillCurrent(providerID, revision) else { return }
                self.updateAvailableModels(models)   // 探测顺带刷新列表，切换器保持新鲜
                self.connectivity = .ok
                print("[ProNotch] API 连通检测: 正常")
            } catch {
                guard let self, self.isStillCurrent(providerID, revision) else { return }
                self.connectivity = .failed(error.localizedDescription)
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
        let providerID = currentProviderID
        let revision = providerRevision
        let transport = env.transport
        Task { [weak self] in
            do {
                let models = try await Self.fetchAvailableModels(
                    baseURL: url, apiKey: key, transport: transport)
                // 拉了半天回来时用户已经切到别套：这份列表属于上一套，写进去就是张冠李戴
                guard let self, self.isStillCurrent(providerID, revision) else { return }
                self.updateAvailableModels(models)
                // 模型栏为空时自动填入第一个，少点一次
                if self.draftModel.trimmingCharacters(in: .whitespaces).isEmpty,
                   let first = models.first {
                    self.draftModel = first
                }
                print("[ProNotch] 获取到 \(models.count) 个模型")
            } catch {
                guard let self, self.isStillCurrent(providerID, revision) else { return }
                self.fetchError = error.localizedDescription
            }
            guard let self, self.isStillCurrent(providerID, revision) else { return }
            self.fetchingModels = false
        }
    }

    /// 右上角切换模型：立即生效并持久化，不必进设置表单
    func selectModel(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != model else { return }
        model = trimmed
        draftModel = trimmed
        env.defaults.set(trimmed, forKey: PrefKey.chatModel)
        syncCurrentProviderModels()
        print("[ProNotch] 已切换模型: \(trimmed)")
    }

    /// 模型列表既供设置表单也供右上角切换器，持久化后重启即用
    private func updateAvailableModels(_ models: [String]) {
        availableModels = models
        env.defaults.set(models, forKey: "chatAvailableModels")
        syncCurrentProviderModels()
    }

    /// 切换器展示的合并列表：手动添加的在前 + 服务端列表，去重；
    /// 当前模型两边都没有（设置表单直接填的）也补进来
    var switcherModels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in customModels + availableModels where seen.insert(m).inserted { out.append(m) }
        if !model.isEmpty, !seen.contains(model) { out.insert(model, at: 0) }
        return out
    }

    /// 往当前套的模型列表添加一个模型（设置页用）：只入列表、不切当前，重名不收
    func addModelToList(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !customModels.contains(trimmed), !availableModels.contains(trimmed) else { return }
        customModels.append(trimmed)
        env.defaults.set(customModels, forKey: "chatCustomModels")
        syncCurrentProviderModels()
        print("[ProNotch] 已添加模型到列表: \(trimmed)")
    }

    /// 移除手动添加的模型；正在用的不强制切走（列表里仍会显示当前模型）
    func removeCustomModel(_ name: String) {
        customModels.removeAll { $0 == name }
        env.defaults.set(customModels, forKey: "chatCustomModels")
        syncCurrentProviderModels()
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
        ensureCurrentConversation()
        messages.append(ChatMessage(role: .user, content: trimmed, imageData: attachment))
        let history = messages.map(Self.payloadEntry)
        messages.append(ChatMessage(role: .assistant, content: ""))
        if let i = currentIndex {
            // 首条用户消息当侧栏标题（压掉换行，取一行放得下的长度）
            if conversations[i].title.isEmpty {
                let flat = trimmed.replacingOccurrences(of: "\n", with: " ")
                conversations[i].title = String(flat.prefix(20))
            }
            conversations[i].updatedAt = Date()
        }
        streamingConvID = currentID
        persistConversations()
        isStreaming = true
        // 快照在这生成一次：之后查询改写、搜索、流式请求都只认它。
        // 用户中途切 Provider 不再影响这一轮——本轮从头到尾是同一套配置
        let config = currentRequestConfig()
        streamTask = Task { [weak self] in
            await self?.run(question: trimmed, history: history, config: config)
        }
    }

    /// 完整一轮：可选联网搜索（查询改写 → 搜索 → 结果注入最后一条用户消息）→ 流式请求
    private func run(question: String, history: [[String: Any]], config: ChatRequestConfig) async {
        var payload = history
        if webSearchEnabled {
            isSearching = true
            do {
                // 先让模型把口语化问题（含上下文指代）改写成搜索词，失败则用原话
                let query = await rewriteQuery(history: history, config: config) ?? question
                let results = try await WebSearch.search(
                    query: query, engine: config.searchEngine, key: config.searchKey)
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
        await stream(payload: payload, config: config)
    }

    private func cancelBeforeStream() {
        isStreaming = false
        withStreamingConv { msgs in
            if let last = msgs.last, last.role == .assistant, last.content.isEmpty {
                msgs.removeLast()
            }
        }
        persistConversations()
        print("[ProNotch] 已在搜索阶段停止")
    }

    private func setLastAssistantSearchCount(_ count: Int) {
        withStreamingConv { msgs in
            if let index = msgs.indices.last, msgs[index].role == .assistant {
                msgs[index].searchResultCount = count
            }
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
    private func rewriteQuery(history: [[String: Any]], config: ChatRequestConfig) async -> String? {
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
            let raw = try await completeOnce(payload: payload, config: config)
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
    private func completeOnce(payload: [[String: String]],
                             config: ChatRequestConfig) async throws -> String {
        var request = URLRequest(url: try config.chatCompletionsURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "messages": payload,
            "stream": false,
        ])
        let (data, response) = try await env.transport.data(for: request)
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

    /// 拉取服务端可用模型列表（GET /v1/models，OpenAI 兼容）。
    /// 用表单当场填写的地址和 Key，不要求先保存
    static func fetchAvailableModels(baseURL: String, apiKey: String,
                                     transport: HTTPTransporting = URLSessionTransport()) async throws -> [String] {
        var request = URLRequest(url: try ChatRequestConfig.modelsURL(baseURL: baseURL))
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespaces))",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
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

    private func stream(payload: [[String: Any]], config: ChatRequestConfig) async {
        defer {
            isStreaming = false
            streamTask = nil
            persistConversations()   // 成功、失败、停止统一在这落盘
        }
        do {
            var request = URLRequest(url: try config.chatCompletionsURL())
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "messages": payload,
                "stream": true,
            ])

            let (lines, response) = try await env.transport.stream(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // 错误正文按行收，够拼错误信息即止（原先是收 4096 字节，同一条 JSON 错误的呈现一致）
                var detail = ""
                for try await line in lines {
                    detail += line
                    if detail.count > 4096 { break }
                }
                throw NSError(domain: "ProNotch", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey:
                                  "HTTP \(http.statusCode) \(detail.prefix(200))"])
            }

            for try await line in lines {
                try Task.checkCancellation()   // 点「停止」时与原先的 bytes.lines 一样立刻抛 CancellationError
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
            let chars = conversations.first(where: { $0.id == streamingConvID })?
                .messages.last?.content.count ?? 0
            print("[ProNotch] AI 回复完成（\(chars) 字符）")
            // 真实对话成功是最可靠的连通证据，顺带刷新状态灯
            connectivity = .ok
        } catch is CancellationError {
            print("[ProNotch] AI 回复已停止")
        } catch let error as URLError where error.code == .cancelled {
            print("[ProNotch] AI 回复已停止")
        } catch {
            errorText = error.localizedDescription
            var imageStripped = false
            withStreamingConv { msgs in
                // 失败时移除空的占位回复
                if let last = msgs.last, last.role == .assistant, last.content.isEmpty {
                    msgs.removeLast()
                }
                // 关键：本次带图的 user 消息若发送失败，去掉它的图片（保留文字）——否则这条 image_url 会
                // 永久留在历史，之后每次请求都重发它、被不支持图片的模型反复 400，会话彻底卡死。
                if let idx = msgs.indices.last, msgs[idx].role == .user, msgs[idx].imageData != nil {
                    msgs[idx].imageData = nil
                    imageStripped = true
                }
            }
            if imageStripped {
                errorText = "图片发送失败，当前模型可能不支持图片：\(error.localizedDescription)"
            }
            print("[ProNotch] AI 请求失败: \(error.localizedDescription)")
            // 状态灯不因单次请求失败就常红——单次失败（尤其 400 请求内容问题，如图片不支持）不代表
            // 连接坏了。用轻量 GET /models 探测真实连通来定灯色：连接正常自动转绿，真断了才保持红。
            checkConnectivity(force: true)
        }
    }

    private func appendToLastAssistant(_ chunk: String) {
        withStreamingConv { msgs in
            guard let last = msgs.indices.last, msgs[last].role == .assistant else { return }
            msgs[last].content += chunk
        }
    }
}
