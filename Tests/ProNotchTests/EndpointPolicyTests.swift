import XCTest
@testable import ProNotch

/// 用户自填 API 端点的安全策略。
///
/// 这条规则守的是"Bearer Key 和整段对话不能明文过公网"。四个入口
/// （对话、模型列表、截图翻译、设置页测试）必须共用同一份判定，
/// 少一处就等于开了一扇后门。
final class EndpointPolicyTests: XCTestCase {

    private func assertAllowed(_ raw: String, file: StaticString = #filePath, line: UInt = #line) {
        let url = URL(string: raw)!
        XCTAssertNoThrow(try EndpointPolicy.validateUserAPIEndpoint(url), raw, file: file, line: line)
    }

    private func assertRejected(_ raw: String, file: StaticString = #filePath, line: UInt = #line) {
        let url = URL(string: raw)!
        XCTAssertThrowsError(try EndpointPolicy.validateUserAPIEndpoint(url), raw,
                             file: file, line: line)
    }

    func test放行_HTTPS公网() {
        assertAllowed("https://api.deepseek.com/v1/chat/completions")
        assertAllowed("https://api.openai.com/v1/models")
    }

    func test放行_本机HTTP() {
        assertAllowed("http://localhost:11434/v1/chat/completions")   // Ollama 默认
        assertAllowed("http://127.0.0.1:8000/v1")
        assertAllowed("http://[::1]:1234/v1")
        assertAllowed("http://LocalHost:11434/v1")                    // 大小写
        assertAllowed("http://127.0.0.2:8080/v1")                     // 127.0.0.0/8 整段
    }

    func test拒绝_公网明文HTTP() {
        assertRejected("http://example.com/v1/chat/completions")
        assertRejected("http://api.deepseek.com/v1")
    }

    func test拒绝_局域网明文HTTP() {
        assertRejected("http://192.168.1.2:8000/v1")
        assertRejected("http://10.0.0.5/v1")
        // 同网段的人能抓到 Key，和公网一样不可接受
    }

    func test拒绝_非法scheme与缺host() {
        assertRejected("ftp://example.com/v1")
        assertRejected("file:///etc/passwd")
        assertRejected("https:///v1/chat/completions")
    }

    func test拒绝_URL带用户信息() {
        assertRejected("https://user:pass@api.example.com/v1")
    }

    // MARK: - 两个端点生成入口都必须过同一策略

    func test闪问端点生成_公网明文被拒绝() {
        let config = ChatRequestConfig(providerID: UUID(), baseURL: "http://example.com/v1",
                                       apiKey: "k", model: "m",
                                       searchEngine: .duckduckgo, searchKey: "")
        XCTAssertThrowsError(try config.chatCompletionsURL())
        XCTAssertThrowsError(try ChatRequestConfig.modelsURL(baseURL: "http://example.com"))
        XCTAssertNoThrow(try ChatRequestConfig.modelsURL(baseURL: "http://localhost:11434"))
    }

    func test截图翻译端点生成_与闪问同一套判定() {
        XCTAssertThrowsError(try ScreenshotTranslator.completionsURL("http://example.com/v1"))
        XCTAssertNoThrow(try ScreenshotTranslator.completionsURL("https://api.deepseek.com/v1"))
        XCTAssertEqual(try ScreenshotTranslator.completionsURL("http://127.0.0.1:11434/v1/").absoluteString,
                       "http://127.0.0.1:11434/v1/chat/completions")
    }
}
