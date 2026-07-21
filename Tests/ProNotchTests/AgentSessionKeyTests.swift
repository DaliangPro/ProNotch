import XCTest
@testable import ProNotch

/// 会话身份的单一口径：来源 + 规范化 ID。
///
/// 病灶：四家的会话 ID 格式各不相同（Claude 裸 uuid、Codex `rollout-<日期>-<uuid>`、
/// Kimi `session_<uuid>`、Grok 目录名），而 hook 事件报回来的多是裸 uuid。
/// 原实现只好用 `id == key || id.hasSuffix(key)` 模糊比对——它跨不了来源，
/// Claude 的 uuid 完全可能后缀命中 Codex 的文件名；同时 `sessionTokens` 以裸 ID 为键，
/// 两家撞上同一 UUID 就互相覆盖。
final class AgentSessionKeyTests: XCTestCase {

    private let uuid = "7aeb4841-a4a3-4b3e-8e74-f99e221c8d6d"

    // MARK: - 规范化

    func testKimi的session前缀与裸uuid收敛到同一个key() {
        // session_index.jsonl 的 sessionId 与目录名都是 `session_<uuid>`（2026-07 实测），
        // 而 hook 的 stdin payload 报的是裸 uuid
        let fromIndex = AgentSessionKey(source: .kimi, rawID: "session_\(uuid)")
        let fromHook = AgentSessionKey(source: .kimi, rawID: uuid)
        XCTAssertEqual(fromIndex, fromHook)
        XCTAssertEqual(fromIndex.id, uuid)
    }

    func testCodex的rollout文件名与裸threadID收敛到同一个key() {
        let fromFile = AgentSessionKey(source: .codex, rawID: "rollout-2026-07-20T14-03-11-\(uuid)")
        let fromHook = AgentSessionKey(source: .codex, rawID: uuid)
        XCTAssertEqual(fromFile, fromHook, "hook 只报裸 thread-id，必须能对上 rollout 文件")
    }

    func testCodex子代理聚合出的agg前缀也收敛() {
        // SessionUsage 在根文件本周没动时会合成 `agg-<根 uuid>`
        XCTAssertEqual(AgentSessionKey(source: .codex, rawID: "agg-\(uuid)"),
                       AgentSessionKey(source: .codex, rawID: uuid))
    }

    func test不是UUID结尾的ID原样保留() {
        let key = AgentSessionKey(source: .grok, rawID: "my-workspace-folder")
        XCTAssertEqual(key.id, "my-workspace-folder", "认不出 UUID 就别乱截，原样留着还能精确匹配")
    }

    func test大小写与空白不影响身份() {
        XCTAssertEqual(AgentSessionKey(source: .claude, rawID: "  \(uuid.uppercased())  "),
                       AgentSessionKey(source: .claude, rawID: uuid))
    }

    func test同一UUID不同来源是两个key() {
        XCTAssertNotEqual(AgentSessionKey(source: .claude, rawID: uuid),
                          AgentSessionKey(source: .kimi, rawID: "session_\(uuid)"),
                          "四家的 UUID 空间彼此独立，撞号是可能的，必须靠来源分开")
    }

    // MARK: - 每会话 token

    func testClaude与Kimi撞上同一UUID时token互不覆盖() {
        let table = ProductionUsageLoader.tokenTable([
            (.claude, [SessionUsage.Scanned(id: uuid, tokens: 1000, url: URL(fileURLWithPath: "/tmp/c"))]),
            (.kimi, [SessionUsage.Scanned(id: "session_\(uuid)", tokens: 2000, url: URL(fileURLWithPath: "/tmp/k"))]),
        ])
        XCTAssertEqual(table[AgentSessionKey(source: .claude, rawID: uuid)], 1000)
        XCTAssertEqual(table[AgentSessionKey(source: .kimi, rawID: uuid)], 2000)
        XCTAssertEqual(table.count, 2, "两家各占一格，谁也别想把谁盖掉")
    }

    func test同一家内同键重复取和() {
        // Codex 归并后同一根任务可能来自多个文件名形式
        let table = ProductionUsageLoader.tokenTable([
            (.codex, [
                SessionUsage.Scanned(id: "rollout-2026-07-20T01-00-00-\(uuid)", tokens: 300,
                                     url: URL(fileURLWithPath: "/tmp/a")),
                SessionUsage.Scanned(id: "agg-\(uuid)", tokens: 700,
                                     url: URL(fileURLWithPath: "/tmp/b")),
            ]),
        ])
        XCTAssertEqual(table[AgentSessionKey(source: .codex, rawID: uuid)], 1000)
    }

    func testAgent卡片能按自己的key取到token() {
        let card = AgentSession(id: "rollout-2026-07-20T14-03-11-\(uuid)", source: .codex,
                                projectPath: "/tmp/proj", model: nil, lastActivity: Date(),
                                lastMessage: nil, title: nil, state: .idle)
        let table = ProductionUsageLoader.tokenTable([
            (.codex, [SessionUsage.Scanned(id: uuid, tokens: 4242,
                                           url: URL(fileURLWithPath: "/tmp/x"))]),
        ])
        XCTAssertEqual(table[card.key], 4242,
                       "卡片来自文件扫描、token 来自额度扫描，两条路必须落在同一个键上")
    }

    // MARK: - 宿主映射持久化

    func test宿主映射编码解码往返() {
        let hosts: [AgentSessionKey: String] = [
            AgentSessionKey(source: .claude, rawID: uuid): "com.apple.Terminal",
            AgentSessionKey(source: .codex, rawID: uuid): "com.microsoft.VSCode",
        ]
        let restored = AgentSessionsStore.decodeHosts(AgentSessionsStore.encodeHosts(hosts))
        XCTAssertEqual(restored, hosts, "同 UUID 不同来源存成两条，回来还得是两条")
    }

    func test旧格式的裸ID宿主记录被丢弃() {
        let restored = AgentSessionsStore.decodeHosts([uuid: "com.apple.Terminal"])
        XCTAssertTrue(restored.isEmpty,
                      "旧记录不带来源，猜错会把跳转指到别家 App；丢掉即可，下次 hook 就补回来")
    }
}

/// hook 事件落到正确那张卡上（跨来源不串台）
@MainActor
final class AgentSessionHookRoutingTests: XCTestCase {

    private let uuid = "7aeb4841-a4a3-4b3e-8e74-f99e221c8d6d"
    private var savedSelection: [String]?

    override func setUp() {
        super.setUp()
        savedSelection = UserDefaults.standard.stringArray(forKey: AgentKind.selectionKey)
        UserDefaults.standard.set([AgentKind.claude.rawValue, AgentKind.codex.rawValue],
                                  forKey: AgentKind.selectionKey)
    }

    override func tearDown() {
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: AgentKind.selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AgentKind.selectionKey)
        }
        super.tearDown()
    }

    func testClaude的hook事件不得点亮同UUID的Codex卡片() async {
        let now = Date()
        let scanner = ScriptedSessionScanner([[
            AgentSession(id: uuid, source: .claude, projectPath: "/tmp/a", model: nil,
                         lastActivity: now, lastMessage: nil, title: nil, state: .idle),
            AgentSession(id: "rollout-2026-07-20T14-03-11-\(uuid)", source: .codex,
                         projectPath: "/tmp/b", model: nil, lastActivity: now,
                         lastMessage: nil, title: nil, state: .idle),
        ]])
        let store = AgentSessionsStore(scanner: scanner)
        store.refresh(force: true)
        await scanner.release()
        await waitUntil("首轮扫描落地") { store.sessions.count == 2 }

        // Claude 的 hook 报的就是裸 session_id，和 Codex 文件名的后缀恰好一致
        store.markTurnEnded(session: uuid, source: .claude, host: nil)

        let claude = store.sessions.first { $0.source == .claude }
        let codex = store.sessions.first { $0.source == .codex }
        XCTAssertEqual(claude?.state, .waiting, "该点亮的是 Claude 这张")
        XCTAssertEqual(codex?.state, .idle, "Codex 那张不该被后缀匹配误伤")
    }

    func testCodex的hook只报裸threadID也要点亮对应卡片() async {
        let now = Date()
        let scanner = ScriptedSessionScanner([[
            AgentSession(id: "rollout-2026-07-20T14-03-11-\(uuid)", source: .codex,
                         projectPath: "/tmp/b", model: nil, lastActivity: now,
                         lastMessage: nil, title: nil, state: .idle),
        ]])
        let store = AgentSessionsStore(scanner: scanner)
        store.refresh(force: true)
        await scanner.release()
        await waitUntil("首轮扫描落地") { store.sessions.count == 1 }

        store.markTurnEnded(session: uuid, source: .codex, host: nil)
        XCTAssertEqual(store.sessions.first?.state, .waiting,
                       "规范化之后裸 thread-id 与 rollout 文件名是同一个键")
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 3,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待超时：\(label)"); return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
