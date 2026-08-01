import XCTest
@testable import ProNotch

/// 设置页点选模型必须立即生效（大梁老师 2026-08-01：「设置里改了模型，闪问界面不跟着变」）。
///
/// 病根是设置页的模型行只写 draftModel（草稿），要点「保存」才落地，
/// 但勾勾当场就挪过去了——看着像已生效。现在设置页与闪问窗右上角切换器
/// 同走 selectModel，这里锁住它的三件事：改 model、写盘、draft 同步
final class SettingsModelApplyTests: XCTestCase {

    private final class MemKeychain: KeychainAccessing, @unchecked Sendable {
        var values: [String: String] = [:]
        func read(_ a: String, service: String) -> Result<String?, KeychainError> { .success(values[a]) }
        func save(_ v: String, account: String, service: String) -> Result<Void, KeychainError> {
            values[account] = v; return .success(())
        }
        func delete(_ a: String, service: String) -> Result<Void, KeychainError> {
            values[a] = nil; return .success(())
        }
    }

    @MainActor
    private func makeStore(defaults: UserDefaults) throws -> ChatStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = APIProvider(name: "T", baseURL: "https://e.com/v1",
                            model: "old-model", keychainAccount: "acc")
        defaults.set(try JSONEncoder().encode([p]), forKey: "chatProviders")
        defaults.set(p.id.uuidString, forKey: "chatCurrentProviderID")
        defaults.set("old-model", forKey: PrefKey.chatModel)
        let kc = MemKeychain(); kc.values["acc"] = "sk-x"
        return ChatStore(env: ChatEnvironment(defaults: defaults, keychain: kc,
            keychainService: "t", transport: URLSessionTransport(),
            conversationsURL: tmp.appendingPathComponent("c.json"), plaintextDomain: nil))
    }

    @MainActor
    func test点选模型立即生效并持久化() throws {
        let defaults = UserDefaults(suiteName: "model.\(UUID().uuidString)")!
        let store = try makeStore(defaults: defaults)
        XCTAssertEqual(store.model, "old-model")

        store.selectModel("new-model")

        XCTAssertEqual(store.model, "new-model", "闪问界面读的就是 model，点选必须当场变")
        XCTAssertEqual(store.draftModel, "new-model", "设置表单草稿同步，勾勾与实际一致")
        XCTAssertEqual(defaults.string(forKey: PrefKey.chatModel), "new-model", "已写盘，重启仍是新模型")
    }

    /// 存档同步：点选后当前套 provider 的 model 也要跟上，
    /// 否则切走再切回这套配置就变回旧模型
    @MainActor
    func test点选写回当前套存档() throws {
        let defaults = UserDefaults(suiteName: "model.\(UUID().uuidString)")!
        let store = try makeStore(defaults: defaults)
        store.selectModel("new-model")
        let data = defaults.data(forKey: "chatProviders")!
        let archived = try JSONDecoder().decode([APIProvider].self, from: data)
        XCTAssertEqual(archived.first?.model, "new-model")
    }
}
