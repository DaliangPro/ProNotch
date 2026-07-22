import XCTest
@testable import ProNotch

/// 刘海收起态槽位的「谁在干活」记账。
///
/// 这份状态全靠两个 hook 事件维持（UserPromptSubmit 置入、Stop 移出），
/// 中间没有任何轮询能来纠偏——记错了就一直错着，直到下一个回合。
/// 所以这里重点钉三件事：多会话不互相抹除、信号残缺时宁可早熄灭、卡死能自愈。
@MainActor
final class AgentActivityStoreTests: XCTestCase {

    func test开工后标记为工作中_收工后回到空闲() {
        let store = AgentActivityStore()
        XCTAssertTrue(store.working.isEmpty)

        store.markBusy(.claude, session: "s1")
        XCTAssertEqual(store.working, [.claude])

        store.markIdle(.claude, session: "s1")
        XCTAssertTrue(store.working.isEmpty)
    }

    /// 同一家常常同时开着好几个会话。只按来源记账的话，任一会话收工就会把整家判成空闲，
    /// 另外几个还在跑的就被抹掉了——用户看到的是「明明还在跑，灯却灭了」
    func test同家多会话_一个收工不影响其它() {
        let store = AgentActivityStore()
        store.markBusy(.claude, session: "s1")
        store.markBusy(.claude, session: "s2")

        store.markIdle(.claude, session: "s1")
        XCTAssertEqual(store.working, [.claude], "还有 s2 在跑，不能熄")

        store.markIdle(.claude, session: "s2")
        XCTAssertTrue(store.working.isEmpty)
    }

    func test不同家各记各的() {
        let store = AgentActivityStore()
        store.markBusy(.claude, session: "s1")
        store.markBusy(.codex, session: "t1")
        XCTAssertEqual(store.working, [.claude, .codex])

        store.markIdle(.codex, session: "t1")
        XCTAssertEqual(store.working, [.claude])
    }

    /// 脚本 sed 抓会话 id 会扑空（各家载荷字段拼写不一）。这时退化成「整家标闲」：
    /// 宁可早熄灭也不要让黄灯一直亮着——亮着不灭是用户唯一会来投诉的失效方式
    func test收工信号没带会话id时把整家标闲() {
        let store = AgentActivityStore()
        store.markBusy(.claude, session: "s1")
        store.markBusy(.claude, session: "s2")

        store.markIdle(.claude, session: "")
        XCTAssertTrue(store.working.isEmpty, "抓不到会话就该整家熄灭，不能留下永不熄的灯")
    }

    /// 开工信号也可能抓不到会话 id，此时空串就是这一回合的 key，
    /// 收工时的空串必须仍能把它清掉（走的是「整家标闲」那条路）
    func test开工也没会话id时仍能被清掉() {
        let store = AgentActivityStore()
        store.markBusy(.grok, session: "")
        XCTAssertEqual(store.working, [.grok])
        store.markIdle(.grok, session: "")
        XCTAssertTrue(store.working.isEmpty)
    }

    /// 崩溃、强杀、或收工那一刻 ProNotch 没开着，完成信号就丢了，
    /// 状态会永远卡在「工作中」。超时兜底必须能自己把它扫掉
    func test超时未收到收工信号则自行归为空闲() {
        let store = AgentActivityStore(staleAfter: 0.05)
        store.markBusy(.kimi, session: "s1")
        XCTAssertEqual(store.working, [.kimi])

        Thread.sleep(forTimeInterval: 0.1)
        // 任一次记账都会顺手清理过期项（定时器是 60 秒一轮，测试里不等它）
        store.markIdle(.claude, session: "no-such")
        XCTAssertTrue(store.working.isEmpty, "卡死的状态没被兜底扫掉，黄灯会一直亮着")
    }

    /// 重复的开工信号只应刷新时间戳，不该把同一回合记成两笔
    func test重复开工信号不重复记账() {
        let store = AgentActivityStore()
        store.markBusy(.codex, session: "t1")
        store.markBusy(.codex, session: "t1")
        store.markIdle(.codex, session: "t1")
        XCTAssertTrue(store.working.isEmpty, "记成两笔的话，一次收工清不干净")
    }

    /// 取消勾选某家时它的钩子就被卸了，收工信号再也不会来。
    /// 不主动清账的话，那一家会停在最后一次开工的状态上，直到超时兜底才熄
    func test取消勾选后清掉那一家的全部会话() {
        let store = AgentActivityStore()
        store.markBusy(.claude, session: "s1")
        store.markBusy(.claude, session: "s2")
        store.markBusy(.grok, session: "g1")

        store.applyAgentSelection([.grok, .codex, .kimi])
        XCTAssertEqual(store.working, [.grok], "只清取消掉的那家，别家不受牵连")
    }
}
