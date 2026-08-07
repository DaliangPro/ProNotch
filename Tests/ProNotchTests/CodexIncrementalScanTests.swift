import XCTest
@testable import ProNotch

/// Codex rollout 文件的续扫正确性。
///
/// 由来（2026-07-31）：主力长会话（实测 200MB）每追加一笔就被从头重扫一遍，
/// 采样自耗时榜第一是 `Data.firstIndex(of:)`——一个核常年被吃满，大梁老师叫修。
/// 修法是「变长就从上次的换行处续扫」，这组用例锁住**续扫结果必须等于全量重扫**，
/// 尤其是末尾残行（无换行收尾的最新一笔）在补全前后都不重不漏
final class CodexIncrementalScanTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionUsage._resetCodexCacheForTests()
    }

    override func tearDown() {
        SessionUsage._resetCodexCacheForTests()
    }

    /// 一条 token_count 事件（与真实 rollout 同构：payload 里带 last_token_usage）
    private func event(day: String, input: Int = 0, cached: Int = 0, output: Int) -> String {
        """
        {"timestamp":"\(day)T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "output_tokens":\(output)}}}}
        """
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private var today: String { String(ISO8601DateFormatter().string(from: Date()).prefix(10)) }

    func test全量扫描逐日聚桶() throws {
        let day = today
        let url = try write([event(day: day, input: 100, cached: 40, output: 10),
                             event(day: day, output: 5),
                             "{\"type\":\"other\"}"].joined(separator: "\n") + "\n", to: "rollout-a.jsonl")
        let info = SessionUsage.codexFileInfo(url)
        // (100-40)+10 + 5 = 75
        XCTAssertEqual(info.buckets[day], 75)
    }

    /// 核心用例：先扫一遍（末行无换行），再补全末行并追加新行——续扫结果必须与
    /// 一个从未见过该文件的全量扫描完全一致
    func test追加后续扫等于全量重扫() throws {
        let day = today
        let full = try write("", to: "rollout-full.jsonl")
        let inc = try write("", to: "rollout-inc.jsonl")

        // 第一阶段：两行完整 + 半行残尾（正在写入的最新一笔）
        let lineA = event(day: day, output: 10)
        let lineB = event(day: day, output: 20)
        let lineC = event(day: day, output: 40)
        let half = String(lineC.prefix(lineC.count / 2))
        try Data((lineA + "\n" + lineB + "\n" + half).utf8).write(to: inc)
        let stage1 = SessionUsage.codexFileInfo(inc)
        XCTAssertEqual(stage1.buckets[day], 30, "残行是半截 JSON，解析不出，只有 A+B")

        // 第二阶段：残行补全 + 再追加一行完整的
        let lineD = event(day: day, output: 80)
        let fh = try FileHandle(forWritingTo: inc)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((String(lineC.dropFirst(half.count)) + "\n" + lineD + "\n").utf8))
        try fh.close()

        let incResult = SessionUsage.codexFileInfo(inc)     // 走续扫（文件变长、缓存在）
        try Data((lineA + "\n" + lineB + "\n" + lineC + "\n" + lineD + "\n").utf8).write(to: full)
        let fullResult = SessionUsage.codexFileInfo(full)   // 走全量（首次见）
        XCTAssertEqual(incResult.buckets, fullResult.buckets, "续扫与全扫必须一个数")
        XCTAssertEqual(incResult.buckets[day], 150, "10+20+40+80，残行补全后恰好算一次")
    }

    /// mtime+size 全等直接复用：第二次调用零 IO 也要拿到含残行的结果
    func test缓存命中结果含残行() throws {
        let day = today
        let url = try write(event(day: day, output: 10) + "\n" + event(day: day, output: 7),
                            to: "rollout-tail.jsonl")   // 末行刻意不带换行
        XCTAssertEqual(SessionUsage.codexFileInfo(url).buckets[day], 17)
        XCTAssertEqual(SessionUsage.codexFileInfo(url).buckets[day], 17, "命中缓存的第二次也得带上残行")
    }

    /// 文件被截短（改写）时不能沿用旧偏移，必须全量重扫
    func test截短后全量重扫() throws {
        let day = today
        let url = try write(event(day: day, output: 10) + "\n" + event(day: day, output: 20) + "\n",
                            to: "rollout-shrink.jsonl")
        XCTAssertEqual(SessionUsage.codexFileInfo(url).buckets[day], 30)
        try Data((event(day: day, output: 5) + "\n").utf8).write(to: url)
        XCTAssertEqual(SessionUsage.codexFileInfo(url).buckets[day], 5, "截短改写后应按新内容重算")
    }

    // MARK: - 模型桶（「最常用模型」的来源）

    /// rollout 把 model 写在 turn_context 行、消耗写在 token_count 行，两者不同行，
    /// 落账靠「当前生效的模型」这个跨行状态
    private func turnContext(_ model: String) -> String {
        "{\"timestamp\":\"\(today)T08:00:00.000Z\",\"type\":\"turn_context\"," +
        "\"payload\":{\"model\":\"\(model)\",\"cwd\":\"/tmp/x\"}}"
    }

    func test消耗算在当前生效的模型头上() throws {
        let url = try write([turnContext("gpt-5.6-sol"), event(day: today, output: 10),
                             turnContext("gpt-5.6-mini"), event(day: today, output: 20)]
                                .joined(separator: "\n") + "\n", to: "rollout-model.jsonl")
        let info = SessionUsage.codexFileInfo(url)
        XCTAssertEqual(info.models, ["gpt-5.6-sol": 10, "gpt-5.6-mini": 20], "换挡后的消耗要算给新模型")
        XCTAssertEqual(info.buckets[today], 30, "天桶不受模型换挡影响")
    }

    /// 首个 turn_context 之前的消耗归不到任何模型，但天桶不能少——
    /// 宁可模型桶偏少，也不能把它挂到某个猜出来的模型上
    func test没有模型信息时只进天桶() throws {
        let url = try write(event(day: today, output: 9) + "\n", to: "rollout-nomodel.jsonl")
        let info = SessionUsage.codexFileInfo(url)
        XCTAssertTrue(info.models.isEmpty)
        XCTAssertEqual(info.buckets[today], 9)
    }

    /// 核心：续扫可能从文件中段接着读，一条 turn_context 都碰不到——
    /// 「当前模型」必须随缓存带过去，否则续扫出来的消耗全部无主
    func test续扫的模型桶等于全扫() throws {
        let full = try write("", to: "rollout-model-full.jsonl")
        let inc = try write("", to: "rollout-model-inc.jsonl")
        let ctx = turnContext("gpt-5.6-sol")
        let a = event(day: today, output: 10), b = event(day: today, output: 20)
        let c = event(day: today, output: 40)
        let half = String(b.prefix(b.count / 2))

        try Data((ctx + "\n" + a + "\n" + half).utf8).write(to: inc)
        XCTAssertEqual(SessionUsage.codexFileInfo(inc).models, ["gpt-5.6-sol": 10])

        let fh = try FileHandle(forWritingTo: inc)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((String(b.dropFirst(half.count)) + "\n" + c + "\n").utf8))
        try fh.close()

        let incResult = SessionUsage.codexFileInfo(inc)      // 续扫：起点已在 turn_context 之后
        try Data((ctx + "\n" + a + "\n" + b + "\n" + c + "\n").utf8).write(to: full)
        let fullResult = SessionUsage.codexFileInfo(full)    // 全扫
        XCTAssertEqual(incResult.models, fullResult.models, "续扫与全扫的模型桶必须一个数")
        XCTAssertEqual(incResult.models, ["gpt-5.6-sol": 70], "10+20+40，残行补全后恰好算一次")
    }

    /// 大小写进 8MB 分块边界也不许丢行：造一条横跨块边界的记录
    func test跨分块边界的行不丢() throws {
        let day = today
        // 8MB 填充行（无 token_count，不解析）+ 跨界的有效行
        let filler = String(repeating: "x", count: 8 * 1024 * 1024 - 100)
        let url = try write("{\"pad\":\"\(filler)\"}\n" + event(day: day, output: 33) + "\n",
                            to: "rollout-chunk.jsonl")
        XCTAssertEqual(SessionUsage.codexFileInfo(url).buckets[day], 33)
    }
}
