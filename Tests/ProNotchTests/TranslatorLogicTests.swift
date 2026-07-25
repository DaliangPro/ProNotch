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

    func test补翻判定_只补自然语句不补专名() {
        // 该补：≥2 个普通词的自然语句（真漏翻）
        XCTAssertTrue(ScreenshotTranslator.isRetryWorthySentence("Download the latest version"))
        XCTAssertTrue(ScreenshotTranslator.isRetryWorthySentence("Sign in to continue"))
        // 中英混排句照补
        XCTAssertTrue(ScreenshotTranslator.isRetryWorthySentence("请下载 latest version"))
        // 不该补：品牌/驼峰/全大写缩写/单词条目——模型原样保留是正确输出，
        // 此前误判它们为漏翻导致几乎每屏都多跑一轮补翻请求
        XCTAssertFalse(ScreenshotTranslator.isRetryWorthySentence("DeepSeek"))
        XCTAssertFalse(ScreenshotTranslator.isRetryWorthySentence("GitHub Copilot"))
        XCTAssertFalse(ScreenshotTranslator.isRetryWorthySentence("OCR API"))
        XCTAssertFalse(ScreenshotTranslator.isRetryWorthySentence("Settings"))
        XCTAssertFalse(ScreenshotTranslator.isRetryWorthySentence("已经是中文了"))
    }

    /// 深度思考开关：开着不许往请求体里塞 thinking——OpenAI 这类严格校验未知字段的接口
    /// 会因为一个多余的键直接 400，而绝大多数用户根本不用 DeepSeek
    func test深度思考开关_只在关闭时写入请求体() {
        let on = ScreenshotTranslator.requestBody("[\"Save\"]", system: "sys", temperature: 0.2,
                                                  model: "deepseek-v4-flash", disableThinking: false)
        XCTAssertNil(on["thinking"], "默认（开启深度思考）不该出现 thinking 字段")
        XCTAssertEqual(on["model"] as? String, "deepseek-v4-flash")

        let off = ScreenshotTranslator.requestBody("[\"Save\"]", system: "sys", temperature: 0.2,
                                                   model: "deepseek-v4-flash", disableThinking: true)
        XCTAssertEqual(off["thinking"] as? [String: String], ["type": "disabled"],
                       "关闭时须按 DeepSeek 官方取值发 thinking:{type:disabled}")
        // 关思考不该动其他字段
        XCTAssertEqual(off["temperature"] as? Double, 0.2)
        XCTAssertEqual((off["messages"] as? [[String: String]])?.count, 2)
    }

    /// 接口报错说明必须原样带给用户：模型名过期、Key 失效、余额不足全是 4xx，
    /// 只报「接口返回 400」等于什么都没说（大梁老师实测 deepseek-chat 下线即撞此坑）
    func test接口错误说明_从各种响应体里抠出来() {
        let openAI = #"{"error":{"message":"The supported API model names are deepseek-v4-pro or deepseek-v4-flash, but you passed deepseek-chat.","type":"invalid_request_error"}}"#
        XCTAssertEqual(ScreenshotTranslator.apiMessage(Data(openAI.utf8)),
                       "The supported API model names are deepseek-v4-pro or deepseek-v4-flash, but you passed deepseek-chat.")
        // 少数实现把说明放顶层
        XCTAssertEqual(ScreenshotTranslator.apiMessage(Data(#"{"message":"Insufficient Balance"}"#.utf8)), "Insufficient Balance")
        // 非 JSON 直接当纯文本
        XCTAssertEqual(ScreenshotTranslator.apiMessage(Data("Bad Gateway".utf8)), "Bad Gateway")
        // 空体不硬凑一句空话
        XCTAssertNil(ScreenshotTranslator.apiMessage(Data()))
        // 整篇 HTML 报错要截断，不能撑爆提示气泡
        let long = String(repeating: "长", count: 400)
        let cut = ScreenshotTranslator.apiMessage(Data(long.utf8))
        XCTAssertEqual(cut?.count, 121)   // 120 字 + 省略号
        XCTAssertTrue(cut?.hasSuffix("…") == true)
    }
}
