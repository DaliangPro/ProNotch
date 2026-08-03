import XCTest
@testable import ProNotch

/// Top 5 的 token 窗口必须锚定额度窗口起点（大梁老师 2026-08-03「Codex 严重不准」）。
///
/// 分账公式是「token 占比 × 已用%」，分子分母必须同一段时间。OpenAI 的 Pro Lite
/// 只有一个 7 天窗（且从重置时刻起算），token 侧若固定往前推 7 天，重置前的
/// 老会话也来分当前额度——他机器实测：旧口径分母 1.44 亿 token，锚定后 2860 万，
/// 榜单五席换了三席。这里锁 since 参数的过滤语义
final class QuotaWindowAnchorTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionUsage._resetCodexCacheForTests()
    }

    override func tearDown() { SessionUsage._resetCodexCacheForTests() }

    private func event(daysAgo: Int, output: Int) -> String {
        let day = String(ISO8601DateFormatter()
            .string(from: Date().addingTimeInterval(-Double(daysAgo) * 86400)).prefix(10))
        return """
        {"timestamp":"\(day)T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":\(output)}}}}
        """
    }

    func test锚定起点把重置前的会话挡在门外() throws {
        // 老会话：全部消耗在 5 天前；新会话：全部在 1 天内
        try Data((event(daysAgo: 5, output: 1000) + "\n").utf8)
            .write(to: dir.appendingPathComponent("rollout-old.jsonl"))
        try Data((event(daysAgo: 0, output: 300) + "\n").utf8)
            .write(to: dir.appendingPathComponent("rollout-new.jsonl"))

        // 不锚定：两个都在 7 天窗内
        let unanchored = SessionUsage.scanCodex(root: dir)
        XCTAssertEqual(unanchored.count, 2)

        // 锚定到 2 天前（模拟额度窗口重置点）：老会话不再入账
        SessionUsage._resetCodexCacheForTests()
        let anchored = SessionUsage.scanCodex(root: dir,
                                              since: Date().addingTimeInterval(-2 * 86400))
        XCTAssertEqual(anchored.count, 1, "重置前的老会话不该来分当前额度")
        XCTAssertEqual(anchored.first?.tokens, 300)
    }

    /// 锚点早于 7 天时以 7 天为界（额度端点没通时的退路不放大扫描范围）
    func test锚点不早于七天() throws {
        try Data((event(daysAgo: 6, output: 500) + "\n").utf8)
            .write(to: dir.appendingPathComponent("rollout-a.jsonl"))
        let out = SessionUsage.scanCodex(root: dir,
                                         since: Date().addingTimeInterval(-30 * 86400))
        XCTAssertEqual(out.first?.tokens, 500, "六天前的会话仍在七天窗内，应照常入账")
    }
}
