import XCTest
@testable import ProNotch

/// 按问题语言选搜索渠道（大梁老师 2026-08-03 拍板）。
///
/// 海外索引（Tavily/Brave/DDG）对中文论坛、公众号、垂直站覆盖弱；博查是国内索引。
/// 实测同题对照：「小红书起号」类问题博查 8/8 条中文来源（青瓜传媒、人人都是产品经理
/// 等垂直站），Tavily 虽也 8 条但混入 YouTube、海外 App Store。
/// 分流只在两把 Key 都配了时启用——少一把就维持单渠道旧行为
final class SearchEngineRoutingTests: XCTestCase {

    private func config(engine: SearchEngine, key: String,
                        alt: SearchEngine? = nil, altKey: String = "") -> ChatRequestConfig {
        ChatRequestConfig(providerID: UUID(), baseURL: "https://e.com/v1", apiKey: "k",
                          model: "m", searchEngine: engine, searchKey: key,
                          alternateEngine: alt, alternateKey: altKey, thinking: false)
    }

    // MARK: - 语言判定

    func test纯中文判为中文() {
        XCTAssertTrue(SearchEngine.isChineseQuery("小红书起号最新玩法"))
    }

    func test纯英文判为非中文() {
        XCTAssertFalse(SearchEngine.isChineseQuery("SwiftUI LazyVStack performance"))
    }

    /// 中文技术问题常夹大量英文专名，中文占比可以低到 5.7%
    ///（「…orderFrontRegardless 用法」）。这两条把判据从「比例」逼成了「有没有」
    func test中文夹英文专名仍判中文() {
        XCTAssertTrue(SearchEngine.isChineseQuery("SwiftUI LazyVStack 为什么会卡顿"))
        XCTAssertTrue(SearchEngine.isChineseQuery("macOS NSWindow orderFrontRegardless 用法"))
    }

    func test空串与纯符号不判中文() {
        XCTAssertFalse(SearchEngine.isChineseQuery(""))
        XCTAssertFalse(SearchEngine.isChineseQuery("--- ??? !!!"))
        XCTAssertFalse(SearchEngine.isChineseQuery("2026 GPT-5 release date"), "数字与英文不算中文")
    }

    // MARK: - 渠道选择

    func test中文问题改走博查() {
        let c = config(engine: .tavily, key: "tav", alt: .bocha, altKey: "bo")
        let picked = ChatStore.pickEngine(for: "小红书起号最新玩法", config: c)
        XCTAssertEqual(picked.engine, .bocha)
        XCTAssertEqual(picked.key, "bo")
    }

    func test英文问题留在Tavily() {
        let c = config(engine: .tavily, key: "tav", alt: .bocha, altKey: "bo")
        let picked = ChatStore.pickEngine(for: "SwiftUI performance tips", config: c)
        XCTAssertEqual(picked.engine, .tavily)
    }

    /// 主引擎选博查时反向也成立：英文问题改走 Tavily
    func test主选博查时英文问题改走Tavily() {
        let c = config(engine: .bocha, key: "bo", alt: .tavily, altKey: "tav")
        let picked = ChatStore.pickEngine(for: "SwiftUI performance tips", config: c)
        XCTAssertEqual(picked.engine, .tavily)
        XCTAssertEqual(picked.key, "tav")
    }

    /// 没配备用引擎＝单渠道旧行为，任何语言都不改道
    func test无备用引擎时永不改道() {
        let c = config(engine: .tavily, key: "tav")
        XCTAssertEqual(ChatStore.pickEngine(for: "小红书起号", config: c).engine, .tavily)
        XCTAssertEqual(ChatStore.pickEngine(for: "swift tips", config: c).engine, .tavily)
    }

    /// 备用 Key 是空串时同样不改道（配了引擎没填 Key 的中间态）
    func test备用Key为空不改道() {
        let c = config(engine: .tavily, key: "tav", alt: .bocha, altKey: "")
        XCTAssertEqual(ChatStore.pickEngine(for: "小红书起号", config: c).engine, .tavily)
    }

    // MARK: - 博查时效词表

    func test时效词表映射() {
        XCTAssertEqual(WebSearch.bochaFreshness("day"), "oneDay")
        XCTAssertEqual(WebSearch.bochaFreshness("week"), "oneWeek")
        XCTAssertEqual(WebSearch.bochaFreshness("month"), "oneMonth")
        XCTAssertEqual(WebSearch.bochaFreshness("year"), "oneYear")
        XCTAssertEqual(WebSearch.bochaFreshness(nil), "noLimit")
        XCTAssertEqual(WebSearch.bochaFreshness("乱填"), "noLimit", "未知值退 noLimit，别把请求打挂")
    }
}
