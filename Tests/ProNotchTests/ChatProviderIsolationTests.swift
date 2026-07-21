import XCTest
@testable import ProNotch

/// 多套 API 配置之间的隔离：迟到的异步结果绝不能落到当前这一套头上。
///
/// 用户切 Provider 是一瞬间的事，而钥匙串读取、连通检测、模型列表拉取、
/// 整轮对话都是几百毫秒到几十秒的事。这里每个用例都构造"发起时是 A、
/// 回来时已是 B"的时序，断言 B 不被污染。
@MainActor
final class ChatProviderIsolationTests: XCTestCase {

    // MARK: - 测试替身

    /// 内存钥匙串；可对指定账户挂闸，模拟"这一套的 Key 读得特别慢"
    private final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var gates: [String: DispatchSemaphore] = [:]

        func seed(_ value: String, account: String) {
            lock.lock(); values[account] = value; lock.unlock()
        }

        /// 给某账户挂闸：读到它就卡住，直到 `open(account:)`
        func gate(_ account: String) {
            lock.lock(); gates[account] = DispatchSemaphore(value: 0); lock.unlock()
        }

        func open(_ account: String) {
            lock.lock(); let g = gates[account]; lock.unlock()
            g?.signal()
        }

        func read(_ account: String, service: String) -> Result<String?, KeychainError> {
            lock.lock(); let gate = gates[account]; lock.unlock()
            gate?.wait()   // 后台线程上等，主线程照常处理用户的切换操作
            lock.lock(); let value = values[account]; lock.unlock()
            return .success(value)
        }

        func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> {
            lock.lock(); values[account] = value; lock.unlock()
            return .success(())
        }

        func delete(_ account: String, service: String) -> Result<Void, KeychainError> {
            lock.lock(); values[account] = nil; lock.unlock()
            return .success(())
        }
    }

    /// 记录真实发出的请求；可挂闸让请求悬在半空，好在此期间切走 Provider。
    /// ChatStore 是 @MainActor，这些方法都在主 actor 上跑，无需加锁
    private final class FakeTransport: HTTPTransporting, @unchecked Sendable {
        var requests: [URLRequest] = []
        var dataBody = Data(#"{"choices":[{"message":{"content":"改写后的查询词"}}]}"#.utf8)
        var dataStatus = 200
        /// data() 悬停开关：置 true 后请求会停在这，直到 releaseData()
        var holdData = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var streamLines: [String] = ["data: {\"choices\":[{\"delta\":{\"content\":\"回复\"}}]}", "data: [DONE]"]

        func releaseData() {
            let pending = waiters
            waiters = []
            holdData = false
            pending.forEach { $0.resume() }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            if holdData {
                await withCheckedContinuation { waiters.append($0) }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: dataStatus,
                                           httpVersion: nil, headerFields: nil)!
            guard request.url?.path.hasSuffix("/models") == true else { return (dataBody, response) }
            // 模型列表按主机名区分，才能验出"A 的列表落到了 B 上"
            let host = request.url?.host ?? "?"
            return (Data(#"{"data":[{"id":"模型-\#(host)"}]}"#.utf8), response)
        }

        func stream(for request: URLRequest) async throws
            -> (AsyncThrowingStream<String, Error>, URLResponse) {
            requests.append(request)
            let lines = streamLines
            let stream = AsyncThrowingStream<String, Error> { continuation in
                lines.forEach { continuation.yield($0) }
                continuation.finish()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (stream, response)
        }

        /// 所有打向对话端点的请求（Key 回填会顺带打 /models，要排除掉）
        func chatCalls() -> [(url: String, key: String, model: String)] {
            requests.filter { $0.url?.path.hasSuffix("/chat/completions") == true }.map { r in
                let key = (r.value(forHTTPHeaderField: "Authorization") ?? "")
                    .replacingOccurrences(of: "Bearer ", with: "")
                let model = r.httpBody
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { $0?["model"] as? String } ?? ""
                return (r.url?.absoluteString ?? "", key, model)
            }
        }
    }

    // MARK: - 夹具

    private var defaults: UserDefaults!
    private var domain: String!
    private var tempDir: URL!
    private var keychain: FakeKeychain!
    private var transport: FakeTransport!

    private let idA = UUID(), idB = UUID(), idC = UUID()

    override func setUp() {
        super.setUp()
        domain = "com.daliangpro.ProNotchTests.provider.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProNotchTests-\(UUID().uuidString)")
        keychain = FakeKeychain()
        transport = FakeTransport()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// 三套配置：A/B/C 各自独立的端点、Key、模型
    private func seedProviders(current: UUID) {
        let list = [
            APIProvider(id: idA, name: "A", baseURL: "https://a.example.com/v1",
                        model: "model-a", keychainAccount: "kcA"),
            APIProvider(id: idB, name: "B", baseURL: "https://b.example.com/v1",
                        model: "model-b", keychainAccount: "kcB"),
            APIProvider(id: idC, name: "C", baseURL: "https://c.example.com/v1",
                        model: "model-c", keychainAccount: "kcC"),
        ]
        defaults.set(try! JSONEncoder().encode(list), forKey: "chatProviders")
        defaults.set(current.uuidString, forKey: "chatCurrentProviderID")
        keychain.seed("key-A", account: "kcA")
        keychain.seed("key-B", account: "kcB")
        keychain.seed("key-C", account: "kcC")
    }

    private func makeStore() -> ChatStore {
        ChatStore(env: ChatEnvironment(
            defaults: defaults,
            keychain: keychain,
            keychainService: "test.service",
            transport: transport,
            conversationsURL: tempDir.appendingPathComponent("chat.json"),
            plaintextDomain: nil))
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待超时: \(label)"); return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    // MARK: - Key 回填

    func test切换中途的Key回填_不写入新Provider() async {
        seedProviders(current: idB)
        let store = makeStore()
        await waitUntil("B 的 Key 回填完成") { store.apiKey == "key-B" }

        keychain.gate("kcA")                 // A 的 Key 读得很慢
        store.activateProvider(idA)
        XCTAssertEqual(store.apiKey, "", "切过去时先清空，等回填")
        store.activateProvider(idB)          // 用户等不及，切回 B
        await waitUntil("切回 B 后 Key 就位") { store.apiKey == "key-B" }

        keychain.open("kcA")                 // A 的 Key 现在才回来
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.apiKey, "key-B", "A 的迟到 Key 绝不能盖在 B 上")
        XCTAssertEqual(store.currentProviderID, idB)
    }

    func test快速连切ABC_只有最后一套的Key落地() async {
        seedProviders(current: idA)
        let store = makeStore()
        await waitUntil("A 的 Key 回填完成") { store.apiKey == "key-A" }

        keychain.gate("kcB")
        keychain.gate("kcC")
        store.activateProvider(idB)
        store.activateProvider(idC)
        keychain.open("kcB")                 // B 的结果先回来，但它已经不是当前套了
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(store.apiKey, "", "B 已被切走，它的 Key 不该落地")

        keychain.open("kcC")
        await waitUntil("C 的 Key 落地") { store.apiKey == "key-C" }
        XCTAssertEqual(store.currentProviderID, idC)
    }

    func test删除当前套后的回填_不覆盖之后切去的那套() async {
        seedProviders(current: idA)
        let store = makeStore()
        await waitUntil("A 的 Key 回填完成") { store.apiKey == "key-A" }

        keychain.gate("kcB")
        store.deleteProvider(idA)            // 删当前套 → 自动落到 B，并开始读 B 的 Key
        store.activateProvider(idC)          // 用户紧接着切到 C
        await waitUntil("C 的 Key 落地") { store.apiKey == "key-C" }

        keychain.open("kcB")                 // B 的回填迟到
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.apiKey, "key-C", "删除后那次回填也要校验身份")
        XCTAssertEqual(store.currentProviderID, idC)
    }

    // MARK: - 连通检测与模型列表

    func test连通性结果迟到_不改变新Provider状态() async {
        seedProviders(current: idA)
        let store = makeStore()
        await waitUntil("A 的 Key 回填完成") { store.apiKey == "key-A" }

        transport.holdData = true
        transport.dataStatus = 500           // A 这次探测会失败
        store.checkConnectivity(force: true)
        await waitUntil("探测已发出") { !self.transport.requests.isEmpty }

        keychain.seed("", account: "kcB")    // B 没配 Key → 不会自发探测，状态可判定
        store.activateProvider(idB)
        transport.releaseData()
        try? await Task.sleep(nanoseconds: 50_000_000)

        if case .failed = store.connectivity {
            XCTFail("A 的失败结果不该染红 B 的状态灯")
        }
    }

    func test模型列表迟到_不写入新Provider() async {
        seedProviders(current: idA)
        let store = makeStore()
        await waitUntil("A 的 Key 回填完成") { store.apiKey == "key-A" }

        transport.holdData = true
        store.fetchModels()
        await waitUntil("模型请求已发出") { !self.transport.requests.isEmpty }

        store.activateProvider(idB)
        transport.releaseData()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(store.availableModels.contains("模型-a.example.com"),
                       "A 的模型列表迟到落到 B 上，切换器就会列出 B 根本没有的模型")
    }

    // MARK: - 一轮对话贯穿同一份快照

    func test发送中途切走_流式请求仍用发起时那套配置() async {
        seedProviders(current: idA)
        // Brave + 空 Key：搜索会在本地直接抛错，不触网，但保留"搜索阶段"这段耗时
        defaults.set(true, forKey: "chatWebSearchEnabled")
        defaults.set(SearchEngine.brave.rawValue, forKey: "chatSearchEngine")
        let store = makeStore()
        await waitUntil("A 的 Key 回填完成") { store.apiKey == "key-A" }

        transport.holdData = true            // 卡在查询改写这一步
        store.send("今天天气如何")
        await waitUntil("查询改写已发出") { !self.transport.requests.isEmpty }

        store.activateProvider(idB)          // 就在这时用户切到了 B
        await waitUntil("B 的 Key 回填完成") { store.apiKey == "key-B" }
        transport.releaseData()

        // 查询改写一次 + 流式一次，两次都属于这一轮对话
        await waitUntil("流式请求发出") { self.transport.chatCalls().count >= 2 }
        for call in transport.chatCalls() {
            XCTAssertEqual(call.url, "https://a.example.com/v1/chat/completions",
                           "切走后建的请求仍必须打向 A 的端点")
            XCTAssertEqual(call.key, "key-A", "把 A 的对话带着 B 的 Key 发出去，等于跨服务商泄露")
            XCTAssertEqual(call.model, "model-a")
        }
    }

    // MARK: - 端点规范化

    func test端点规范化() throws {
        let config = ChatRequestConfig(providerID: UUID(), baseURL: "https://x.com/v1/",
                                       apiKey: "k", model: "m",
                                       searchEngine: .duckduckgo, searchKey: "")
        XCTAssertEqual(try config.chatCompletionsURL().absoluteString,
                       "https://x.com/v1/chat/completions")
        XCTAssertEqual(try ChatRequestConfig.modelsURL(baseURL: "https://x.com/v1/chat/completions")
            .absoluteString, "https://x.com/v1/models")
        XCTAssertEqual(try ChatRequestConfig.modelsURL(baseURL: "https://x.com").absoluteString,
                       "https://x.com/v1/models")
    }
}
