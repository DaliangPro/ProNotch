import XCTest
@testable import ProNotch

/// 翻译多套存档并入闪问接口池（2026-09-22 两边共用一个池子）
final class TranslateEndpointMergeTests: XCTestCase {
    private func provider(_ name: String, _ url: String, _ model: String) -> APIProvider {
        APIProvider(name: name, baseURL: url, model: model, keychainAccount: "chatAPIKey-\(name)")
    }

    func test不同的套追加进池子并沿用原钥匙串账号() {
        let pool = [provider("Deepseek", "https://api.deepseek.com", "deepseek-flash")]
        let ep = TranslateEndpoint(name: "百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                                   model: "qwen3.7-flash", keychainAccount: "translateAPIKey-x")
        let r = ChatStore.mergeTranslateEndpoints(into: pool, endpoints: [ep])
        XCTAssertEqual(r.providers.count, 2)
        XCTAssertEqual(r.providers[1].name, "百炼")
        XCTAssertEqual(r.providers[1].keychainAccount, "translateAPIKey-x", "Key 不搬，账号原样沿用")
        XCTAssertEqual(r.mapping[ep.id], r.providers[1].id)
    }

    func test地址与模型都相同的视为同一套_映射到已有的() {
        let existing = provider("Deepseek", "https://api.deepseek.com", "deepseek-flash")
        let ep = TranslateEndpoint(name: "DS", baseURL: " https://API.deepseek.com ", model: "deepseek-flash",
                                   keychainAccount: "translateAPIKey")
        let r = ChatStore.mergeTranslateEndpoints(into: [existing], endpoints: [ep])
        XCTAssertEqual(r.providers.count, 1)
        XCTAssertEqual(r.mapping[ep.id], existing.id)
    }

    func test空地址的壳不并() {
        let ep = TranslateEndpoint(name: "新配置", baseURL: "", model: "", keychainAccount: "translateAPIKey-y")
        let r = ChatStore.mergeTranslateEndpoints(into: [], endpoints: [ep])
        XCTAssertTrue(r.providers.isEmpty)
        XCTAssertNil(r.mapping[ep.id])
    }

    func test没名字的套按域名起名() {
        let ep = TranslateEndpoint(name: "", baseURL: "https://api.moonshot.cn/v1", model: "kimi",
                                   keychainAccount: "translateAPIKey-z")
        let r = ChatStore.mergeTranslateEndpoints(into: [], endpoints: [ep])
        XCTAssertEqual(r.providers.first?.name, "Moonshot")
    }
}
