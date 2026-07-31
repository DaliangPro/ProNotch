import XCTest
@testable import ProNotch

/// 消息元信息与数据层兼容性（任务书 §8.2 / §18）
final class ChatMessageMetaTests: XCTestCase {

    private func snapshot(network: Bool = true, reasoning: Bool = false) -> ChatModeSnapshot {
        ChatModeSnapshot(modelID: "deepseek-v4-pro", modelDisplayName: "DeepSeek V4 Pro",
                         networkEnabled: network, reasoningEnabled: reasoning,
                         submittedAt: Date(timeIntervalSince1970: 0))
    }

    func test元信息按快照拼段() {
        let m = ChatMessage(role: .assistant, content: "答", searchResultCount: 8,
                            snapshot: snapshot(network: true, reasoning: true))
        XCTAssertEqual(m.metaParts,
                       ["DeepSeek V4 Pro", "联网", "深度思考", "8 个来源"])
    }

    /// 老消息没有快照：整段不显示，**不许拿当前全局设置反推**（§8.2.4）
    func test没有快照就不显示模型与模式() {
        let m = ChatMessage(role: .assistant, content: "答")
        XCTAssertTrue(m.metaParts.isEmpty)
    }

    func test没开的模式不占位() {
        let m = ChatMessage(role: .assistant, content: "答",
                            snapshot: snapshot(network: false, reasoning: false))
        XCTAssertEqual(m.metaParts, ["DeepSeek V4 Pro"])
    }

    /// 搜索失败最终没来源时不显示条数（§9.2）
    func test零条来源不显示() {
        let m = ChatMessage(role: .assistant, content: "答", searchResultCount: 0,
                            snapshot: snapshot(network: true))
        XCTAssertEqual(m.metaParts, ["DeepSeek V4 Pro", "联网"])
    }

    func test被停止的标出来() {
        var m = ChatMessage(role: .assistant, content: "答一半", snapshot: snapshot())
        m.stopped = true
        XCTAssertTrue(m.metaParts.contains("已停止"))
    }

    /// 老档案里没有这些字段，解出来必须是 nil 而不是报错（§18 兼容规则）
    func test老档案能解出来() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","role":"assistant","content":"旧的"}"#
        let m = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertEqual(m.content, "旧的")
        XCTAssertNil(m.snapshot)
        XCTAssertNil(m.sources)
        XCTAssertFalse(m.stopped)
    }

    func test快照与来源能往返() throws {
        var m = ChatMessage(role: .assistant, content: "答", searchResultCount: 1,
                            snapshot: snapshot())
        m.sources = [ChatSource(title: "标题", url: "https://example.com/a", domain: "example.com")]
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(back.snapshot?.modelDisplayName, "DeepSeek V4 Pro")
        XCTAssertEqual(back.sources?.first?.domain, "example.com")
    }

    func test域名提取去掉www() {
        XCTAssertEqual(ChatStore.domain(of: "https://www.example.com/a/b"), "example.com")
        XCTAssertEqual(ChatStore.domain(of: "https://news.ycombinator.com/x"), "news.ycombinator.com")
        XCTAssertEqual(ChatStore.domain(of: "不是网址"), "")
    }
}
