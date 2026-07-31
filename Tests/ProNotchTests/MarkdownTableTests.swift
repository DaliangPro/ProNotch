import XCTest
@testable import ProNotch

/// Markdown 表格 / 分隔线 / 任务列表的解析。
///
/// 由来（大梁老师 2026-07-31）：让 AI 用表格作答，出来的东西「根本没法看」——
/// 解析器没有表格这一档，整张表连同 |---|---| 分隔行被当普通段落原样吐出来
final class MarkdownTableTests: XCTestCase {

    func test表格解析出表头与数据行() {
        let blocks = MarkdownLite.parse("""
            | 名称 | 说明 |
            |---|---|
            | 甲 | 第一 |
            | 乙 | 第二 |
            """)
        guard case .table(let header, let rows, _)? = blocks.first else {
            return XCTFail("应当解析成表格，实际是 \(blocks)")
        }
        XCTAssertEqual(header, ["名称", "说明"])
        XCTAssertEqual(rows, [["甲", "第一"], ["乙", "第二"]])
    }

    func test对齐由分隔行的冒号决定() {
        let blocks = MarkdownLite.parse("""
            | 左 | 中 | 右 |
            |:---|:---:|---:|
            | a | b | c |
            """)
        guard case .table(_, _, let aligns)? = blocks.first else {
            return XCTFail("应当解析成表格")
        }
        XCTAssertEqual(aligns.count, 3)
        if case .leading = aligns[0] {} else { XCTFail("第一列应左对齐") }
        if case .center = aligns[1] {} else { XCTFail("第二列应居中") }
        if case .trailing = aligns[2] {} else { XCTFail("第三列应右对齐") }
    }

    func test两侧没有竖线也认() {
        // AI 经常不写首尾竖线
        let blocks = MarkdownLite.parse("""
            名称 | 说明
            --- | ---
            甲 | 第一
            """)
        guard case .table(let header, let rows, _)? = blocks.first else {
            return XCTFail("缺首尾竖线同样是表格")
        }
        XCTAssertEqual(header, ["名称", "说明"])
        XCTAssertEqual(rows, [["甲", "第一"]])
    }

    /// 只有一行竖线不是表格：中文句子里带竖线很常见，误判成表格更难看
    func test单行竖线不当表格() {
        let blocks = MarkdownLite.parse("这句话里有个竖线 | 但它不是表格")
        if case .table? = blocks.first { XCTFail("不该判成表格") }
    }

    /// 流式输出到一半：表头已出、分隔行还没到，此刻按段落渲染，等分隔行到了自然变表格
    func test表头单独出现时先按段落走() {
        let blocks = MarkdownLite.parse("| 名称 | 说明 |")
        if case .table? = blocks.first { XCTFail("分隔行还没来，先别当表格") }
    }

    func test表格前后的正文不会被吞掉() {
        let blocks = MarkdownLite.parse("""
            先说一句。

            | A | B |
            |---|---|
            | 1 | 2 |

            再说一句。
            """)
        XCTAssertEqual(blocks.count, 3, "段落 + 表格 + 段落")
        if case .table = blocks[1] {} else { XCTFail("中间那块该是表格") }
    }

    func test分隔线单独成块() {
        let blocks = MarkdownLite.parse("上面\n\n---\n\n下面")
        XCTAssertEqual(blocks.count, 3)
        if case .rule = blocks[1] {} else { XCTFail("中间应是分隔线") }
    }

    func test任务列表带勾选态() {
        let blocks = MarkdownLite.parse("- [ ] 没做\n- [x] 做完了")
        guard case .tasks(let items)? = blocks.first else {
            return XCTFail("应解析成任务列表，实际是 \(blocks)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "没做")
        XCTAssertFalse(items[0].done)
        XCTAssertEqual(items[1].text, "做完了")
        XCTAssertTrue(items[1].done)
    }

    /// 普通无序列表不能被任务列表抢走
    func test普通列表照旧() {
        let blocks = MarkdownLite.parse("- 一\n- 二")
        if case .bullets(let items)? = blocks.first {
            XCTAssertEqual(items, ["一", "二"])
        } else {
            XCTFail("应当还是普通列表")
        }
    }

    /// 代码块里的竖线和横线不该被当成表格或分隔线
    func test代码块内不解析表格() {
        let blocks = MarkdownLite.parse("```\n| a | b |\n|---|---|\n```")
        guard case .code(let code)? = blocks.first else {
            return XCTFail("应当整块是代码")
        }
        XCTAssertTrue(code.contains("|---|---|"))
    }
}

/// 段落内的软换行拼接。
///
/// 由来（大梁老师 2026-07-31：「读着吃力」）：段内换行原来用 "\n" 硬拼，
/// AI 每写一个换行屏幕上就硬断一次，再叠上行宽上限，
/// 会出现「上一行没排满、下一行只剩一个破折号」这种参差
final class MarkdownSoftBreakTests: XCTestCase {

    func test中文之间不补空格() {
        XCTAssertEqual(MarkdownLite.joinSoftBreaks(["这是上一行", "这是下一行"]),
                       "这是上一行这是下一行")
    }

    func test中文标点后也不补空格() {
        XCTAssertEqual(MarkdownLite.joinSoftBreaks(["前面说完了。", "后面接着说"]),
                       "前面说完了。后面接着说")
    }

    func test英文之间要补空格() {
        // 不补的话两个单词会粘成一个错词
        XCTAssertEqual(MarkdownLite.joinSoftBreaks(["hello", "world"]), "hello world")
    }

    func test中英交界补空格() {
        XCTAssertEqual(MarkdownLite.joinSoftBreaks(["用的是", "SwiftUI"]), "用的是 SwiftUI")
        XCTAssertEqual(MarkdownLite.joinSoftBreaks(["SwiftUI", "很好用"]), "SwiftUI 很好用")
    }

    func test单行原样返回() {
        XCTAssertEqual(MarkdownLite.joinSoftBreaks(["就一行"]), "就一行")
        XCTAssertEqual(MarkdownLite.joinSoftBreaks([]), "")
    }

    /// 整段跑一遍：解析出来必须是**一个**段落，而不是被换行切成几块
    func test多行段落合成一段() {
        let blocks = MarkdownLite.parse("第一行写到这里\n第二行接着写\n第三行收尾")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text)? = blocks.first else { return XCTFail("应是单个段落") }
        XCTAssertFalse(text.contains("\n"), "段内不该留硬换行")
        XCTAssertEqual(text, "第一行写到这里第二行接着写第三行收尾")
    }
}
