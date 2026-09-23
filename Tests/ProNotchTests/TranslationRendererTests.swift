import XCTest
@testable import ProNotch

/// 译文原位渲染的判定规则：抠错片段会把代码/产品名送去翻译（"import NaturalLanguage"
/// 变成「导入自然语言」），抠漏则该翻的英文原样留在图上。这些规则此前锁在
/// ScreenshotOverlayView 的 private 里，只能靠截图实跑肉眼比对。
final class TranslationRendererTests: XCTestCase {

    // MARK: - 拉丁片段是否该翻

    func test该翻_纯自然语言英文() {
        XCTAssertTrue(TranslationRenderer.latinFragNeedsTranslation("Read a file"))
        XCTAssertTrue(TranslationRenderer.latinFragNeedsTranslation("helper"))
    }

    func test不翻_代码标识符与专名() {
        // 驼峰标识符：普通词 import 只有 1 个，整体视为代码
        XCTAssertFalse(TranslationRenderer.latinFragNeedsTranslation("import NaturalLanguage"))
        XCTAssertFalse(TranslationRenderer.latinFragNeedsTranslation("snake_case_name"))
        XCTAssertFalse(TranslationRenderer.latinFragNeedsTranslation("API"))       // 全大写缩写
        XCTAssertFalse(TranslationRenderer.latinFragNeedsTranslation("deepseek"))  // 白名单产品名
        XCTAssertFalse(TranslationRenderer.latinFragNeedsTranslation("a"))         // 太短
    }

    func test该翻_自然语句里嵌产品名() {
        // 普通词≥2 → 整句送翻，产品名交翻译引擎按语义保留
        XCTAssertTrue(TranslationRenderer.latinFragNeedsTranslation(
            "Here is your GitHub authentication code"))
    }

    // MARK: - 从块文本里抠待翻片段

    func test抠片段_目标中文时抠英文放过代码值() {
        let frags = TranslationRenderer.translatableFragments(
            in: "运行结果 status=200 与 Read a file 两项", targetLang: "zh-Hans")
        let texts = frags.map(\.text)
        XCTAssertTrue(texts.contains("Read a file"))
        XCTAssertFalse(texts.contains("status"), "字母紧贴代码值的前缀不该被单独抠去翻")
    }

    func test抠片段_目标英文时抠中文() {
        let frags = TranslationRenderer.translatableFragments(
            in: "打开 Finder 窗口", targetLang: "en")
        XCTAssertEqual(frags.map(\.text), ["打开", "窗口"])
    }

    func test抠片段_目标中文时日文整句送翻() {
        // 日文汉字与假名不拆开；纯汉字词在带假名的块里也算日文
        let frags = TranslationRenderer.translatableFragments(
            in: "東京都の天気予報、明日は晴れ。", targetLang: "zh-Hans")
        XCTAssertEqual(frags.map(\.text), ["東京都の天気予報、明日は晴れ"])
        let kanjiOnly = TranslationRenderer.translatableFragments(
            in: "設定 ボタンを押す", targetLang: "zh-Hans")
        XCTAssertEqual(kanjiOnly.map(\.text), ["設定", "ボタンを押す"])
    }

    func test抠片段_目标中文时韩文送翻中文保留() {
        let frags = TranslationRenderer.translatableFragments(
            in: "中文说明 안녕하세요 세계", targetLang: "zh-Hans")
        XCTAssertEqual(frags.map(\.text), ["안녕하세요 세계"])
    }

    func test抠片段_目标日文时中文要翻日文保留() {
        let zh = TranslationRenderer.translatableFragments(in: "打开设置", targetLang: "ja")
        XCTAssertEqual(zh.map(\.text), ["打开设置"])
        let ja = TranslationRenderer.translatableFragments(in: "設定を開く", targetLang: "ja")
        XCTAssertTrue(ja.isEmpty)
    }

    func test抠片段_带重音的西文与俄文不被拆词() {
        let frags = TranslationRenderer.translatableFragments(
            in: "Ouvrir le café · Привет мир", targetLang: "zh-Hans")
        XCTAssertEqual(frags.map(\.text), ["Ouvrir le café", "Привет мир"])
    }

    func test抠片段_混排按位置升序且回填不错位() {
        let text = "点击 안녕 然后 Cancel"
        let frags = TranslationRenderer.translatableFragments(in: text, targetLang: "zh-Hans")
        XCTAssertEqual(frags.map(\.text), ["안녕", "Cancel"])
        let out = TranslationRenderer.applyFragments(text, frags, ["안녕": "你好", "Cancel": "取消"])
        XCTAssertEqual(out, "点击 你好 然后 取消")
    }

    // MARK: - 译文就地回填

    func test回填_从后往前替换不错位() {
        let text = "点击 Save 然后 Cancel"
        let frags = TranslationRenderer.translatableFragments(in: text, targetLang: "zh-Hans")
        let out = TranslationRenderer.applyFragments(text, frags, ["Save": "保存", "Cancel": "取消"])
        XCTAssertEqual(out, "点击 保存 然后 取消")
    }

    func test回填_无译文或译文同原文时保留原样() {
        let text = "点击 Save"
        let frags = TranslationRenderer.translatableFragments(in: text, targetLang: "zh-Hans")
        XCTAssertEqual(TranslationRenderer.applyFragments(text, frags, [:]), text)
        XCTAssertEqual(TranslationRenderer.applyFragments(text, frags, ["Save": "Save"]), text)
    }

    // MARK: - 配色

    func test文字色_深底给白字浅底给黑字() {
        XCTAssertEqual(TranslationRenderer.contrast(.black), .white)
        XCTAssertEqual(TranslationRenderer.contrast(.white), .black)
    }

    /// 底色取样走的是 CGImage 直方图，与上面的纯字符串逻辑是两条路径，单独冒烟一次
    @MainActor
    func test底色取样_纯色图取到该色() throws {
        let size = 40
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(ctx.makeImage())

        let bg = TranslationRenderer.dominantBg(image, CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = try XCTUnwrap(bg.usingColorSpace(.deviceRGB))
        XCTAssertEqual(c.redComponent, 0.2, accuracy: 0.03)
        XCTAssertEqual(c.greenComponent, 0.4, accuracy: 0.03)
        XCTAssertEqual(c.blueComponent, 0.8, accuracy: 0.03)
        // 该底色偏暗 → 文字应取白（框内无文字像素时退回对比色）
        XCTAssertEqual(TranslationRenderer.textColor(image, CGRect(x: 0, y: 0, width: 1, height: 1), bg: bg), .white)
    }
}
