import XCTest
@testable import ProNotch

/// 两个 Store 的刷新代际与迟到结果隔离。
///
/// 病灶：额度刷新与会话扫描都是「主线程发起 → 后台扫几百 MB 文件 → 回主线程写 UI」。
/// 后台那段要几百毫秒到几秒，期间用户完全来得及在设置里取消勾选某家。
/// 原实现回来时无条件写入，于是刚取消的家又被填回界面；
/// 而 `guard !refreshing else { return }` 又让「勾选变更后立即重拉」这条强制刷新
/// 在撞上在途刷新时**静默消失**——两个问题叠加，界面就停在错误状态上。
@MainActor
final class StoreRefreshGenerationTests: XCTestCase {

    private var savedSelection: [String]?

    override func setUp() {
        super.setUp()
        savedSelection = UserDefaults.standard.stringArray(forKey: AgentKind.selectionKey)
    }

    override func tearDown() {
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: AgentKind.selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AgentKind.selectionKey)
        }
        super.tearDown()
    }

    private func setEnabled(_ kinds: Set<AgentKind>) {
        UserDefaults.standard.set(kinds.map(\.rawValue), forKey: AgentKind.selectionKey)
    }

    /// 轮询等待条件成立（不用 expectation：这些状态变化没有通知可挂）
    private func waitUntil(_ label: String, timeout: TimeInterval = 3,
                           _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { XCTFail("等待超时：\(label)"); return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - UsageStore

    func test取消勾选后_旧刷新结果不得把该家填回来() async {
        setEnabled([.claude, .codex])
        let loader = ScriptedUsageLoader([
            UsageSnapshot(codex: quota("codex 的旧结果"), claude: quota("claude")),
            UsageSnapshot(claude: quota("claude 的新结果")),
        ])
        let store = UsageStore(loader: loader)

        store.refresh(force: true)
        await waitUntil("loader 收到第一次调用") { await loader.callCount >= 1 }

        // 刷新在途时取消勾选 Codex
        setEnabled([.claude])
        store.applyAgentSelection()

        await loader.release()   // 放行第一轮（按旧勾选集拉的）
        await loader.release()   // 放行第二轮
        await waitUntil("两轮都收尾") { !store.refreshing }

        XCTAssertNil(store.codex, "已取消勾选的 Codex 不得被旧结果填回来")
        XCTAssertEqual(store.claude?.plan, "claude 的新结果")
    }

    func test刷新中再次强制刷新_最终发布第二次结果() async {
        setEnabled([.claude])
        let loader = ScriptedUsageLoader([
            UsageSnapshot(claude: quota("第一次")),
            UsageSnapshot(claude: quota("第二次")),
        ])
        let store = UsageStore(loader: loader)

        store.refresh(force: true)
        await waitUntil("第一轮在途") { store.refreshing }
        store.refresh(force: true)   // 撞上在途刷新——旧实现在这里直接 return，第二轮永远不会发生

        await loader.release()
        await waitUntil("第二轮启动") { await loader.callCount >= 2 }
        await loader.release()
        await waitUntil("全部收尾") { !store.refreshing }

        let calls = await loader.callCount
        XCTAssertEqual(calls, 2, "强制刷新不能被静默吞掉")
        XCTAssertEqual(store.claude?.plan, "第二次", "最终应发布第二轮的结果")
    }

    func test快速切换勾选集_只发布最后一代的结果() async {
        setEnabled([.claude, .codex, .grok, .kimi])
        let loader = ScriptedUsageLoader([
            UsageSnapshot(claude: quota("第 1 代")),
            UsageSnapshot(claude: quota("第 2 代")),
            UsageSnapshot(claude: quota("第 3 代")),
        ])
        let store = UsageStore(loader: loader)

        store.refresh(force: true)
        setEnabled([.claude, .codex])
        store.applyAgentSelection()
        setEnabled([.claude])
        store.applyAgentSelection()

        // 三轮乱序放行：先放最后一轮，再放前两轮的迟到结果
        await loader.release()
        await loader.release()
        await loader.release()
        await waitUntil("全部收尾") { !store.refreshing }

        XCTAssertEqual(store.claude?.plan, "第 3 代", "只有最后一代的结果可以落地")
        XCTAssertNil(store.codex)
        XCTAssertNil(store.grok)
        XCTAssertNil(store.kimi)
    }

    func test取消刷新后_refreshing必须复位() async {
        setEnabled([.claude])
        let loader = ScriptedUsageLoader([UsageSnapshot(claude: quota("x"))])
        let store = UsageStore(loader: loader)

        store.refresh(force: true)
        await waitUntil("刷新在途") { store.refreshing }
        store.cancelRefresh()
        XCTAssertFalse(store.refreshing, "取消后不能卡在「刷新中」——被取消的任务不会再走收尾分支")

        // 迟到结果回来也不能把状态搅乱
        await loader.release()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(store.refreshing)
        XCTAssertNil(store.claude, "已取消那轮的结果不得落地")
    }

    // MARK: - AgentSessionsStore

    func test会话扫描_取消勾选后旧结果不得列回来() async {
        setEnabled([.claude, .codex])
        let scanner = ScriptedSessionScanner([
            [session("a", .claude), session("b", .codex)],
            [session("a", .claude)],
        ])
        let store = AgentSessionsStore(scanner: scanner)

        store.refresh(force: true)
        await waitUntil("扫描在途") { store.refreshing }

        setEnabled([.claude])
        store.applyAgentSelection()

        await scanner.release()
        await scanner.release()
        await waitUntil("全部收尾") { !store.refreshing }

        XCTAssertTrue(store.sessions.allSatisfy { $0.source == .claude },
                      "已取消勾选的 Codex 会话不得留在监控台：\(store.sessions.map(\.id))")
    }

    func test会话扫描_扫描中再次强制刷新不被吞掉() async {
        setEnabled([.claude])
        let scanner = ScriptedSessionScanner([
            [session("旧", .claude)],
            [session("新", .claude)],
        ])
        let store = AgentSessionsStore(scanner: scanner)

        store.refresh(force: true)
        await waitUntil("扫描在途") { store.refreshing }
        store.refresh(force: true)   // hook 事件走的正是这条路

        await scanner.release()
        await waitUntil("第二轮启动") { await scanner.callCount >= 2 }
        await scanner.release()
        await waitUntil("全部收尾") { !store.refreshing }

        let calls = await scanner.callCount
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.sessions.first?.id, "新")
    }

    func test会话扫描_取消后refreshing复位() async {
        setEnabled([.claude])
        let scanner = ScriptedSessionScanner([[session("a", .claude)]])
        let store = AgentSessionsStore(scanner: scanner)

        store.refresh(force: true)
        await waitUntil("扫描在途") { store.refreshing }
        store.cancelRefresh()
        XCTAssertFalse(store.refreshing)

        await scanner.release()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(store.refreshing)
        XCTAssertTrue(store.sessions.isEmpty, "已取消那轮的结果不得落地")
    }

    // MARK: - 夹具

    private func quota(_ plan: String) -> ServiceQuota {
        var q = ServiceQuota()
        q.plan = plan
        return q
    }

    private func session(_ id: String, _ source: AgentKind) -> AgentSession {
        AgentSession(id: id, source: source, projectPath: "/tmp/\(id)", model: nil,
                     lastActivity: Date(), lastMessage: nil, title: nil, state: .idle)
    }
}

/// 可控延迟的额度 loader：每次 `load` 都挂起，直到测试显式 `release()`。
/// 有了它才能构造「旧结果比新结果晚回来」这种真实但难复现的时序
actor ScriptedUsageLoader: UsageLoading {
    private var queue: [UsageSnapshot]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var credits = 0
    private(set) var seenEnabled: [Set<AgentKind>] = []

    init(_ queue: [UsageSnapshot]) { self.queue = queue }

    var callCount: Int { seenEnabled.count }

    func load(enabled: Set<AgentKind>) async -> UsageSnapshot {
        seenEnabled.append(enabled)
        let snapshot = queue.isEmpty ? UsageSnapshot() : queue.removeFirst()
        await hold()
        return snapshot
    }

    /// 放行一次。若 load 还没进来就先记账，避免测试要精确掐时序
    func release() {
        if waiters.isEmpty { credits += 1; return }
        waiters.removeFirst().resume()
    }

    private func hold() async {
        if credits > 0 { credits -= 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }
}

/// 可控延迟的会话扫描器，用法同上
actor ScriptedSessionScanner: AgentSessionScanning {
    private var queue: [[AgentSession]]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var credits = 0
    private(set) var seenEnabled: [Set<AgentKind>] = []

    init(_ queue: [[AgentSession]]) { self.queue = queue }

    var callCount: Int { seenEnabled.count }

    func scan(enabled: Set<AgentKind>) async -> [AgentSession] {
        seenEnabled.append(enabled)
        let result = queue.isEmpty ? [] : queue.removeFirst()
        await hold()
        return result
    }

    func release() {
        if waiters.isEmpty { credits += 1; return }
        waiters.removeFirst().resume()
    }

    private func hold() async {
        if credits > 0 { credits -= 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }
}
