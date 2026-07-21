import XCTest
@testable import ProNotch

/// 截图原位翻译「复用闪问接口」时取哪一套配置。
///
/// 闪问是多套 Provider：每套有自己的端点、模型、钥匙串账号，切套不需要按保存。
/// 而 `chatBaseURL` / `chatModel` 只在按保存时才写，固定账号 `chatAPIKey` 又永远
/// 指向第一套。两条老路径拼在一起，用户切到第二套之后翻译就会拿 A 的 Key 请求
/// 上次保存那套的端点——401 是好结果，坏结果是内容送错了服务商。
final class ScreenshotTranslationProviderTests: XCTestCase {

    // MARK: - 假钥匙串

    private final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: String] = [:]

        init(_ initial: [String: String] = [:]) { store = initial }

        func read(_ account: String, service: String) -> Result<String?, KeychainError> {
            lock.lock(); defer { lock.unlock() }
            return .success(store[account])
        }
        func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> {
            lock.lock(); defer { lock.unlock() }
            store[account] = value
            return .success(())
        }
        func delete(_ account: String, service: String) -> Result<Void, KeychainError> {
            lock.lock(); defer { lock.unlock() }
            store[account] = nil
            return .success(())
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ScreenshotTranslationProviderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func env(_ keychain: FakeKeychain) -> ChatEnvironment {
        var e = ChatEnvironment.production
        e.defaults = defaults
        e.keychain = keychain
        e.keychainService = "test.service"
        return e
    }

    private func writeProviders(_ list: [APIProvider], current: UUID?) {
        defaults.set(try! JSONEncoder().encode(list), forKey: "chatProviders")
        if let current { defaults.set(current.uuidString, forKey: "chatCurrentProviderID") }
    }

    private func provider(_ name: String, _ host: String, _ model: String,
                          account: String) -> APIProvider {
        APIProvider(name: name, baseURL: "https://\(host)/v1", model: model, keychainAccount: account)
    }

    // MARK: - 取的是当前活动那一套

    func test取当前活动套_而不是第一套() {
        let a = provider("甲", "a.example.com", "模型甲", account: "chatAPIKey")
        let b = provider("乙", "b.example.com", "模型乙", account: "chatAPIKey-乙")
        writeProviders([a, b], current: b.id)
        // 老路径遗留：上次保存时写下的是甲的端点
        defaults.set("https://a.example.com/v1", forKey: PrefKey.chatBaseURL)
        defaults.set("模型甲", forKey: PrefKey.chatModel)

        let snapshot = ActiveProviderSnapshot.load(
            from: env(FakeKeychain(["chatAPIKey": "KEY-甲", "chatAPIKey-乙": "KEY-乙"])))

        XCTAssertEqual(snapshot.providerID, b.id)
        XCTAssertEqual(snapshot.baseURL, "https://b.example.com/v1")
        XCTAssertEqual(snapshot.model, "模型乙")
        XCTAssertEqual(snapshot.apiKey, "KEY-乙", "拿到甲的 Key 就是把内容送错了服务商")
        XCTAssertEqual(snapshot.readiness, .ready)
    }

    func test切套后未按保存_端点仍跟随当前套() {
        // 切套不写 chatBaseURL，这正是老实现错位的根因
        let a = provider("甲", "a.example.com", "模型甲", account: "chatAPIKey")
        let b = provider("乙", "b.example.com", "模型乙", account: "chatAPIKey-乙")
        writeProviders([a, b], current: b.id)
        defaults.set("https://a.example.com/v1", forKey: PrefKey.chatBaseURL)

        let snapshot = ActiveProviderSnapshot.load(
            from: env(FakeKeychain(["chatAPIKey": "KEY-甲", "chatAPIKey-乙": "KEY-乙"])))
        XCTAssertNotEqual(snapshot.baseURL, defaults.string(forKey: PrefKey.chatBaseURL))
        XCTAssertEqual(snapshot.baseURL, "https://b.example.com/v1")
    }

    func test当前套ID失效_退回第一套而不是空配置() {
        let a = provider("甲", "a.example.com", "模型甲", account: "chatAPIKey")
        writeProviders([a], current: nil)
        defaults.set(UUID().uuidString, forKey: "chatCurrentProviderID")   // 指向已删除的套

        let snapshot = ActiveProviderSnapshot.load(from: env(FakeKeychain(["chatAPIKey": "KEY-甲"])))
        XCTAssertEqual(snapshot.providerID, a.id)
        XCTAssertEqual(snapshot.apiKey, "KEY-甲")
    }

    func test无多套存档_退回单套时代的键() {
        // 老用户还没触发过多套迁移
        defaults.set("https://old.example.com/v1", forKey: PrefKey.chatBaseURL)
        defaults.set("老模型", forKey: PrefKey.chatModel)

        let snapshot = ActiveProviderSnapshot.load(from: env(FakeKeychain(["chatAPIKey": "老KEY"])))
        XCTAssertNil(snapshot.providerID)
        XCTAssertEqual(snapshot.baseURL, "https://old.example.com/v1")
        XCTAssertEqual(snapshot.model, "老模型")
        XCTAssertEqual(snapshot.apiKey, "老KEY")
    }

    // MARK: - 三种就绪状态要分得开

    func test就绪状态_Key未回填算尚未就绪而非未配置() {
        let a = provider("甲", "a.example.com", "模型甲", account: "chatAPIKey-甲")
        writeProviders([a], current: a.id)

        let snapshot = ActiveProviderSnapshot.load(from: env(FakeKeychain()))   // 钥匙串里没这套的 Key
        XCTAssertEqual(snapshot.readiness, .keyPending,
                       "端点和模型都填了，只差 Key——提示用户去设置里配置是误导")
    }

    func test就绪状态_端点或模型缺失才算未配置() {
        let noModel = APIProvider(name: "甲", baseURL: "https://a.example.com/v1", model: "",
                                  keychainAccount: "k1")
        writeProviders([noModel], current: noModel.id)
        XCTAssertEqual(ActiveProviderSnapshot.load(from: env(FakeKeychain(["k1": "KEY"]))).readiness,
                       .notConfigured)

        let noURL = APIProvider(name: "乙", baseURL: "", model: "模型", keychainAccount: "k2")
        writeProviders([noURL], current: noURL.id)
        XCTAssertEqual(ActiveProviderSnapshot.load(from: env(FakeKeychain(["k2": "KEY"]))).readiness,
                       .notConfigured)
    }

    func test就绪状态_全齐才算ready() {
        let a = provider("甲", "a.example.com", "模型甲", account: "k")
        writeProviders([a], current: a.id)
        XCTAssertEqual(ActiveProviderSnapshot.load(from: env(FakeKeychain(["k": "KEY"]))).readiness,
                       .ready)
    }

    // MARK: - 快照能直接喂给翻译器

    func test快照可直接构造翻译配置且端点合法() throws {
        let a = provider("甲", "api.deepseek.com", "deepseek-chat", account: "k")
        writeProviders([a], current: a.id)
        let snapshot = ActiveProviderSnapshot.load(from: env(FakeKeychain(["k": "KEY"])))

        let config = ScreenshotTranslator.Config(baseURL: snapshot.baseURL,
                                                 apiKey: snapshot.apiKey,
                                                 model: snapshot.model,
                                                 keyPending: snapshot.readiness == .keyPending)
        XCTAssertFalse(config.keyPending)
        XCTAssertEqual(try ScreenshotTranslator.completionsURL(config.baseURL).absoluteString,
                       "https://api.deepseek.com/v1/chat/completions")
    }
}
