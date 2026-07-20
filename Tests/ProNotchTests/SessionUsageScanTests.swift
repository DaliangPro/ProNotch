import XCTest
@testable import ProNotch

/// Kimi / Grok 耗额榜扫描口径（2.0 接入时逐条实测本机数据定的规矩）。
/// 这些断言锁的都是「用错字段照样能跑出好看数字」的地方——不锁住，回归时无人察觉。
final class SessionUsageScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pronotch-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)   // 测试自建的临时夹具，随用随清
    }

    private func write(_ lines: [String], to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    // MARK: - Grok

    /// 最关键的一条：消耗必须取 turn_completed.usage，绝不能取 _meta.totalTokens。
    /// 后者是上下文窗口占用，同一会话实测 55049 vs 901657——差 16 倍，
    /// 且是低估，屏显「这个对话只花了一点」完全看不出错
    func testGrok不拿上下文占用充当消耗() throws {
        try write([
            #"{"timestamp":\#(now),"params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk"}},"_meta":{"totalTokens":999999}}"#,
            #"{"timestamp":\#(now),"params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1000,"cachedReadTokens":700,"outputTokens":50}}}}"#,
        ], to: "proj/s1/updates.jsonl")

        let out = SessionUsage.scanGrok(root: root)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.tokens, 350,
                       "应为 (1000−700)+50；若等于 999999 说明误用了 _meta.totalTokens")
    }

    func testGrok多轮求和且扣缓存读() throws {
        try write([
            #"{"timestamp":\#(now),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1000,"cachedReadTokens":700,"outputTokens":50}}}}"#,
            #"{"timestamp":\#(now),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":200,"cachedReadTokens":0,"outputTokens":30}}}}"#,
        ], to: "proj/s1/updates.jsonl")

        XCTAssertEqual(SessionUsage.scanGrok(root: root).first?.tokens, 580, "350 + 230")
    }

    /// 同一会话 uuid 会被写进多个项目目录（本机实测有）。按目录累加 = 同一笔算两次，
    /// 故取记录最全的一份
    func testGrok同一会话跨项目目录不重复计() throws {
        try write([
            #"{"timestamp":\#(now),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100,"cachedReadTokens":0,"outputTokens":0}}}}"#,
        ], to: "projA/same-uuid/updates.jsonl")
        try write([
            #"{"timestamp":\#(now),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100,"cachedReadTokens":0,"outputTokens":0}}}}"#,
            #"{"timestamp":\#(now),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":300,"cachedReadTokens":0,"outputTokens":0}}}}"#,
        ], to: "projB/same-uuid/updates.jsonl")

        let out = SessionUsage.scanGrok(root: root)
        XCTAssertEqual(out.count, 1, "同 uuid 只出一行")
        XCTAssertEqual(out.first?.tokens, 400, "取记录最全的一份（400），不是两份相加（500）")
    }

    func testGrok窗口外的轮次不计() throws {
        let old = now - 8 * 86400   // 近 7 天窗口之外
        try write([
            #"{"timestamp":\#(old),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":9999,"cachedReadTokens":0,"outputTokens":0}}}}"#,
            #"{"timestamp":\#(now),"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":10,"cachedReadTokens":0,"outputTokens":5}}}}"#,
        ], to: "proj/s1/updates.jsonl")

        XCTAssertEqual(SessionUsage.scanGrok(root: root).first?.tokens, 15, "只算窗口内的轮次")
    }

    // MARK: - Kimi

    /// 缓存读必须扣：实测一个会话含缓存 5636 万、扣掉才 86 万，
    /// 不扣的话单个对话在榜上显示成几千万 token，整个榜失真
    func testKimi扣掉缓存读() throws {
        try write([
            #"{"type":"usage.record","usage":{"inputOther":100,"output":20,"inputCacheRead":5000},"time":\#(now * 1000)}"#,
        ], to: "wd_x/session_a/agents/main/wire.jsonl")

        XCTAssertEqual(SessionUsage.scanKimi(root: root).first?.tokens, 120,
                       "应为 100+20；若等于 5120 说明把缓存读也算进了消耗")
    }

    /// 主代理与子代理各写各的 wire.jsonl，同一任务不该在榜上占成两行
    func testKimi子代理归并到会话() throws {
        try write([
            #"{"type":"usage.record","usage":{"inputOther":100,"output":0},"time":\#(now * 1000)}"#,
        ], to: "wd_x/session_a/agents/main/wire.jsonl")
        try write([
            #"{"type":"usage.record","usage":{"inputOther":40,"output":0},"time":\#(now * 1000)}"#,
        ], to: "wd_x/session_a/agents/agent-0/wire.jsonl")

        let out = SessionUsage.scanKimi(root: root)
        XCTAssertEqual(out.count, 1, "同一 session_ 目录只出一行")
        XCTAssertEqual(out.first?.id, "session_a")
        XCTAssertEqual(out.first?.tokens, 140, "主代理 100 + 子代理 40")
    }

    func testKimi窗口外的记录不计() throws {
        let oldMs = (now - 8 * 86400) * 1000
        try write([
            #"{"type":"usage.record","usage":{"inputOther":9999,"output":0},"time":\#(oldMs)}"#,
            #"{"type":"usage.record","usage":{"inputOther":10,"output":5},"time":\#(now * 1000)}"#,
        ], to: "wd_x/session_a/agents/main/wire.jsonl")

        XCTAssertEqual(SessionUsage.scanKimi(root: root).first?.tokens, 15)
    }
}
