import XCTest
import AppKit
@testable import ProNotch

/// 只挂截图、一个字都不打，能不能发出去。
///
/// 由来（大梁老师 2026-08-08）：「截图问 AI」这条路存在的意义就是少几步——
/// 框选、点一下、图就挂上了。可挂上之后发送键还是灰的，非得先打两个字才亮，
/// 等于把刚省下的那一步又还回去。而挂上图之后多数时候想问的就是「这是什么」
@MainActor
final class ChatAttachmentOnlySendTests: XCTestCase {

    // MARK: - 按钮亮不亮

    func test只挂了截图没打字也能发() {
        XCTAssertTrue(ChatComposer.canSend(draft: "", hasAttachment: true))
        XCTAssertTrue(ChatComposer.canSend(draft: "   \n ", hasAttachment: true))
    }

    func test什么都没有还是不能发() {
        XCTAssertFalse(ChatComposer.canSend(draft: "", hasAttachment: false))
        XCTAssertFalse(ChatComposer.canSend(draft: " \n\t ", hasAttachment: false))
    }

    func test只打了字没挂图照常能发() {
        XCTAssertTrue(ChatComposer.canSend(draft: "在吗", hasAttachment: false))
    }

    // MARK: - 真发得出去

    /// UI 放行、Store 挡住＝按钮亮着却点不动。两处判据必须一致
    func test挂了图的空消息真的进了对话() throws {
        let store = try makeStore()
        store.newConversation()
        store.attachScreenshot(magentaShot())
        XCTAssertNotNil(store.draftAttachment)

        store.send("")
        // 一条用户消息 + 一条待填的 AI 回复
        XCTAssertEqual(store.messages.count, 2, "空文本 + 图被 send 挡下了，按钮就成了摆设")
        XCTAssertEqual(store.messages.first?.role, .user)
        XCTAssertNotNil(store.messages.first?.imageData, "图没跟着消息走，那这条发了等于没发")
        XCTAssertNil(store.draftAttachment, "发完草稿附件该清空，否则下一条会重复带上")
        store.stopStreaming()
    }

    func test什么都没有时send原地不动() throws {
        let store = try makeStore()
        store.newConversation()
        store.send("   ")
        XCTAssertTrue(store.messages.isEmpty)
    }

    /// 侧栏标题取首条用户消息，没打字就无话可取。给个中性标签，不替他编一句问话
    func test只发图时会话标题给中性标签() throws {
        let store = try makeStore()
        store.newConversation()
        store.attachScreenshot(magentaShot())
        store.send("")
        XCTAssertEqual(store.conversations.first?.title, "截图提问")
        store.stopStreaming()
    }

    func test打了字时标题仍取那句话() throws {
        let store = try makeStore()
        store.newConversation()
        store.attachScreenshot(magentaShot())
        store.send("这张图什么意思")
        XCTAssertEqual(store.conversations.first?.title, "这张图什么意思")
        store.stopStreaming()
    }

    // MARK: - 载荷

    /// 空字符串的 text part 有的服务端直接判 400，只发图时干脆不放这一段
    func test只发图的载荷里没有空文本段() throws {
        let store = try makeStore()
        store.newConversation()
        store.attachScreenshot(magentaShot())
        store.send("")
        let parts = try XCTUnwrap(ChatStore.payloadEntry(for: store.messages[0])["content"]
                                    as? [[String: Any]])
        XCTAssertEqual(parts.count, 1, "只该剩图片那一段")
        XCTAssertEqual(parts.first?["type"] as? String, "image_url")
        store.stopStreaming()
    }

    func test带文字发图时文本段还在() throws {
        let store = try makeStore()
        store.newConversation()
        store.attachScreenshot(magentaShot())
        store.send("这是什么")
        let parts = try XCTUnwrap(ChatStore.payloadEntry(for: store.messages[0])["content"]
                                    as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url"])
        store.stopStreaming()
    }

    /// 联网材料要注入的是**文本**那一段。只发图的消息本来没有这一段，
    /// 不补一个的话，搜回来的东西会静默丢掉
    func test给只有图的消息注入搜索材料会补出文本段() {
        let onlyImage: [[String: Any]] = [["type": "image_url",
                                           "image_url": ["url": "data:image/jpeg;base64,AA"]]]
        let replaced = ChatStore.replacingText(in: onlyImage, with: "材料")
        let parts = replaced as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?.first?["type"] as? String, "text")
        XCTAssertEqual(parts?.first?["text"] as? String, "材料")
        XCTAssertEqual(parts?.last?["type"] as? String, "image_url", "图不能被挤掉")
    }

    // MARK: - 夹具

    private func magentaShot() -> NSImage {
        let size = NSSize(width: 40, height: 30)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.magenta.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    private func makeStore() throws -> ChatStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "only.\(UUID().uuidString)")!
        defaults.set("https://api.example.com/v1", forKey: PrefKey.chatBaseURL)
        defaults.set("deepseek-v4-pro", forKey: PrefKey.chatModel)
        defaults.set("sk-test", forKey: "chatAPIKey")
        return ChatStore(env: ChatEnvironment(
            defaults: defaults, keychain: OnlyKeychain(), keychainService: "only.test",
            transport: URLSessionTransport(),
            conversationsURL: tmp.appendingPathComponent("c.json"), plaintextDomain: nil))
    }

    private final class OnlyKeychain: KeychainAccessing, @unchecked Sendable {
        func read(_ account: String, service: String) -> Result<String?, KeychainError> { .success("sk-test") }
        func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
        func delete(_ account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
    }
}
