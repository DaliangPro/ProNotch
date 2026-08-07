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

    // MARK: - 逐条分流

    /// 分流按**每条查询**判，不跟着整句问题走。
    ///
    /// 由来（大梁老师 2026-08-07 的实例）：「千问办公和 QoderWork 有什么区别」
    /// 整句含中文，按整句判就整轮锁死走博查——可拆出来的 `QoderWork` 是纯英文产品名，
    /// 本该走英文强的那家。技术与产品话题里一句中文带几个英文名是常态
    func test同一轮里中英查询分头走() {
        let c = config(engine: .bocha, key: "bo", alt: .tavily, altKey: "tav")
        let routed = ChatStore.route(["千问办公", "QoderWork"], config: c)
        XCTAssertEqual(routed.count, 2)
        XCTAssertEqual(routed[0].engine, .bocha, "中文查询走国内索引")
        XCTAssertEqual(routed[0].key, "bo")
        XCTAssertEqual(routed[1].engine, .tavily, "纯英文产品名走英文强的那家")
        XCTAssertEqual(routed[1].key, "tav")
    }

    /// 查询词原样带过去，分流不许顺手改词
    func test分流不改动查询词() {
        let c = config(engine: .bocha, key: "bo", alt: .tavily, altKey: "tav")
        XCTAssertEqual(ChatStore.route(["千问办公 公测", "QoderWork 是什么"], config: c).map(\.query),
                       ["千问办公 公测", "QoderWork 是什么"])
    }

    /// 没配备用引擎时逐条判也得到同一家——单渠道旧行为不变
    func test无备用引擎时逐条判也不改道() {
        let c = config(engine: .bocha, key: "bo")
        let routed = ChatStore.route(["千问办公", "QoderWork"], config: c)
        XCTAssertEqual(Set(routed.map(\.engine)), [.bocha])
    }

    /// 日志只报渠道名、去重、不带查询词——查询词是用户问的内容，不该落进系统日志
    func test渠道摘要去重且不含查询词() {
        let c = config(engine: .bocha, key: "bo", alt: .tavily, altKey: "tav")
        let summary = ChatStore.routeSummary(
            ChatStore.route(["千问办公", "钉钉集成", "QoderWork"], config: c))
        XCTAssertEqual(summary, "bocha+tavily")
        XCTAssertFalse(summary.contains("千问办公"))
        XCTAssertEqual(ChatStore.routeSummary([]), "无")
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
