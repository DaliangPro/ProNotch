import XCTest
@testable import ProNotch

/// 系统翻译语言映射：设置里的 8 种目标语言 → BCP-47，映射错会让系统翻译静默失效
final class SystemTranslatorTests: XCTestCase {
    func test语言码映射() {
        XCTAssertEqual(SystemTranslator.languageCode(for: "中文"), "zh-Hans")
        XCTAssertEqual(SystemTranslator.languageCode(for: "English"), "en")
        XCTAssertEqual(SystemTranslator.languageCode(for: "日本語"), "ja")
        XCTAssertEqual(SystemTranslator.languageCode(for: "한국어"), "ko")
        XCTAssertEqual(SystemTranslator.languageCode(for: "Français"), "fr")
        XCTAssertEqual(SystemTranslator.languageCode(for: "Deutsch"), "de")
        XCTAssertEqual(SystemTranslator.languageCode(for: "Español"), "es")
        XCTAssertEqual(SystemTranslator.languageCode(for: "Русский"), "ru")
        XCTAssertEqual(SystemTranslator.languageCode(for: "未知语言"), "zh-Hans")   // 兜底
    }
}
