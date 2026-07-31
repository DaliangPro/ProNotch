import XCTest
@testable import ProNotch

/// Claude transcript 的续扫正确性（与 CodexIncrementalScanTests 同一组保障，差异在条目形态与标题）。
///
/// 由来（2026-07-31 刘海卡顿排查）：24 秒采样里 parseClaudeFile 独占一条后台核——
/// String 整读 + split 整串咀嚼，活跃 transcript 每追加一笔就整文件重嚼。
/// 换成指针级续扫后，这组用例锁「续扫 ≡ 全扫」与标题的末条语义
final class ClaudeIncrementalScanTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionUsage._resetClaudeCacheForTests()
    }

    override func tearDown() {
        SessionUsage._resetClaudeCacheForTests()
    }

    private var today: String { String(ISO8601DateFormatter().string(from: Date()).prefix(10)) }

    private func usageLine(day: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(day)T09:00:00.000Z","message":{"model":"claude-opus-5",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    private func titleLine(_ t: String) -> String {
        "{\"type\":\"custom-title\",\"customTitle\":\"\(t)\"}"
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func scan(_ root: URL) -> [(url: URL, entries: [SessionUsage.UsageEntry], title: String?)] {
        SessionUsage.claudeFileScans(root: root)
    }

    func test全量解析条目与标题() throws {
        _ = try write([usageLine(day: today, input: 100, output: 10),
                       titleLine("旧名"), titleLine("新名"),
                       usageLine(day: today, input: 0, output: 5)].joined(separator: "\n") + "\n",
                      to: "a.jsonl")
        let out = scan(dir)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].entries.map(\.tokens), [110, 5])
        XCTAssertEqual(out[0].title, "新名", "标题取末条")
    }

    /// 核心：残行补全 + 追加后，续扫结果必须与全新解析完全一致
    func test追加后续扫等于全量() throws {
        let lineA = usageLine(day: today, input: 10, output: 0)
        let lineB = usageLine(day: today, input: 0, output: 20)
        let lineC = usageLine(day: today, input: 0, output: 40)
        let half = String(lineC.prefix(lineC.count / 2))
        let inc = try write(lineA + "\n" + lineB + "\n" + half, to: "inc.jsonl")
        XCTAssertEqual(scan(dir)[0].entries.map(\.tokens), [10, 20], "残行是半截，解析不出")

        let fh = try FileHandle(forWritingTo: inc)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((String(lineC.dropFirst(half.count)) + "\n"
                                       + titleLine("尾名") + "\n").utf8))
        try fh.close()
        let incOut = scan(dir)[0]
        XCTAssertEqual(incOut.entries.map(\.tokens), [10, 20, 40], "残行补全后恰好算一次")
        XCTAssertEqual(incOut.title, "尾名")

        // 同内容全新文件对照
        SessionUsage._resetClaudeCacheForTests()
        let fresh = scan(dir)[0]
        XCTAssertEqual(incOut.entries.map(\.tokens), fresh.entries.map(\.tokens))
        XCTAssertEqual(incOut.title, fresh.title)
    }

    /// 末尾残行是「结果的一部分」但不进续扫基底：命中缓存的第二次也要带上它
    func test缓存命中含残行标题() throws {
        _ = try write(usageLine(day: today, input: 3, output: 0) + "\n" + titleLine("残标题"),
                      to: "tail.jsonl")   // 标题行刻意无换行
        XCTAssertEqual(scan(dir)[0].title, "残标题")
        XCTAssertEqual(scan(dir)[0].title, "残标题", "零 IO 命中同样要有")
    }

    func test截短改写后全量重扫() throws {
        let url = try write(usageLine(day: today, input: 10, output: 0) + "\n"
                            + usageLine(day: today, input: 20, output: 0) + "\n", to: "s.jsonl")
        XCTAssertEqual(scan(dir)[0].entries.count, 2)
        try Data((usageLine(day: today, input: 7, output: 0) + "\n").utf8).write(to: url)
        XCTAssertEqual(scan(dir)[0].entries.map(\.tokens), [7], "截短后按新内容重算")
    }

    /// 非官方模型（第三方中转）不入账——口径与旧实现一致
    func test第三方模型不计() throws {
        _ = try write("""
            {"type":"assistant","timestamp":"\(today)T09:00:00.000Z","message":{"model":"deepseek-v4",\
            "usage":{"input_tokens":999,"output_tokens":1}}}
            """ + "\n", to: "x.jsonl")
        XCTAssertTrue(scan(dir)[0].entries.isEmpty)
    }
}
