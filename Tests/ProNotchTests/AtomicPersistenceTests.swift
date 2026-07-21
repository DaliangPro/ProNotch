import XCTest
@testable import ProNotch

/// 本地持久化的三条底线：写入不倒序、写入不半截、损坏不覆盖。
///
/// 病灶：聊天历史、剪贴板索引、话术库三份 JSON 原先都是
/// 「主线程改内存 → `Task.detached` 甩出去 → `try? data.write(to:)`」。
/// detached task 之间没有顺序保证，旧快照后落地就把新状态盖掉；
/// 非原子写在中途被杀会留下半截 JSON；而下次启动解码失败被 `try?` 一吞，
/// 接着第一次保存又把这份损坏文件覆盖——数据就是这么无声无息没的。
@MainActor
final class AtomicPersistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProNotchAtomic-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func url(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    private func text(at url: URL) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    }

    // MARK: - 单调 revision

    func test旧revision后到_不得覆盖新内容() async throws {
        let file = url("list.json")
        let store = AtomicFileStore()

        let newer = try await store.write(["新"], to: file, revision: 2)
        XCTAssertEqual(newer, .written(revision: 2))

        // 更早发起、更晚落地的那次保存
        let older = try await store.write(["旧"], to: file, revision: 1)
        XCTAssertEqual(older, .stale(revision: 1, latest: 2),
                       "revision 1 比已落盘的 2 旧，必须被丢弃")
        XCTAssertEqual(try text(at: file), ["新"], "文件内容仍是 revision 2 写的那份")
    }

    func test相同revision也拒收() async throws {
        let file = url("list.json")
        let store = AtomicFileStore()
        _ = try await store.write(["甲"], to: file, revision: 7)
        let again = try await store.write(["乙"], to: file, revision: 7)
        XCTAssertEqual(again, .stale(revision: 7, latest: 7))
        XCTAssertEqual(try text(at: file), ["甲"])
    }

    func test代际按文件各记各的() async throws {
        let a = url("a.json"), b = url("b.json")
        let store = AtomicFileStore()
        _ = try await store.write(["a5"], to: a, revision: 5)
        // b 是另一个文件，revision 3 对它来说不算旧
        let wrote = try await store.write(["b3"], to: b, revision: 3)
        XCTAssertEqual(wrote, .written(revision: 3))
        XCTAssertEqual(try text(at: b), ["b3"])
    }

    func test连续快速写入_最终是最高revision那份() async throws {
        let file = url("list.json")
        let store = AtomicFileStore()
        // 乱序发起 1…8，模拟调度打乱后的落地顺序
        for revision in [3, 1, 8, 2, 7, 5, 4, 6] as [UInt64] {
            _ = try await store.write(["第 \(revision) 版"], to: file, revision: revision)
        }
        XCTAssertEqual(try text(at: file), ["第 8 版"])
        let latest = await store.writtenRevision(for: file)
        XCTAssertEqual(latest, 8)
    }

    // MARK: - 写入中断与备份

    func test写入中断留下半截文件_旧内容仍能从备份取回() async throws {
        let file = url("list.json")
        let store = AtomicFileStore()
        _ = try await store.write(["第一版"], to: file, revision: 1)
        _ = try await store.write(["第二版"], to: file, revision: 2)   // 这一步把第一版抄进 .bak

        // 模拟第三次写入被杀在半路：备份那一步已经做完（writeAtomically 的第一步），
        // 主文件只落下半截 JSON
        try Data(contentsOf: file).write(to: AtomicFileStore.backupURL(for: file), options: .atomic)
        try Data("[\"第三".utf8).write(to: file)

        let loaded = AtomicFileStore.load([String].self, from: file)
        XCTAssertEqual(loaded.value, ["第二版"], "备份里那份完整数据必须能救回来")
        XCTAssertNotNil(loaded.error, "恢复过就得留下可展示的说明，不能悄无声息")
        XCTAssertEqual(try text(at: file), ["第二版"], "备份应被扶正，下次启动走正常路径")
    }

    func test备份文件在每次写入前刷新() async throws {
        let file = url("list.json")
        let store = AtomicFileStore()
        _ = try await store.write(["v1"], to: file, revision: 1)
        _ = try await store.write(["v2"], to: file, revision: 2)
        _ = try await store.write(["v3"], to: file, revision: 3)
        XCTAssertEqual(try text(at: AtomicFileStore.backupURL(for: file)), ["v2"],
                       "备份应是被覆盖掉的那一版")
    }

    // MARK: - 损坏文件保全

    func test损坏且无备份_原件改名保全并从空数据开始() throws {
        let file = url("list.json")
        let broken = Data("{ 这不是合法 JSON".utf8)
        try broken.write(to: file)

        let loaded = AtomicFileStore.load([String].self, from: file)
        XCTAssertNil(loaded.value, "无备份可恢复，调用方应从空数据开始")
        XCTAssertNotNil(loaded.error)

        let kept = try XCTUnwrap(loaded.quarantined, "损坏原件必须被保留下来")
        XCTAssertTrue(kept.lastPathComponent.contains(".corrupt-"),
                      "保全文件名应带 corrupt 时间戳：\(kept.lastPathComponent)")
        XCTAssertEqual(try Data(contentsOf: kept), broken, "保全的必须是原始字节，一个都不能改")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "原路径应已腾空，等新数据写入")
    }

    func test同一秒内两次损坏_保全文件不互相覆盖() throws {
        let file = url("list.json")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try Data("坏一".utf8).write(to: file)
        let first = try XCTUnwrap(AtomicFileStore.quarantine(file, now: now))
        try Data("坏二".utf8).write(to: file)
        let second = try XCTUnwrap(AtomicFileStore.quarantine(file, now: now))

        XCTAssertNotEqual(first, second, "同一秒的第二份保全不能盖掉第一份")
        XCTAssertEqual(try Data(contentsOf: first), Data("坏一".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("坏二".utf8))
    }

    func test文件不存在不算异常() {
        let loaded = AtomicFileStore.load([String].self, from: url("从未写过.json"))
        XCTAssertNil(loaded.value)
        XCTAssertNil(loaded.error, "首次运行没有文件是正常的，不该报错吓唬用户")
        XCTAssertNil(loaded.quarantined)
    }

    // MARK: - ChatStore

    func test会话历史连续快速保存_最终内容正确() async throws {
        let file = url("chat.json")
        let store = makeChatStore(at: file)

        for i in 1...5 {
            store.messages.append(ChatMessage(role: .user, content: "第 \(i) 条"))
            store.newConversation()   // 每次都触发一次落盘
        }
        await store.waitForPersist()

        let saved = try JSONDecoder().decode(
            [ChatConversation].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.count, 6, "5 段有内容的会话 + 1 段新建空会话")
        XCTAssertEqual(saved.compactMap { $0.messages.first?.content },
                       ["第 1 条", "第 2 条", "第 3 条", "第 4 条", "第 5 条"],
                       "快速连续保存不能丢中间任何一段")
    }

    func test会话历史损坏_保全原件并从空会话开始() throws {
        let file = url("chat.json")
        try Data("[{\"id\":".utf8).write(to: file)

        let store = makeChatStore(at: file)
        XCTAssertNotNil(store.storageError, "历史读不出来必须让用户看见原因，不能静默吞掉")
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertTrue(store.conversations[0].messages.isEmpty, "从一段空会话开始")

        let kept = try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertEqual(kept.count, 1, "损坏的历史必须原样留在磁盘上供事后抢救：\(kept)")
    }

    func test重建Store后仍能落盘_不被上一个实例的代际挡住() async throws {
        let file = url("chat.json")
        let first = makeChatStore(at: file)
        first.messages.append(ChatMessage(role: .user, content: "旧实例"))
        first.newConversation()
        await first.waitForPersist()

        // 重新构造一个 Store（App 重启、测试重建都会走到）：
        // 保存代际若各记各的，这里会带着 revision 1 撞上文件里已有的更高代际而被丢弃
        let second = makeChatStore(at: file)
        second.messages.append(ChatMessage(role: .user, content: "新实例"))
        second.newConversation()
        await second.waitForPersist()

        let saved = try JSONDecoder().decode(
            [ChatConversation].self, from: Data(contentsOf: file))
        XCTAssertTrue(saved.contains { $0.messages.first?.content == "新实例" },
                      "新实例的保存必须落地：\(saved.map { $0.messages.first?.content ?? "空" })")
    }

    // MARK: - SnippetStore

    func test话术库连续重排_最终顺序正确() async throws {
        let file = url("snippets.json")
        let store = SnippetStore(fileURL: file)
        store.add(title: nil, content: "丙")
        store.add(title: nil, content: "乙")
        store.add(title: nil, content: "甲")   // 新增置顶，此时是 甲乙丙

        store.move(from: 0, to: 2)   // 乙丙甲
        store.move(from: 0, to: 1)   // 丙乙甲
        await store.waitForSave()

        let saved = try JSONDecoder().decode([Snippet].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.map(\.content), ["丙", "乙", "甲"])
        XCTAssertEqual(store.snippets.map(\.content), saved.map(\.content),
                       "内存与磁盘必须一致")
    }

    func test话术库损坏_保全原件并从空库开始() throws {
        let file = url("snippets.json")
        try Data("不是 JSON".utf8).write(to: file)

        let store = SnippetStore(fileURL: file)
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertNotNil(store.storageError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "损坏原件已改名保全，不该还占着原路径等着被覆盖")
    }

    // MARK: - ClipboardStore

    func test索引落盘成功之后才删图片文件() async throws {
        let dir = url("Clipboard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let picture = dir.appendingPathComponent("pic.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        let item = ClipboardItem(id: UUID(), kind: .image, text: nil,
                                 imageFileName: "pic.png", imageHash: "hash", date: Date())
        try JSONEncoder().encode([item]).write(to: dir.appendingPathComponent("index.json"))

        let store = ClipboardStore(directory: dir)
        store.loadHistoryOnly()
        XCTAssertEqual(store.items.count, 1)

        store.clear()
        // 这里还没让出主线程，落盘任务不可能已经收尾
        XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path),
                      "索引还没写成功就先删图：写盘一旦失败，索引里指着的图就永远打不开了")

        await store.waitForIndexWrite()
        XCTAssertFalse(FileManager.default.fileExists(atPath: picture.path),
                       "索引落盘成功后才轮到清理文件")
    }

    func test剪贴板索引损坏_保全原件并从空历史开始() throws {
        let dir = url("Clipboard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[{\"id\"".utf8).write(to: dir.appendingPathComponent("index.json"))

        let store = ClipboardStore(directory: dir)
        store.loadHistoryOnly()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.storageError)

        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertEqual(kept.count, 1, "损坏索引必须留档：\(kept)")
    }

    // MARK: - 夹具

    /// 只为构造 ChatStore 的空壳钥匙串：本组测试一个 Key 都不读
    private final class NullKeychain: KeychainAccessing, @unchecked Sendable {
        func read(_ account: String, service: String) -> Result<String?, KeychainError> { .success(nil) }
        func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
        func delete(_ account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
    }

    private final class NullTransport: HTTPTransporting, @unchecked Sendable {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            throw URLError(.notConnectedToInternet)
        }
        func stream(for request: URLRequest) async throws
            -> (AsyncThrowingStream<String, Error>, URLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }

    private func makeChatStore(at url: URL) -> ChatStore {
        let defaults = UserDefaults(suiteName: "atomic.persistence.\(UUID().uuidString)")!
        return ChatStore(env: ChatEnvironment(
            defaults: defaults,
            keychain: NullKeychain(),
            keychainService: "test.service",
            transport: NullTransport(),
            conversationsURL: url,
            plaintextDomain: nil))
    }
}
