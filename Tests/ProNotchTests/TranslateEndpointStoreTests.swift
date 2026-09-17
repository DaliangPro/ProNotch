import XCTest
@testable import ProNotch

/// 翻译接口从「一套」变「多套」之后，老用户的那套不能丢、各套的 Key 不能串。
///
/// 病灶（大梁老师 2026-08-17 反馈）：翻译原本只存 `translateBaseURL` /
/// `translateModel` 两个字符串，换一个服务商就把上一个盖掉，想切回去只能凭记忆
/// 重敲地址、Key 和模型名。
///
/// 迁移这件事最容易踩的坑是搬 Key：Key 在钥匙串里，启动路径上一读就可能弹授权框。
/// 这里的做法是首套**沿用旧账号名**，一个字节都不搬——下面头两条用例钉的就是它。
final class TranslateEndpointStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "translate-endpoints-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 迁移

    func test无存档时把单套配置迁成第一套() {
        let list = TranslateEndpointStore.load(from: defaults,
                                               legacyBaseURL: "https://api.deepseek.com",
                                               legacyModel: "deepseek-v4-flash")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].baseURL, "https://api.deepseek.com")
        XCTAssertEqual(list[0].model, "deepseek-v4-flash")
        XCTAssertEqual(list[0].name, "Deepseek", "名字该从域名猜出来")
    }

    /// 迁过来的第一套必须继续用老账号：搬 Key 就得读钥匙串，
    /// 而这段代码跑在启动路径上，一读就可能多弹一次授权框
    func test迁移沿用旧钥匙串账号_不搬Key() {
        let list = TranslateEndpointStore.load(from: defaults,
                                               legacyBaseURL: "https://api.x.com", legacyModel: "m")
        XCTAssertEqual(list[0].keychainAccount, TranslateEndpointStore.legacyAccount)
        XCTAssertEqual(TranslateEndpointStore.legacyAccount, "translateAPIKey",
                       "账号名变了，老用户已经填好的 Key 就读不到了")
    }

    func test地址为空时也迁得出一套_不至于没得可选() {
        let list = TranslateEndpointStore.load(from: defaults, legacyBaseURL: "", legacyModel: "")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "默认")
    }

    func test有存档时原样读出_不再拿老键覆盖() {
        let saved = [TranslateEndpoint(name: "本地", baseURL: "http://127.0.0.1:11434",
                                       model: "qwen", keychainAccount: "translateAPIKey-abc")]
        TranslateEndpointStore.persist(saved, current: saved[0].id, to: defaults)

        let list = TranslateEndpointStore.load(from: defaults,
                                               legacyBaseURL: "https://api.deepseek.com",
                                               legacyModel: "deepseek-v4-flash")
        XCTAssertEqual(list, saved, "存档在就该以存档为准，老键只是迁移用的种子")
    }

    // MARK: - 当前选中

    func test当前选中被删过后退回第一套() {
        let a = TranslateEndpoint(name: "A", baseURL: "https://a.com", model: "m",
                                  keychainAccount: "translateAPIKey")
        let b = TranslateEndpoint(name: "B", baseURL: "https://b.com", model: "m",
                                  keychainAccount: "translateAPIKey-b")
        TranslateEndpointStore.persist([a, b], current: b.id, to: defaults)
        // B 被删了，存档里只剩 A，但「当前」还指着 B
        TranslateEndpointStore.persist([a], current: b.id, to: defaults)

        XCTAssertEqual(TranslateEndpointStore.currentID(from: defaults, in: [a]), a.id,
                       "指向不存在的那套会让界面一片空白")
    }

    func test存过的当前选中能读回来() {
        let a = TranslateEndpoint(name: "A", baseURL: "https://a.com", model: "m",
                                  keychainAccount: "translateAPIKey")
        let b = TranslateEndpoint(name: "B", baseURL: "https://b.com", model: "m",
                                  keychainAccount: "translateAPIKey-b")
        TranslateEndpointStore.persist([a, b], current: b.id, to: defaults)
        XCTAssertEqual(TranslateEndpointStore.currentID(from: defaults, in: [a, b]), b.id)
    }

    // MARK: - 钥匙串账号

    /// 每新增一套都得有自己的账号，否则第二套的 Key 会把第一套的盖掉——
    /// 那就退回「填了新的老的就没了」，正是这次要修的病
    func test新增的钥匙串账号互不相同且不撞旧账号() {
        let accounts = (0..<8).map { _ in TranslateEndpointStore.newAccount() }
        XCTAssertEqual(Set(accounts).count, accounts.count, "账号重复，两套的 Key 会互相覆盖")
        XCTAssertFalse(accounts.contains(TranslateEndpointStore.legacyAccount),
                       "撞上旧账号会把老用户填好的 Key 顶掉")
        XCTAssertTrue(accounts.allSatisfy { $0.hasPrefix(TranslateEndpointStore.legacyAccount) },
                      "统一前缀，将来按前缀清理才找得全")
    }

    // MARK: - 读写同源

    /// 写 Key 与读 Key 必须问同一个账号。
    ///
    /// 病灶（2026-08-17 实测）：保存走「当前套的账号」，翻译取 Key 却写死成
    /// `translateAPIKey`。于是新建那套填了正确的 Key、连通性测试也通过，
    /// 一到真翻译还是报鉴权失败——取到的始终是第一套里那个填错的旧 Key。
    func test每套各认各的账号() {
        let a = TranslateEndpoint(name: "A", baseURL: "https://a.com", model: "m",
                                  keychainAccount: TranslateEndpointStore.legacyAccount)
        let b = TranslateEndpoint(name: "B", baseURL: "https://b.com", model: "m",
                                  keychainAccount: "translateAPIKey-b")
        let list = [a, b]

        XCTAssertEqual(TranslateEndpointStore.account(for: a.id, in: list),
                       TranslateEndpointStore.legacyAccount)
        XCTAssertEqual(TranslateEndpointStore.account(for: b.id, in: list), "translateAPIKey-b")
        XCTAssertNotEqual(TranslateEndpointStore.account(for: a.id, in: list),
                          TranslateEndpointStore.account(for: b.id, in: list),
                          "两套认同一个账号，后填的 Key 会盖掉前一套")
    }

    func test没选中任何一套时退回旧账号_老用户的Key还读得到() {
        XCTAssertEqual(TranslateEndpointStore.account(for: nil, in: []),
                       TranslateEndpointStore.legacyAccount)
    }

    /// 不许再把账号名写死：这个坑闪问栽过一次、翻译又栽一次，
    /// 靠人记不住，交给测试盯着——取 Key 一律经 `TranslateEndpointStore.account`
    func test取Key的地方不许把账号名写死() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ProNotchTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let src = try String(contentsOf: root.appendingPathComponent(
            "Sources/ProNotch/Settings/SettingsStore.swift"), encoding: .utf8)
        for line in src.split(separator: "\n")
        where line.contains("KeychainStore.read") || line.contains("KeychainStore.save") {
            XCTAssertFalse(line.contains("\"\(TranslateEndpointStore.legacyAccount)\""),
                           "又把账号写死了，切套之后读到的还是第一套的 Key：\(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    // MARK: - 猜名字

    func test从域名猜配置名() {
        XCTAssertEqual(TranslateEndpointStore.inferName(from: "https://api.deepseek.com/v1"), "Deepseek")
        XCTAssertEqual(TranslateEndpointStore.inferName(from: "https://api.openai.com"), "Openai")
        XCTAssertEqual(TranslateEndpointStore.inferName(from: "http://localhost:11434"), "localhost")
        XCTAssertEqual(TranslateEndpointStore.inferName(from: ""), "默认")
    }

    // MARK: - 往返

    func test存档往返不丢字段() throws {
        let list = [TranslateEndpoint(name: "本地 Ollama", baseURL: "http://127.0.0.1:11434/v1",
                                      model: "qwen2.5:7b", keychainAccount: "translateAPIKey-x")]
        TranslateEndpointStore.persist(list, current: list[0].id, to: defaults)
        let back = TranslateEndpointStore.load(from: defaults, legacyBaseURL: "", legacyModel: "")
        XCTAssertEqual(back, list)
        XCTAssertEqual(TranslateEndpointStore.currentID(from: defaults, in: back), list[0].id)
    }
}
