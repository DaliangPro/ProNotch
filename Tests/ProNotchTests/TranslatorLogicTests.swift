import XCTest
@testable import ProNotch

/// 翻译分块与漏翻判定：分块错位会导致译文贴错位置，漏翻判定错会补翻不该翻的
final class TranslatorLogicTests: XCTestCase {
    func test分块_预算与边界() {
        // 每条 200 字 × 6 条，预算 400 → 每块两条，三块连续且覆盖全部
        let texts = Array(repeating: String(repeating: "字", count: 200), count: 6)
        let ranges = ScreenshotTranslator.chunkRanges(texts, budget: 400)
        XCTAssertEqual(ranges, [0..<2, 2..<4, 4..<6])
        // 单条超预算也独占一块，不会产生空块
        let big = [String(repeating: "长", count: 999), "短"]
        XCTAssertEqual(ScreenshotTranslator.chunkRanges(big, budget: 400), [0..<1, 1..<2])
        XCTAssertEqual(ScreenshotTranslator.chunkRanges([], budget: 400), [])
    }

    func test漏翻判定_该翻的与不该翻的() {
        XCTAssertTrue(ScreenshotTranslator.looksTranslatable("Hello world"))
        XCTAssertTrue(ScreenshotTranslator.looksTranslatable("Sign in to continue"))
        // 原样回传是对的，不算漏翻：URL / 路径 / 纯数字 / 时间
        XCTAssertFalse(ScreenshotTranslator.looksTranslatable("https://github.com/DaliangPro"))
        XCTAssertFalse(ScreenshotTranslator.looksTranslatable("/Applications/ProNotch.app"))
        XCTAssertFalse(ScreenshotTranslator.looksTranslatable("2026-07-04 12:00"))
        XCTAssertFalse(ScreenshotTranslator.looksTranslatable("42"))
        // 中文本身不需要再翻
        XCTAssertFalse(ScreenshotTranslator.looksTranslatable("已经是中文了"))
    }
}
