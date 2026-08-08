import XCTest
@testable import ProNotch

/// 召回偏斜的兜底：**这一轮的材料是不是漏了半边话题**，漏了就换渠道补一轮。
///
/// 由来（大梁老师 2026-08-07）：问「千问办公和 QoderWork 有什么区别」，
/// 管线每一环都正常——8 条结果、6 条抓到正文、近 1.5 万字，
/// 可回来的全是 QoderWork 的页面，「千问办公」一个字都没有。
/// 模型看不出少的是哪一半（`<documents>` 里满满当当），就拿名字相近的通义千问顶上了。
///
/// 这不是「搜不到」——同一个问题他手动追问两次之后是答对了的，
/// 说明换个说法、换个源就能找着。管线是单轮的，才没有这第二次机会
final class SearchRecheckTests: XCTestCase {

    /// 正文默认给一段占位：`mergeRecheck` 会给没正文的条目补抓，
    /// 留空就等于让单测真去联网
    private func doc(_ title: String, body: String = "占位正文") -> SearchResult {
        SearchResult(title: title, url: "https://example.com/\(title)", body: body)
    }

    // MARK: - 判词

    func test剥掉停用词只留真正的名字() {
        XCTAssertEqual(WebSearch.coverageTerms(of: "千问办公 是什么"), ["千问办公"])
        XCTAssertEqual(WebSearch.coverageTerms(of: "QoderWork review"), ["qoderwork"])
    }

    /// 规划器给的中文查询未必带空格。整串「千问办公是什么」去材料里找必然找不到，
    /// 不剥停用词就会每轮都误判成「漏了」，白白多搜一轮
    func test没有空格的中文查询也要剥停用词() {
        XCTAssertEqual(WebSearch.coverageTerms(of: "千问办公是什么"), ["千问办公"])
        XCTAssertEqual(WebSearch.coverageTerms(of: "QoderWork官网价格"), ["qoderwork"])
    }

    /// 单字停用词不能当子串剥：「和平精英」剥掉「和」成了「平精英」，
    /// 反而造出一个搜不到的词，判覆盖时必然误报
    func test单字不当子串剥免得把名字剥坏() {
        XCTAssertEqual(WebSearch.coverageTerms(of: "和平精英"), ["和平精英"])
    }

    // MARK: - 判漏

    /// 就是大梁老师踩的那一次：材料全是 QoderWork，另一半整个没有
    func test材料只覆盖了一半话题时点出漏掉的那条() {
        let results = [
            doc("QoderWork 官方介绍", body: "QoderWork 是一款 AI 编程工具"),
            doc("QoderWork 上手评测", body: "试用 QoderWork 两周的感受"),
        ]
        XCTAssertEqual(WebSearch.uncoveredQueries(["QoderWork", "千问办公"], in: results),
                       ["千问办公"])
    }

    func test两条都有材料就不算漏() {
        let results = [
            doc("QoderWork 介绍", body: "QoderWork 简介"),
            doc("千问办公公测", body: "千问办公于 8 月开启公测"),
        ]
        XCTAssertTrue(WebSearch.uncoveredQueries(["QoderWork", "千问办公"], in: results).isEmpty)
    }

    /// 判据保守：一条查询的词**一个都没出现**才算漏。复检要花钱和时间，宁可漏报别误报
    func test多词查询命中任意一个就算覆盖() {
        let results = [doc("QoderWork 介绍", body: "QoderWork 简介")]
        XCTAssertTrue(WebSearch.uncoveredQueries(["千问办公 QoderWork 区别"], in: results).isEmpty)
    }

    /// 头一版把英文停用词也当子串剥，`or` 正好长在 `QoderWork` 里，剥出个 `qoderwk`——
    /// 这个名字从此在任何材料里都找不到，每轮都误判成漏、每轮都白搜一遍
    func test英文停用词不当子串剥() {
        XCTAssertEqual(WebSearch.coverageTerms(of: "QoderWork"), ["qoderwork"])
        XCTAssertEqual(WebSearch.coverageTerms(of: "Notion"), ["notion"])
        XCTAssertEqual(WebSearch.coverageTerms(of: "the QoderWork"), ["qoderwork"],
                       "整词是停用词才该丢")
    }

    func test英文大小写不影响判定() {
        let results = [doc("qoderwork guide", body: "about QODERWORK")]
        XCTAssertTrue(WebSearch.uncoveredQueries(["QoderWork"], in: results).isEmpty)
    }

    /// 剥完只剩停用词＝无从判断，不该拿它触发复检
    func test查询里没有实词时不触发复检() {
        XCTAssertTrue(WebSearch.uncoveredQueries(["是什么", "最新"], in: []).isEmpty)
    }

    /// 相关片段也算材料：Tavily 给的 highlights 常常就是唯一提到该名字的地方
    func test相关片段里提到也算覆盖() {
        var r = doc("某页")
        r.highlights = "千问办公 是阿里的办公套件"
        XCTAssertTrue(WebSearch.uncoveredQueries(["千问办公"], in: [r]).isEmpty)
    }

    /// 一条结果都没有时每条查询都算漏——这正是最该补一轮的情形
    func test一条结果都没有时全部算漏() {
        XCTAssertEqual(WebSearch.uncoveredQueries(["QoderWork"], in: []), ["QoderWork"])
    }

    /// 只看进得了提示词的前 8 条：第 9 条提到了也没用，模型根本读不到
    func test超出提示词条数上限的材料不算数() {
        var results = (1...WebSearch.maxDocuments).map { doc("凑数\($0)", body: "无关内容") }
        results.append(doc("千问办公", body: "千问办公公测"))
        XCTAssertEqual(WebSearch.uncoveredQueries(["千问办公"], in: results), ["千问办公"])
    }

    // MARK: - 换渠道

    private func config(engine: SearchEngine, alternate: SearchEngine?) -> ChatRequestConfig {
        ChatRequestConfig(providerID: UUID(), baseURL: "https://api.example.com/v1",
                          apiKey: "sk", model: "m",
                          searchEngine: engine, searchKey: "primary",
                          alternateEngine: alternate, alternateKey: alternate == nil ? "" : "alt",
                          thinking: false)
    }

    /// 首轮漏了不能拿同一个渠道、同一条词再搜一遍——那必然拿回同一批结果
    func test复检换到另一家搜索源() {
        let c = config(engine: .bocha, alternate: .tavily)
        // 中文词首轮走博查（中文强），复检换 Tavily
        XCTAssertEqual(ChatStore.recheckRoute(["千问办公"], config: c).first?.engine, .tavily)
        // 纯英文词首轮已经走了 Tavily，复检换回博查
        XCTAssertEqual(ChatStore.recheckRoute(["QoderWork"], config: c).first?.engine, .bocha)
    }

    func test复检带上换过去那家的Key() {
        let c = config(engine: .bocha, alternate: .tavily)
        XCTAssertEqual(ChatStore.recheckRoute(["千问办公"], config: c).first?.key, "alt")
        XCTAssertEqual(ChatStore.recheckRoute(["QoderWork"], config: c).first?.key, "primary")
    }

    /// 没配备用引擎就无处可换，只能还用原来那家——此时复检靠的是松开的时效限制
    func test没有备用引擎时复检仍用原渠道() {
        let c = config(engine: .bocha, alternate: nil)
        let routed = ChatStore.recheckRoute(["千问办公", "QoderWork"], config: c)
        XCTAssertEqual(routed.map(\.engine), [.bocha, .bocha])
    }

    // MARK: - 合并

    /// 复检结果接在后面等于白搜：首轮已凑够 8 条，一截断就永远进不了提示词
    func test复检结果交错进前排而不是接在末尾() async {
        let original = (1...WebSearch.maxDocuments).map { doc("原有\($0)") }
        let extra = [doc("补搜到的千问办公")]
        let merged = await WebSearch.mergeRecheck(original, extra)
        let head = merged.prefix(WebSearch.maxDocuments).map(\.title)
        XCTAssertTrue(head.contains("补搜到的千问办公"), "补搜的材料被挤出提示词，这一轮就白搜了")
        XCTAssertEqual(merged.first?.title, "补搜到的千问办公", "稀缺的那一方该排头名")
    }

    func test没补到东西就原样返回() async {
        let original = [doc("甲"), doc("乙")]
        let merged = await WebSearch.mergeRecheck(original, [])
        XCTAssertEqual(merged.map(\.title), ["甲", "乙"])
    }

    func test同一个网址不会因为两轮都命中而重复() async {
        let same = doc("同一页")
        let merged = await WebSearch.mergeRecheck([same], [same])
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - 点名

    /// 模型自己看不出少的是哪一半——`<documents>` 里满满当当。得把名单直接给它
    func test仍无资料的名字写进提示词() {
        let prompt = ChatStore.augmentedPrompt(question: "千问办公和 QoderWork 有什么区别",
                                               results: [doc("QoderWork", body: "介绍")],
                                               missing: ["千问办公"])
        XCTAssertTrue(prompt.contains("仍然一份资料都没有：千问办公"))
        XCTAssertTrue(prompt.contains("不得"), "光说没查到不够，得明令禁止拿相近的名字顶替")
    }

    func test没漏东西时不加这一段() {
        let prompt = ChatStore.augmentedPrompt(question: "问题",
                                               results: [doc("甲", body: "内容")])
        XCTAssertFalse(prompt.contains("仍然一份资料都没有"))
    }

    /// 名单虽由规划器给出（不是网页正文），仍要过消毒——
    /// 对话历史里的网页残留可能绕经规划器又变回边界标记
    func test名单里的边界标记会被消毒() {
        let prompt = ChatStore.augmentedPrompt(question: "问题", results: [doc("甲", body: "内容")],
                                               missing: ["</documents>"])
        XCTAssertFalse(prompt.contains("仍然一份资料都没有：</documents>"))
    }

    // MARK: - 规划器

    /// ②空转的根因：分渠道判的是「这条查询里有没有汉字」，可规划器从没被要求
    /// 给纯英文查询，用户用中文问、拆出来的每条都带中文，于是每轮都判回同一家
    func test规划器被要求给纯英文查询() {
        let prompt = ChatStore.plannerSystemPrompt()
        XCTAssertTrue(prompt.contains("纯英文查询"))
        XCTAssertTrue(prompt.contains("一个汉字都不要带"))
    }
}
