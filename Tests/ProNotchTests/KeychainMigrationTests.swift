import XCTest
@testable import ProNotch

/// 事务式钥匙串迁移的失败路径。
///
/// 这些路径在真钥匙串上根本没法稳定复现——授权弹框、ACL、SecItem 状态码都不受测试控制，
/// 所以全部靠注入 fake。要守住的底线只有一条：**任何一步失败都不能丢 Key**。
final class KeychainMigrationTests: XCTestCase {

    /// 内存钥匙串；可指定某些账户的写/读/删失败，用来构造事务中断
    private final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
        var items: [Key: String] = [:]
        var failSaveFor: Set<String> = []
        var failDeleteFor: Set<String> = []
        /// 写进新位置后读回来变了（钥匙串写坏 / 被别的进程改掉）。
        /// 只作用于目标 service——否则连"读旧值"这一步都被篡改，测的就不是读回校验了
        var corruptReadbackFor: Set<String> = []
        var corruptService = "com.daliangpro.ProNotch"

        struct Key: Hashable { let account: String; let service: String }

        func read(_ account: String, service: String) -> Result<String?, KeychainError> {
            let k = Key(account: account, service: service)
            if corruptReadbackFor.contains(account), service == corruptService, items[k] != nil {
                return .success("被篡改的值")
            }
            return .success(items[k])
        }

        func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> {
            guard !failSaveFor.contains(account) else { return .failure(.status(-25308)) }
            items[Key(account: account, service: service)] = value
            return .success(())
        }

        func delete(_ account: String, service: String) -> Result<Void, KeychainError> {
            guard !failDeleteFor.contains(account) else { return .failure(.status(-25300)) }
            items[Key(account: account, service: service)] = nil
            return .success(())
        }
    }

    private let newService = "com.daliangpro.ProNotch"
    private let oldService = "com.jiliang.NotchHub"
    private func oldKey(_ a: String) -> FakeKeychain.Key { .init(account: a, service: oldService) }
    private func newKey(_ a: String) -> FakeKeychain.Key { .init(account: a, service: newService) }

    private func makeFake(legacy: [String: String]) -> FakeKeychain {
        let fake = FakeKeychain()
        for (account, value) in legacy { fake.items[oldKey(account)] = value }
        return fake
    }

    private func migrator(_ fake: FakeKeychain) -> KeychainMigrator {
        KeychainMigrator(keychain: fake, currentService: newService)
    }

    // MARK: - 旧 service 搬家

    func test完整成功_旧值删除新值存在() {
        let fake = makeFake(legacy: ["chatAPIKey": "sk-真钥匙"])
        let report = migrator(fake).migrateLegacyService(accounts: ["chatAPIKey"], from: oldService)

        XCTAssertEqual(report.migrated, ["chatAPIKey"])
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(fake.items[newKey("chatAPIKey")], "sk-真钥匙")
        XCTAssertNil(fake.items[oldKey("chatAPIKey")])
    }

    func test写入失败_旧条目仍在且不报完成() {
        let fake = makeFake(legacy: ["chatAPIKey": "sk-真钥匙"])
        fake.failSaveFor = ["chatAPIKey"]
        let report = migrator(fake).migrateLegacyService(accounts: ["chatAPIKey"], from: oldService)

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.failed["chatAPIKey"], .status(-25308))
        XCTAssertEqual(fake.items[oldKey("chatAPIKey")], "sk-真钥匙", "写新位置失败时旧值必须原地保留")
    }

    func test读回不一致_旧条目仍在() {
        let fake = makeFake(legacy: ["chatAPIKey": "sk-真钥匙"])
        fake.corruptReadbackFor = ["chatAPIKey"]
        let report = migrator(fake).migrateLegacyService(accounts: ["chatAPIKey"], from: oldService)

        XCTAssertEqual(report.failed["chatAPIKey"], .verifyMismatch)
        XCTAssertEqual(fake.items[oldKey("chatAPIKey")], "sk-真钥匙", "读回校验没过就删旧值等于丢 Key")
    }

    func test删除旧条目失败_返回失败但新值可读() {
        let fake = makeFake(legacy: ["chatAPIKey": "sk-真钥匙"])
        fake.failDeleteFor = ["chatAPIKey"]
        let report = migrator(fake).migrateLegacyService(accounts: ["chatAPIKey"], from: oldService)

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(fake.items[newKey("chatAPIKey")], "sk-真钥匙", "删旧失败也不该回滚新值——两边都有胜过两边都无")
        XCTAssertEqual(fake.items[oldKey("chatAPIKey")], "sk-真钥匙")
    }

    func test新位置已有值_不覆盖不删旧() {
        let fake = makeFake(legacy: ["chatAPIKey": "sk-旧的"])
        fake.items[newKey("chatAPIKey")] = "sk-用户当前在用"
        let report = migrator(fake).migrateLegacyService(accounts: ["chatAPIKey"], from: oldService)

        XCTAssertEqual(report.skipped, ["chatAPIKey"])
        XCTAssertEqual(fake.items[newKey("chatAPIKey")], "sk-用户当前在用")
    }

    func test重复执行幂等() {
        let fake = makeFake(legacy: ["chatAPIKey": "sk-真钥匙"])
        let m = migrator(fake)
        let first = m.migrateLegacyService(accounts: ["chatAPIKey"], from: oldService)
        let second = m.migrateLegacyService(accounts: ["chatAPIKey"], from: oldService)

        XCTAssertEqual(first.migrated, ["chatAPIKey"])
        XCTAssertEqual(second.skipped, ["chatAPIKey"], "第二遍应识别为无需迁移，不是失败")
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(fake.items[newKey("chatAPIKey")], "sk-真钥匙")
    }

    func test多账户中一个失败_整体不完成而成功的照常搬() {
        let fake = makeFake(legacy: ["chatAPIKey": "sk-a", "chatTavilyKey": "tvly-b"])
        fake.failSaveFor = ["chatTavilyKey"]
        let report = migrator(fake).migrateLegacyService(
            accounts: ["chatAPIKey", "chatTavilyKey"], from: oldService)

        XCTAssertEqual(report.migrated, ["chatAPIKey"])
        XCTAssertFalse(report.isComplete, "有一项失败就不能置迁移完成标记，否则永久放弃重试")
        XCTAssertEqual(fake.items[oldKey("chatTavilyKey")], "tvly-b")
    }

    // MARK: - UserDefaults 明文搬进钥匙串

    /// 每个用例用独立 suite，互不串味
    private func makeDefaults(_ name: String) -> (UserDefaults, String) {
        let domain = "com.daliangpro.ProNotchTests.\(name)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }

    func test明文迁移_校验成功后才删明文() {
        let (defaults, domain) = makeDefaults(#function)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("sk-明文", forKey: "chatAPIKey")

        let fake = FakeKeychain()
        let report = migrator(fake).migratePlaintextKeys(["chatAPIKey"], in: defaults, domain: domain)

        XCTAssertEqual(report.migrated, ["chatAPIKey"])
        XCTAssertEqual(fake.items[newKey("chatAPIKey")], "sk-明文")
        XCTAssertNil(defaults.string(forKey: "chatAPIKey"))
    }

    func test明文迁移_钥匙串写失败时明文保留() {
        let (defaults, domain) = makeDefaults(#function)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("sk-明文", forKey: "chatAPIKey")

        let fake = FakeKeychain()
        fake.failSaveFor = ["chatAPIKey"]
        let report = migrator(fake).migratePlaintextKeys(["chatAPIKey"], in: defaults, domain: domain)

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(defaults.string(forKey: "chatAPIKey"), "sk-明文",
                       "钥匙串没写成功还抹掉明文，等于把用户的 Key 两头都销毁")
    }

    func test明文迁移_读回不一致时明文保留() {
        let (defaults, domain) = makeDefaults(#function)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("sk-明文", forKey: "chatAPIKey")

        let fake = FakeKeychain()
        fake.corruptReadbackFor = ["chatAPIKey"]
        let report = migrator(fake).migratePlaintextKeys(["chatAPIKey"], in: defaults, domain: domain)

        XCTAssertEqual(report.failed["chatAPIKey"], .verifyMismatch)
        XCTAssertEqual(defaults.string(forKey: "chatAPIKey"), "sk-明文")
    }

    func test明文迁移_无明文时视为无需迁移() {
        let (defaults, domain) = makeDefaults(#function)
        defer { defaults.removePersistentDomain(forName: domain) }

        let fake = FakeKeychain()
        let report = migrator(fake).migratePlaintextKeys(
            ["chatAPIKey", "chatTavilyKey"], in: defaults, domain: domain)

        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(report.migrated.isEmpty)
    }
}
