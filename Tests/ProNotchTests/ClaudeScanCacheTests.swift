import XCTest
@testable import ProNotch

/// Claude transcript 扫描缓存的回归护栏：解析口径不变、mtime+size 命中免重读、文件变化重扫。
/// 背景：Top 5 与额度估算此前各把 GB 级全库整读一遍，是常驻内存虚高的真凶（2026-07-18 排查）
final class ClaudeScanCacheTests: XCTestCase {
    private var root: URL!
    private var file: URL!
    private let iso = ISO8601DateFormatter()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pronotch-scan-\(UUID().uuidString)/projects/demo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("abc-session.jsonl")
    }

    override func tearDownWithError() throws {
        // 只清理本测试自建的系统临时目录（非用户文件）
        try? FileManager.default.removeItem(
            at: root.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func usageLine(hoursAgo: Double, tokens: Int, model: String = "claude-opus-4") -> String {
        let ts = iso.string(from: Date().addingTimeInterval(-hoursAgo * 3600))
        return #"{"type":"assistant","timestamp":"\#(ts)","message":{"model":"\#(model)","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
    }

    private func writeFile(_ lines: [String]) throws {
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func test解析口径与旧实现一致() throws {
        try writeFile([
            #"{"type":"custom-title","customTitle":"测试会话"}"#,
            usageLine(hoursAgo: 1, tokens: 100),
            usageLine(hoursAgo: 24, tokens: 50),
            usageLine(hoursAgo: 9 * 24, tokens: 999),                    // 窗外条目：文件 mtime 新也不算
            usageLine(hoursAgo: 2, tokens: 888, model: "gpt-x"),         // 非官方模型不算
            #"{"type":"assistant","message":{"model":"claude-opus-4","usage":{"input_tokens":7,"output_tokens":0}}}"#,   // 缺 timestamp：沿旧口径视为在窗内
            "not json at all",
        ])
        let scanned = SessionUsage.scanClaude(root: root)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned.first?.id, "abc-session")
        XCTAssertEqual(scanned.first?.tokens, 157)   // 100 + 50 + 7
        XCTAssertNotNil(scanned.first?.claudeTitle)

        // 底层共享解析结果：窗外/非官方条目不入缓存，标题原文保留，窗内条目 ts 可精确解析（估算路径用）
        let files = SessionUsage.claudeFileScans(root: root)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.title, "测试会话")
        XCTAssertEqual(files.first?.entries.count, 3)
        XCTAssertEqual(files.first?.entries.filter { $0.ts != nil }.count, 2)
    }

    func test缓存命中免重读且文件变化后重扫() throws {
        try writeFile([usageLine(hoursAgo: 1, tokens: 100)])
        let before = SessionUsage.claudeParseCount
        XCTAssertEqual(SessionUsage.scanClaude(root: root).first?.tokens, 100)
        XCTAssertEqual(SessionUsage.claudeParseCount, before + 1)

        // 第二遍（模拟同轮 refresh 里估算路径再扫）：mtime+size 未变，零重读
        XCTAssertEqual(SessionUsage.scanClaude(root: root).first?.tokens, 100)
        XCTAssertEqual(SessionUsage.claudeParseCount, before + 1)

        // 文件追加（活跃会话在写）：size 变了必然失效，重读拿到新值
        try writeFile([usageLine(hoursAgo: 1, tokens: 100), usageLine(hoursAgo: 0.5, tokens: 23)])
        XCTAssertEqual(SessionUsage.scanClaude(root: root).first?.tokens, 123)
        XCTAssertEqual(SessionUsage.claudeParseCount, before + 2)
    }
}
