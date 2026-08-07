import XCTest
@testable import ProNotch

/// 检索规划与多查询合并。
///
/// 由来（2026-07-29 大梁老师反馈「联网搜索没跟回答融合」）：原先一个问题只搜一条查询词。
/// Tavily 官方对复杂问题的建议是拆成子查询分别发
///（"Break complex queries into sub-queries. Send separate focused requests"），
/// 于是改写器升级成规划器。而规划器的输出是模型生成的 JSON——不可能百分百可靠，
/// 所以这里重点钉「解析不出来时必须安全退回」，而不是只测顺利路径。
final class SearchPlanTests: XCTestCase {

    // MARK: - 要不要联网

    /// 开关打开只表示「允许它搜」，不是「每次都搜」（大梁老师 2026-07-29 提的）。
    /// 写代码、翻译、算数、加工对话里已有的内容，联网没用还白等一次搜索
    func test明确判定无需联网时跳过搜索() {
        let plan = ChatStore.parsePlan(#"{"search":false,"queries":[]}"#, fallback: "原问题")
        XCTAssertFalse(plan.shouldSearch)
        XCTAssertTrue(plan.queries.isEmpty)
    }

    /// 说了不搜，就算顺手带了 queries 也不搜——判断在前，查询词只是附属
    func test判定不搜时带了查询词也不搜() {
        let plan = ChatStore.parsePlan(#"{"search":false,"queries":["还是搜一下"]}"#, fallback: "f")
        XCTAssertFalse(plan.shouldSearch)
        XCTAssertTrue(plan.queries.isEmpty)
    }

    /// search 字段缺失当成「要搜」：这是改造前的老行为，缺字段不该让功能失灵
    func test缺search字段默认要搜() {
        let plan = ChatStore.parsePlan(#"{"queries":["苹果发布会"]}"#, fallback: "f")
        XCTAssertTrue(plan.shouldSearch)
        XCTAssertEqual(plan.queries, ["苹果发布会"])
    }

    /// 关键安全网：拿不准（解析失败）一律**照旧搜**。
    /// 反过来（拿不准就不搜）会让联网时灵时不灵，用户根本不知道这次为什么没查
    func test解析失败时仍然要搜() {
        for raw in ["", "我不确定", "{坏 JSON"] {
            let plan = ChatStore.parsePlan(raw, fallback: "原问题")
            XCTAssertTrue(plan.shouldSearch, "「\(raw)」应退回照旧搜")
            XCTAssertEqual(plan.queries, ["原问题"])
        }
    }

    /// search 为 true 但没给查询词 → 拿原问题搜，不能空手去搜
    func test说要搜却没给查询词则用原问题() {
        let plan = ChatStore.parsePlan(#"{"search":true,"queries":[]}"#, fallback: "原问题")
        XCTAssertTrue(plan.shouldSearch)
        XCTAssertEqual(plan.queries, ["原问题"])
    }

    // MARK: - 规划解析

    func test标准JSON解析() {
        let plan = ChatStore.parsePlan(
            #"{"queries":["DeepSeek V4 发布","DeepSeek V4 定价"],"time_range":"week","news":true}"#,
            fallback: "原问题")
        XCTAssertEqual(plan.queries, ["DeepSeek V4 发布", "DeepSeek V4 定价"])
        XCTAssertEqual(plan.timeRange, "week")
        XCTAssertTrue(plan.news)
    }

    /// 模型爱裹 ```json 围栏，也爱在前后加一句解释。都得能剥出来
    func test围栏与前后废话都能剥掉() {
        let raw = """
        好的，我来规划：
        ```json
        {"queries":["苹果 M5 芯片"],"time_range":null,"news":false}
        ```
        以上是我的规划。
        """
        let plan = ChatStore.parsePlan(raw, fallback: "原问题")
        XCTAssertEqual(plan.queries, ["苹果 M5 芯片"])
        XCTAssertNil(plan.timeRange)
        XCTAssertFalse(plan.news)
    }

    /// 核心安全网：解析不出来一律退回「拿原问题搜一次」。
    /// 那就是改造前的老行为，绝不会比现在更糟
    func test解析失败退回原问题() {
        for raw in ["", "我不知道", "查询词：苹果发布会", "{坏 JSON", "[]", "null"] {
            let plan = ChatStore.parsePlan(raw, fallback: "原问题")
            XCTAssertEqual(plan.queries, ["原问题"], "「\(raw)」应退回原问题")
            XCTAssertNil(plan.timeRange)
            XCTAssertFalse(plan.news)
        }
    }

    /// JSON 合法但 queries 空 / 全是空串 → 同样退回，不能拿空查询去搜
    func test查询为空时退回原问题() {
        XCTAssertEqual(ChatStore.parsePlan(#"{"queries":[]}"#, fallback: "原问题").queries, ["原问题"])
        XCTAssertEqual(ChatStore.parsePlan(#"{"queries":["","  "]}"#, fallback: "原问题").queries, ["原问题"])
    }

    /// 拆太多条就是烧 credits，上限卡死
    func test查询条数封顶() {
        let raw = #"{"queries":["a","b","c","d","e"]}"#
        XCTAssertEqual(ChatStore.parsePlan(raw, fallback: "原问题").queries.count,
                       WebSearch.maxQueries)
    }

    /// 过长的「查询词」多半是模型把整句问题抄了过来——Tavily 明确要求查询要短、
    /// 是关键词而非长句，抄整句会显著拉低相关度，所以剔掉
    func test过长的查询被剔除() {
        let long = String(repeating: "词", count: 100)
        let plan = ChatStore.parsePlan(
            "{\"queries\":[\"\(long)\",\"正常查询\"]}", fallback: "原问题")
        XCTAssertEqual(plan.queries, ["正常查询"])
    }

    /// 时效只认 Tavily 白名单里的四个值。传别的上去会被接口拒掉，
    /// 整轮搜索就白搭了——宁可不限时间
    func test时效范围只认白名单() {
        for good in ["day", "week", "month", "year"] {
            let plan = ChatStore.parsePlan("{\"queries\":[\"q\"],\"time_range\":\"\(good)\"}",
                                           fallback: "f")
            XCTAssertEqual(plan.timeRange, good)
        }
        for bad in ["最近一周", "7d", "hour", "recent", ""] {
            let plan = ChatStore.parsePlan("{\"queries\":[\"q\"],\"time_range\":\"\(bad)\"}",
                                           fallback: "f")
            XCTAssertNil(plan.timeRange, "「\(bad)」不该被当成合法时效")
        }
    }

    func test大小写不敏感的时效() {
        XCTAssertEqual(ChatStore.parsePlan(#"{"queries":["q"],"time_range":"WEEK"}"#,
                                           fallback: "f").timeRange, "week")
    }

    // MARK: - 多查询合并

    private func hit(_ url: String) -> SearchResult {
        SearchResult(title: url, url: url)
    }

    /// 交错而不是拼接：每条查询的头名依次排在最前。
    /// 简单拼接的话，第二个子话题的最佳结果会排在第一个子话题的第 8 名之后，
    /// 正文预算轮到它时早就用光了
    func test交错合并让各查询的头名都靠前() {
        let merged = WebSearch.interleave(
            [0: [hit("https://a1"), hit("https://a2")],
             1: [hit("https://b1"), hit("https://b2")]],
            order: 0..<2)
        XCTAssertEqual(merged.map(\.url), ["https://a1", "https://b1", "https://a2", "https://b2"])
    }

    /// 同一页被多条查询同时命中很常见，只能留一次
    func test同一URL只留一次() {
        let merged = WebSearch.interleave(
            [0: [hit("https://same"), hit("https://a2")],
             1: [hit("https://same"), hit("https://b2")]],
            order: 0..<2)
        XCTAssertEqual(merged.map(\.url), ["https://same", "https://a2", "https://b2"])
    }

    /// 长度不齐时不许越界，短的那条用完就跳过
    func test各查询结果数不等也不越界() {
        let merged = WebSearch.interleave(
            [0: [hit("https://a1")],
             1: [hit("https://b1"), hit("https://b2"), hit("https://b3")]],
            order: 0..<2)
        XCTAssertEqual(merged.map(\.url), ["https://a1", "https://b1", "https://b2", "https://b3"])
    }

    /// 去重的归一化：scheme 与末尾斜杠不计，但**大小写要保留**——
    /// 路径在多数服务器上区分大小写，一并小写会把两个不同页面误判成同一个
    func testURL归一化() {
        XCTAssertEqual(WebSearch.canonicalURL("https://e.com/a/"), WebSearch.canonicalURL("http://e.com/a"))
        XCTAssertEqual(WebSearch.canonicalURL("https://e.com/a///"), "e.com/a")
        XCTAssertNotEqual(WebSearch.canonicalURL("https://e.com/A"), WebSearch.canonicalURL("https://e.com/a"))
        XCTAssertEqual(WebSearch.canonicalURL("https://e.com/"), "e.com")
        // 全是斜杠时不能归一成空串，否则两个不同站点会撞成一个
        XCTAssertFalse(WebSearch.canonicalURL("https://").isEmpty)
    }

    // MARK: - 补抓正文

    /// Tavily 自带 raw_content，不能再抓一遍把它覆盖掉——既白等一次网络，
    /// 又可能抓得比它给的更差
    func test已有正文的条目不会被重抓覆盖() async {
        // .invalid 是 RFC 2606 保留的顶级域，DNS 一定解析不出来，
        // 抓取会在地址校验那一步就快速失败，不会真的等满 8 秒超时
        var results = [
            SearchResult(title: "t1", url: "https://nowhere.invalid/a",
                         highlights: "片段", body: "Tavily 给的整页正文"),
            SearchResult(title: "t2", url: "https://nowhere.invalid/b", highlights: "片段"),
        ]
        await WebSearch.fillBodies(&results)
        XCTAssertEqual(results[0].body, "Tavily 给的整页正文", "自带的正文被覆盖了")
        XCTAssertTrue(results[1].body.isEmpty, "抓不到就保持空，由相关片段兜底")
    }

    /// 空结果不能把索引算越界
    func test空结果补抓不崩() async {
        var empty: [SearchResult] = []
        await WebSearch.fillBodies(&empty)
        XCTAssertTrue(empty.isEmpty)
    }

    /// 抓取名单的长度跟着「能进提示词的条数」走，不是另一个写死的数。
    ///
    /// 原来写死 4，而 maxDocuments 是 8：排在第 5 到 8 的入选来源永远只有一句摘要
    func test抓取上限与提示词条数上限一致() {
        XCTAssertEqual(WebSearch.maxDocuments, 8)
    }

    // MARK: - 规划器的判据

    /// 时效判据看的必须是「答案会不会随时间变」，不是「问句里有没有时效词」。
    ///
    /// 由来（大梁老师 2026-08-07 的实例）：「千问办公和 QoderWork 有什么区别」
    /// 一个时效词都没有，读上去像稳定的对比题，可那产品 2026-08-03 才公测——
    /// 答案全在四天前的新闻里。按旧判据填 null、全时段搜，新页面根本排不上来
    func test时效判据按答案是否会变而非问句措辞() {
        let prompt = ChatStore.plannerSystemPrompt()
        XCTAssertTrue(prompt.contains("答案会不会随时间变"))
        XCTAssertFalse(prompt.contains("问题涉及时效（最新/近期/今年/现在）时填"),
                       "旧的措辞判据必须换掉")
        XCTAssertTrue(prompt.contains("拿不准就填 year"),
                      "得给个够宽的默认档，限太紧会把背景资料一起滤掉")
    }

    /// 「我不认识这个名字」是规划器手上最强的时效证据——
    /// 它的知识本身有截止日期，没听说过多半就是训练之后才出现的
    func test不认识的名字要判定为需要联网() {
        let prompt = ChatStore.plannerSystemPrompt()
        XCTAssertTrue(prompt.contains("出现你不认识的名字就填 true"))
        XCTAssertTrue(prompt.contains("凭印象答一定是错的"))
    }

    /// 原有判据不能在改时效的时候被顺手删掉
    func test规划器仍然保留原有判据() {
        let prompt = ChatStore.plannerSystemPrompt()
        XCTAssertTrue(prompt.contains("拿不准就填 true"))
        XCTAssertTrue(prompt.contains("把上面那段改短"), "基于已有内容的加工不该联网")
        XCTAssertTrue(prompt.contains("只输出 JSON 本身，不要围栏、不要解释"))
    }
}
