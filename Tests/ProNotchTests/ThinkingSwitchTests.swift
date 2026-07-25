import XCTest
@testable import ProNotch

/// 深度思考开关（`thinking` 字段）的三条约定：
/// ① 开着就一个字段都不发，别家接口不会因陌生键平白 4xx；
/// ② 模型不认这个字段时自动摘掉重发，只提醒不报错；
/// ③ Key 失效、模型名过期这些同为 4xx 的真错因，绝不能被甩锅成「不支持深度思考」。
@MainActor
final class ThinkingSwitchTests: XCTestCase {

    /// 首轮按需返回 4xx、重发返回 200 的假传输层，用来验兜底重发
    private final class FallbackTransport: HTTPTransporting, @unchecked Sendable {
        /// 带 thinking 的请求一律回这个状态码（400=不认识该字段；200=支持）
        var statusForThinking = 400
        /// 不带 thinking 的请求回这个状态码（401 用来模拟「真错因是 Key」）
        var statusForPlain = 200
        var chatBodies: [[String: Any]] = []

        private func record(_ request: URLRequest) -> Bool {
            let body = request.httpBody
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if request.url?.path.hasSuffix("/chat/completions") == true { chatBodies.append(body) }
            return body["thinking"] != nil
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let hasThinking = record(request)
            let code = hasThinking ? statusForThinking : statusForPlain
            let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(#"{"choices":[{"message":{"content":"改写"}}]}"#.utf8), response)
        }

        func stream(for request: URLRequest) async throws
            -> (AsyncThrowingStream<String, Error>, URLResponse) {
            let hasThinking = record(request)
            let code = hasThinking ? statusForThinking : statusForPlain
            let lines = code == 200
                ? ["data: {\"choices\":[{\"delta\":{\"content\":\"回复正文\"}}]}", "data: [DONE]"]
                : [#"{"error":{"message":"unknown field: thinking"}}"#]
            let stream = AsyncThrowingStream<String, Error> { c in
                lines.forEach { c.yield($0) }
                c.finish()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                           httpVersion: nil, headerFields: nil)!
            return (stream, response)
        }

        /// 打向对话端点的请求里，各自带没带 thinking
        var thinkingFlags: [Bool] { chatBodies.map { $0["thinking"] != nil } }
    }

    private var defaults: UserDefaults!
    private var domain: String!
    private var tempDir: URL!
    private var transport: FallbackTransport!

    override func setUp() {
        super.setUp()
        domain = "com.daliangpro.ProNotchTests.thinking.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProNotchTests-\(UUID().uuidString)")
        transport = FallbackTransport()
        ThinkingSupport.shared.reset()   // 记账是进程内共享的，用例之间必须清干净
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: tempDir)
        ThinkingSupport.shared.reset()
        super.tearDown()
    }

    private func makeStore() -> ChatStore {
        defaults.set("https://api.example.com/v1", forKey: PrefKey.chatBaseURL)
        defaults.set("model-x", forKey: PrefKey.chatModel)
        defaults.set("sk-test", forKey: "chatAPIKey")   // 测试参数域，绕开钥匙串
        return ChatStore(env: ChatEnvironment(
            defaults: defaults, keychain: FakeKeychain(), keychainService: "test.service",
            transport: transport, conversationsURL: tempDir.appendingPathComponent("chat.json"),
            plaintextDomain: nil))
    }

    /// 什么都不做的内存钥匙串（本组用例不关心 Key 存取）
    private final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
        func read(_ account: String, service: String) -> Result<String?, KeychainError> { .success(nil) }
        func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
        func delete(_ account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待超时: \(label)"); return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    // MARK: - 判定与请求体

    func test记账_不支持的模型不再重复发thinking() {
        let s = ThinkingSupport.shared
        XCTAssertFalse(s.shouldSendDisabled(thinkingOn: true, baseURL: "u", model: "m"),
                       "开着深度思考时一个字段都不该发")
        XCTAssertTrue(s.shouldSendDisabled(thinkingOn: false, baseURL: "u", model: "m"))
        s.markUnsupported(baseURL: "u", model: "m")
        XCTAssertFalse(s.shouldSendDisabled(thinkingOn: false, baseURL: "u", model: "m"),
                       "记过账就别再白撞一轮 4xx")
        // 身份是「端点+模型」：换个端点的同名模型不受影响
        XCTAssertTrue(s.shouldSendDisabled(thinkingOn: false, baseURL: "u2", model: "m"))
    }

    func test闪问请求体_只在关闭时带thinking() {
        let config = ChatRequestConfig(providerID: UUID(), baseURL: "https://x.com/v1",
                                       apiKey: "k", model: "m",
                                       searchEngine: .duckduckgo, searchKey: "", thinking: false)
        let msgs = [["role": "user", "content": "你好"]]
        let on = ChatStore.requestBody(msgs, config: config, stream: true, disableThinking: false)
        XCTAssertNil(on["thinking"])
        XCTAssertEqual(on["stream"] as? Bool, true)

        let off = ChatStore.requestBody(msgs, config: config, stream: false, disableThinking: true)
        XCTAssertEqual(off["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(off["stream"] as? Bool, false)
        XCTAssertEqual(off["model"] as? String, "m")
    }

    // MARK: - 兜底重发

    func test模型不认thinking_摘掉重发并给提醒而非报错() async {
        let store = makeStore()
        store.thinkingEnabled = false
        store.send("你好")
        await waitUntil("回复写完") { store.messages.last?.content == "回复正文" }

        XCTAssertEqual(transport.thinkingFlags, [true, false], "首轮带字段被拒，应摘掉重发一次")
        XCTAssertEqual(store.noticeText, ThinkingSupport.notice, "该给提醒")
        XCTAssertNil(store.errorText, "这不是失败，不该报错")

        // 记过账后，下一问直接不带该字段，不再白撞
        transport.chatBodies = []
        store.send("再问一句")
        await waitUntil("第二问回复写完") { store.messages.last?.content == "回复正文" }
        XCTAssertEqual(transport.thinkingFlags, [false], "第二问就该一次到位")
    }

    func test真错因是Key_不甩锅给深度思考() async {
        transport.statusForPlain = 401   // 摘掉 thinking 也照样失败＝真错因另有其人
        let store = makeStore()
        store.thinkingEnabled = false
        store.send("你好")
        await waitUntil("报错落地") { store.errorText != nil }

        XCTAssertNil(store.noticeText, "重发没成功就不能说是「模型不支持深度思考」")
        XCTAssertTrue(store.errorText?.contains("400") == true, "该原样报出首轮的真实状态码")
        XCTAssertTrue(ThinkingSupport.shared.shouldSendDisabled(
            thinkingOn: false, baseURL: "https://api.example.com/v1", model: "model-x"),
                      "不能把这个模型误记成不支持")
    }

    func test开着深度思考_全程不发thinking字段() async {
        let store = makeStore()
        store.thinkingEnabled = true
        store.send("你好")
        await waitUntil("回复写完") { store.messages.last?.content == "回复正文" }
        XCTAssertEqual(transport.thinkingFlags, [false], "开着＝随服务端默认，一个字段都不发")
        XCTAssertNil(store.noticeText)
    }
}
