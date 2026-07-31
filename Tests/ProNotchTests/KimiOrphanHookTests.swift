import XCTest
@testable import ProNotch

/// 托管块之外的 ProNotch 孤儿 hook 清理。
///
/// 由来（大梁老师 2026-07-31 报「Kimi 跑完没光晕」，排查时在他机器上翻出来的）：
/// 早期版本还没有 BEGIN/END 边界标记，写进去的 hook 散落在数组里；后来的摘除逻辑
/// 只认标记内的，够不着它们——于是每装一次就再追加一份，`agent-busy.sh` 已经堆到 4 份，
/// 每次提问白跑 4 次。这组用例锁住「重装能自愈，且别人的 hook 一行不碰」
final class KimiOrphanHookTests: XCTestCase {

    private let dir = "/Users/x/Library/Application Support/ProNotch"

    /// 他机器上的真实形态：别家 hook + 三份孤儿 busy + 一份孤儿 wait + 一段完整托管块
    private var realWorldToml: String {
        """
        [model]
        name = "kimi"

        [[hooks]]
        event = "SessionStart"
        command = "/Users/x/.vibe-island/bin/vibe-island-bridge --source kimicode"
        timeout = 30

        [[hooks]]
        event = "UserPromptSubmit"
        command = "\\"\(dir)/agent-busy.sh\\" kimi"
        timeout = 5

        [[hooks]]
        event = "UserPromptSubmit"
        command = "\\"\(dir)/agent-busy.sh\\" kimi"
        timeout = 5

        [[hooks]]
        event = "Notification"
        command = "\\"\(dir)/agent-wait.sh\\" kimi"
        timeout = 5

        \(KimiHookBlock.beginMarker)
        [[hooks]]
        event = "Stop"
        command = '"\(dir)/kimi-notify.sh"'
        timeout = 15
        \(KimiHookBlock.endMarker)
        """
    }

    func test孤儿被摘掉() {
        let cleaned = KimiHookBlock.removeOrphans(from: realWorldToml, scriptDir: dir)
        XCTAssertFalse(cleaned.contains("agent-busy.sh"), "托管块外的 busy 孤儿必须清掉")
        XCTAssertFalse(cleaned.contains("agent-wait.sh"), "托管块外的 wait 孤儿必须清掉")
    }

    func test托管块内的不动() {
        let cleaned = KimiHookBlock.removeOrphans(from: realWorldToml, scriptDir: dir)
        XCTAssertTrue(cleaned.contains(KimiHookBlock.beginMarker))
        XCTAssertTrue(cleaned.contains(KimiHookBlock.endMarker))
        XCTAssertTrue(cleaned.contains("kimi-notify.sh"), "托管块内的完成钩子归 remove 管，这里不许碰")
    }

    func test别人的hook一行不碰() {
        let cleaned = KimiHookBlock.removeOrphans(from: realWorldToml, scriptDir: dir)
        XCTAssertTrue(cleaned.contains("vibe-island-bridge"), "第三方 hook 必须原样保留")
        XCTAssertTrue(cleaned.contains("event = \"SessionStart\""))
        XCTAssertTrue(cleaned.contains("[model]"), "非 hooks 的配置段也不能动")
    }

    func test没有孤儿时原样返回() {
        let clean = """
            [[hooks]]
            event = "Stop"
            command = "/other/tool"
            timeout = 30
            """
        XCTAssertEqual(KimiHookBlock.removeOrphans(from: clean, scriptDir: dir), clean)
    }

    /// 反复装不该越堆越多：清理后再清理，结果必须稳定
    func test幂等() {
        let once = KimiHookBlock.removeOrphans(from: realWorldToml, scriptDir: dir)
        let twice = KimiHookBlock.removeOrphans(from: once, scriptDir: dir)
        XCTAssertEqual(once, twice)
    }
}
