import XCTest
@testable import ProNotch

/// 话术数据模型的向后兼容与往返测试。
/// 只测纯值类型 Snippet 的 Codable —— 不实例化 SnippetStore（其 init 会读、add 会写用户真实
/// snippets.json，测试中触碰会污染用户数据）。
final class SnippetStoreTests: XCTestCase {

    /// 关键回归：旧版 snippets.json 没有 title 字段，加字段后必须仍能解码成功且 title=nil，
    /// 否则老用户升级即丢全部话术。
    func test旧数据无title字段向后兼容() throws {
        let json = #"""
        [{"id":"11111111-1111-1111-1111-111111111111","content":"感谢您的咨询","date":700000000}]
        """#
        let arr = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))
        XCTAssertEqual(arr.count, 1)
        XCTAssertNil(arr.first?.title, "旧数据缺 title 字段应解码为 nil，而非解码失败")
        XCTAssertEqual(arr.first?.content, "感谢您的咨询")
    }

    /// 带标题的新数据编解码往返一致。
    func test带标题话术编解码往返() throws {
        let original = Snippet(id: UUID(), title: "报价话术",
                               content: "客单价 3980，含一年陪跑",
                               date: Date(timeIntervalSinceReferenceDate: 700_000_000))
        let data = try JSONEncoder().encode([original])
        let back = try JSONDecoder().decode([Snippet].self, from: data)
        XCTAssertEqual(back.first?.title, "报价话术")
        XCTAssertEqual(back.first?.content, "客单价 3980，含一年陪跑")
        XCTAssertEqual(back.first?.id, original.id)
    }

    /// title 显式为 nil 时编码后仍能原样解回 nil（不因编码丢失可选语义）。
    func test无标题话术往返保持nil() throws {
        let original = Snippet(id: UUID(), title: nil, content: "你好",
                               date: Date(timeIntervalSinceReferenceDate: 700_000_000))
        let data = try JSONEncoder().encode([original])
        let back = try JSONDecoder().decode([Snippet].self, from: data)
        XCTAssertNil(back.first?.title)
        XCTAssertEqual(back.first?.content, "你好")
    }
}
