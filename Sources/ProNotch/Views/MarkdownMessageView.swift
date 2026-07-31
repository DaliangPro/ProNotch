import SwiftUI

/// 轻量 Markdown 渲染（AI 回复用）：支持标题、无序/有序列表、围栏代码块、
/// 引用，行内加粗/斜体/代码/链接交给系统 AttributedString 解析。
/// 无第三方依赖，流式输出时按块增量重排
enum MarkdownLite {
    enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([String])
        case ordered([String])
        case code(String)
        case quote(String)
        /// 表格。AI 拿表格答题很常见，不解析的话竖线会连同分隔行一起原样吐出来，
        /// 那正是大梁老师说「根本没法看」的东西（2026-07-31）
        case table(header: [String], rows: [[String]], aligns: [Align])
        /// 任务列表（- [ ] / - [x]）
        case tasks([(text: String, done: Bool)])
    }

    /// 表格列对齐：由分隔行的冒号决定（:--- 左 / :---: 居中 / ---: 右）
    enum Align {
        case leading, center, trailing
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var quote: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(joinSoftBreaks(paragraph)))
                paragraph = []
            }
        }
        func flushLists() {
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets))
                bullets = []
            }
            if !ordered.isEmpty {
                blocks.append(.ordered(ordered))
                ordered = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushLists()
            flushQuote()
            flushTasksHook?()
        }
        /// flushTasks 定义在下面（要用到 lines 循环里的状态），这里留个钩子给它接上
        var flushTasksHook: (() -> Void)?

        let lines = text.components(separatedBy: "\n")
        var index = 0
        var tasks: [(text: String, done: Bool)] = []

        func flushTasks() {
            if !tasks.isEmpty { blocks.append(.tasks(tasks)); tasks = [] }
        }
        flushTasksHook = flushTasks

        while index < lines.count {
            let rawLine = lines[index]
            index += 1
            if rawLine.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushAll()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushAll()
                continue
            }
            // 表格要往下看一行才认得出来（首行是表头，紧跟的必须是 |---|---| 分隔行），
            // 所以整个解析改成带下标的循环。只有一行竖线不算表格，那多半是普通句子
            if let cells = parseTableRow(line), index < lines.count,
               let sep = parseTableRow(lines[index].trimmingCharacters(in: .whitespaces)),
               isTableSeparator(sep) {
                flushAll()
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let row = parseTableRow(next) else { break }
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(header: cells, rows: rows, aligns: sep.map(alignment(of:))))
                continue
            }
            // 分隔线**识别但不渲染**（大梁老师 2026-07-31 定）。
            //
            // 标题已有明确层级、段落间距也拉开了，再画一条线就是同一件事说三遍，
            // 反而把版面切碎。DeepSeek 写中文长答案时习惯每节之间来一条 `---`，
            // 全画出来就成了「每段中间都有线」。
            //
            // 但**必须继续识别**：不识别的话 `---` 会掉进段落，原样显示成三个横杠。
            // 这里只当作一次分段（flushAll），不产出任何块——产出空块的话
            // VStack 会多算一次 spacing，原地留下一道可疑的大空档
            if isRule(line) {
                flushAll()
                continue
            }
            if let task = parseTask(line) {
                flushParagraph()
                flushLists()
                flushQuote()
                tasks.append(task)
                continue
            }
            if let heading = parseHeading(line) {
                flushAll()
                blocks.append(.heading(level: heading.0, text: heading.1))
            } else if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                flushLists()
                quote.append(String(line.dropFirst(line == ">" ? 1 : 2)))
            } else if let item = parseBullet(line) {
                flushParagraph()
                flushQuote()
                bullets.append(item)
            } else if let item = parseOrdered(line) {
                flushParagraph()
                flushQuote()
                ordered.append(item)
            } else {
                flushLists()
                flushQuote()
                paragraph.append(line)
            }
        }
        if inCode, !codeLines.isEmpty {
            // 流式输出中代码块尚未闭合，先按代码渲染
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// 段落内的换行是**软换行**：按 Markdown 的规矩等同一个空格，不该硬切一行。
    ///
    /// 原来直接用 "\n" 拼，AI 每写一个换行就在屏幕上硬断一次；再叠上行宽上限，
    /// 就会出现「上一行没排满、下一行只剩一个破折号」这种参差（2026-07-31 拍图看出来的）。
    ///
    /// 中英混排要分别对待：两边都是中日韩字符时直接接上（中文之间不该冒出空格），
    /// 否则补一个空格（英文单词粘在一起会连成错词）
    static func joinSoftBreaks(_ lines: [String]) -> String {
        guard var result = lines.first else { return "" }
        for line in lines.dropFirst() {
            let left = result.last
            let right = line.first
            let bothCJK = left.map(isCJK) == true && right.map(isCJK) == true
            result += (bothCJK ? "" : " ") + line
        }
        return result
    }

    /// 中日韩字符（含常用标点），用来决定拼接时要不要补空格
    private static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,   // 中文标点
             0x3040...0x30FF,   // 日文假名
             0x4E00...0x9FFF,   // 汉字
             0xFF00...0xFFEF:   // 全角字符
            return true
        default:
            return false
        }
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// 一行表格：`| a | b |` → ["a", "b"]。两侧竖线可有可无（AI 有时不写）
    static func parseTableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return cells.count >= 2 ? cells : nil
    }

    /// 分隔行：每格只由 - 和 : 组成且至少有一个 -
    static func isTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let t = cell.replacingOccurrences(of: " ", with: "")
            return t.contains("-") && t.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func alignment(of separatorCell: String) -> Align {
        let t = separatorCell.replacingOccurrences(of: " ", with: "")
        if t.hasPrefix(":"), t.hasSuffix(":") { return .center }
        if t.hasSuffix(":") { return .trailing }
        return .leading
    }

    /// 水平分隔线：整行只有 3 个以上的 - / * / _
    static func isRule(_ line: String) -> Bool {
        let t = line.replacingOccurrences(of: " ", with: "")
        guard t.count >= 3 else { return false }
        return t.allSatisfy { $0 == "-" } || t.allSatisfy { $0 == "*" } || t.allSatisfy { $0 == "_" }
    }

    /// 任务项：`- [ ] 待办` / `- [x] 已办`
    static func parseTask(_ line: String) -> (text: String, done: Bool)? {
        guard let item = parseBullet(line) else { return nil }
        let lower = item.lowercased()
        if lower.hasPrefix("[ ] ") { return (String(item.dropFirst(4)), false) }
        if lower.hasPrefix("[x] ") { return (String(item.dropFirst(4)), true) }
        return nil
    }

    private static func parseBullet(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func parseOrdered(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(where: { $0 == "." || $0 == "、" }),
              line.startIndex < dotIndex,
              line[line.startIndex..<dotIndex].allSatisfy(\.isNumber),
              line.index(after: dotIndex) < line.endIndex else { return nil }
        return line[line.index(after: dotIndex)...]
            .trimmingCharacters(in: .whitespaces)
    }

    /// 行内 Markdown（加粗/斜体/行内代码/链接）解析，失败退回纯文本。
    ///
    /// **加粗要同时变亮**（大梁老师 2026-07-31：「字重没有分级，都太一致了」）。
    /// 原来只把 `**重点**` 渲成粗体、颜色与正文一模一样——中文粗体本就比西文含蓄，
    /// 同一个白下几乎看不出差别，AI 标出来的重点等于白标。
    /// 层级得靠**字号 + 字重 + 明度**三样一起分：这里管后两样，
    /// 正文压到 0.76 的白，加粗提到纯白 + bold，一眼就能扫到
    static func inline(_ text: String, size: CGFloat,
                       weight: Font.Weight = .regular,
                       emphasisWeight: Font.Weight = .semibold,
                       base: Color = .white.opacity(0.82),
                       emphasis: Color = .white) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        attributed.font = .system(size: size, weight: weight)
        attributed.foregroundColor = base

        // 先收集区间再改：边遍历 runs 边改属性会让迭代器失效
        var strong: [Range<AttributedString.Index>] = []
        var codes: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.stronglyEmphasized) { strong.append(run.range) }
            if intent.contains(.code) { codes.append(run.range) }
        }
        for range in strong {
            attributed[range].font = .system(size: size, weight: emphasisWeight)
            attributed[range].foregroundColor = emphasis
        }
        for range in codes {
            attributed[range].font = .system(size: size - 0.5, design: .monospaced)
            attributed[range].foregroundColor = emphasis
        }
        return attributed
    }
}

/// AI 回复的排版度量。**所有值都从正文字号推**，不再一处一个魔法数字。
///
/// 由来（大梁老师 2026-07-31：「字重、字号、间距整体再想一遍，读着吃力」）：
/// 之前是逐条打补丁——字号写死过、行距写死过、标题比正文还小过。
/// 每修一处只解决一处，整体仍然不成体系。这里把它们收成一份可推导的表。
///
/// 两档形态：刘海是一条窄带，塞得下才是第一位；独立窗口是拿来读长文的，按阅读舒适度定
struct MarkdownTypography {
    /// 正文字号（刘海 12 / 窗口 16）。窗口的 16 与行高 1.7 出自重构任务书 §7
    var body: CGFloat = 12
    /// 紧凑档（刘海）。窗口用舒适档
    var compact: Bool = true

    /// 行距。中文方块字密度高，行高不到 1.6 倍就发闷；
    /// SwiftUI 的 lineSpacing 是**在默认行高之上再加**，所以取 0.5 倍字号
    /// 行高目标 1.7 倍（任务书 §7）。SwiftUI 的 lineSpacing 是**在默认行高之上再加**，
    /// PingFang 默认约 1.2 倍，所以补 0.5 倍字号
    var lineSpacing: CGFloat { compact ? 1 : body * 0.5 }

    /// 段落之间。任务书 §7：段落底部间距 14（正文 16 时约 0.875 倍）
    var blockSpacing: CGFloat { compact ? body * 0.5 : body * 0.875 }

    /// 标题**上疏下密**：上面留够才看得出它领起新一段，
    /// 下面收紧才与自己统辖的正文成组。上下一样多的话，标题会浮在两段中间谁也不挨。
    /// 任务书 §7：上 22–26、下 10–12（正文 16 时约 1.5 倍与 0.7 倍）
    var headingTop: CGFloat { compact ? body * 0.3 : body * 1.5 }
    var headingBottom: CGFloat { compact ? 0 : body * 0.65 }

    /// 标题字号。任务书 §7 定的是 22 / 19 / 17（正文 16），即 +6 / +3 / +1
    func heading(_ level: Int) -> CGFloat {
        body + (level <= 1 ? 6 : (level == 2 ? 3 : 1))
    }

    /// 标题字重：H1/H2 约 650、H3 约 600（任务书 §7）。
    /// SwiftUI 没有 650 这一档，semibold(600) 与 bold(700) 之间取 semibold 更接近
    func headingWeight(_ level: Int) -> Font.Weight { level <= 2 ? .bold : .semibold }

    /// 任务书 §7：列表项间距 6–8，缩进 1.35–1.5em
    var listItemSpacing: CGFloat { compact ? 3 : body * 0.44 }
    var markerGap: CGFloat { compact ? 6 : body * 0.4 }

    /// 正文一行最多多宽。**这是读着吃不吃力的头号变量**：
    /// 中文一行超过 40 字，回行时极易串行。任务书 §6.4 定的上限是 760pt，
    /// 按正文 16 折算约 47 字——取两者中更稳的 760。
    /// 只管散文（段落/列表/引用），表格和代码不受限——它们本来就该横着铺
    var proseWidth: CGFloat? { compact ? nil : 760 }

    /// 气泡内边距：正文越大，四周越要留得开
    var bubbleH: CGFloat { compact ? 10 : body * 1.15 }
    var bubbleV: CGFloat { compact ? 6 : body * 0.8 }

    /// 两条消息之间
    var messageSpacing: CGFloat { compact ? 6 : body * 1.7 }

    // MARK: - 字重
    //
    // 之前只有 regular / semibold / bold 三档，最细的一档缺席，
    // 满屏都是「粗和中等」（大梁老师 2026-07-31）。
    // 深色底上文字有光晕，看起来本就比浅色底显粗——Apple 的深色模式建议正是
    // 「考虑用更细的字重」。所以窗口正文走 light，靠加粗和标题去顶上面那几档。
    //
    // 刘海不跟：那儿字号只有 12，再细就发虚了

    /// 正文。任务书 §7 定的是 400（regular），照它走之后大梁老师觉得偏粗，
    /// 改回 light（2026-07-31 复议）。
    /// 刘海不跟：那儿正文只有 12pt，再细就发虚
    var bodyWeight: Font.Weight { compact ? .regular : .light }
    /// 行内加粗。用 semibold 而不是 bold——bold 留给标题，两者才分得开
    var emphasisWeight: Font.Weight { compact ? .semibold : .semibold }
    /// 次级信息（引用、项目符号、任务项）：跟正文同一档，靠明度再退一步
    var secondaryWeight: Font.Weight { compact ? .regular : .light }
    /// 表头。表格里不必喊，medium 足够把它和数据行分开
    var tableHeaderWeight: Font.Weight { compact ? .semibold : .medium }

    /// 正文颜色。任务书 §5.1 的 `--qc-text-primary` 是 0.92
    var bodyColor: Color { .white.opacity(compact ? 0.9 : 0.92) }
    /// 元信息 / 次要按钮（`--qc-text-secondary`）
    static let textSecondary = Color.white.opacity(0.64)
    /// Placeholder / 禁用（`--qc-text-tertiary`）
    static let textTertiary = Color.white.opacity(0.42)
}

struct MarkdownMessageView: View {
    let text: String

    /// 整套排版度量。字号、行距、段距、标题层级、行宽全从它推——
    /// 调一个地方，整篇跟着走（见 `MarkdownTypography`）
    var type = MarkdownTypography()

    private var fontSize: CGFloat { type.body }

    var body: some View {
        let blocks = MarkdownLite.parse(text)
        VStack(alignment: .leading, spacing: type.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    /// 散文（段落/标题/列表/引用）限最大行宽，表格与代码不限——
    /// 前者是拿来读的，后者本来就该横着铺
    @ViewBuilder
    private func prose<V: View>(_ view: V) -> some View {
        if let width = type.proseWidth {
            view.frame(maxWidth: width, alignment: .leading)
        } else {
            view
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownLite.Block) -> some View {
        switch block {
        case .paragraph(let text):
            prose(Text(MarkdownLite.inline(text, size: fontSize,
                                           weight: type.bodyWeight,
                                           emphasisWeight: type.emphasisWeight,
                                           base: type.bodyColor))
                .lineSpacing(type.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true))
        case .heading(let level, let text):
            // 字号必须**从正文推**，不能写死。原来是 15/14/13：窗口正文 14 的时候
            // H2 跟正文一样大、H3 比正文还小，等于没有标题——大梁老师说「一大坨字没重点」
            // 有一半是这么来的（2026-07-31）
            prose(Text(MarkdownLite.inline(text, size: type.heading(level),
                                           weight: type.headingWeight(level),
                                           emphasisWeight: type.headingWeight(level),
                                           base: .white, emphasis: .white))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // 上疏下密：标题与它统辖的正文成一组
                .padding(.top, type.headingTop)
                .padding(.bottom, type.headingBottom))
        case .bullets(let items):
            prose(listView(items) { _ in "•" })
        case .ordered(let items):
            prose(listView(items) { "\($0 + 1)." })
        case .code(let code):
            Text(code)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundColor(.white.opacity(0.88))
                .textSelection(.enabled)
                // 滚动容器测量时可能压缩 Text 高度导致截断，固定纵向自适应
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.4)))
        case .quote(let text):
            prose(HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 2)
                Text(MarkdownLite.inline(text, size: fontSize,
                                         weight: type.secondaryWeight,
                                         base: .white.opacity(0.55),
                                         emphasis: .white.opacity(0.85)))
                    .lineSpacing(type.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            })
        case .table(let header, let rows, let aligns):
            tableView(header: header, rows: rows, aligns: aligns)
        case .tasks(let items):
            prose(VStack(alignment: .leading, spacing: type.listItemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .font(.system(size: fontSize - 1))
                            .foregroundColor(.white.opacity(item.done ? 0.75 : 0.4))
                        Text(MarkdownLite.inline(item.text, size: fontSize,
                                                 weight: type.secondaryWeight,
                                                 emphasisWeight: type.emphasisWeight,
                                                 base: .white.opacity(item.done ? 0.45 : 0.82)))
                            .strikethrough(item.done, color: .white.opacity(0.35))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            })
        }
    }

    /// 表格里的一格。单独抽出来是因为写在 Grid 里内联，编译器推类型会超时
    private func tableCell(_ text: String, align: Alignment, isHeader: Bool) -> some View {
        let size = fontSize - 0.5
        let attributed = isHeader
            ? MarkdownLite.inline(text, size: size, weight: type.tableHeaderWeight,
                                  emphasisWeight: type.tableHeaderWeight,
                                  base: .white, emphasis: .white)
            : MarkdownLite.inline(text, size: size, weight: type.bodyWeight,
                                  emphasisWeight: type.emphasisWeight,
                                  base: type.bodyColor)
        return Text(attributed)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: align)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 表格：表头一行 + 细横线 + 数据行。
    ///
    /// 用 Grid 而不是 HStack 拼：各列宽度要由整张表最宽的那格决定，
    /// 一行一行摆出来的「表格」列根本对不齐。
    /// 单元格里的文字照常换行（fixedSize 只锁纵向），窄窗口下不会被裁掉
    private func tableView(header: [String], rows: [[String]],
                           aligns: [MarkdownLite.Align]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        func align(_ i: Int) -> Alignment {
            switch aligns.indices.contains(i) ? aligns[i] : .leading {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
        func cell(_ list: [String], _ i: Int) -> String {
            list.indices.contains(i) ? list[i] : ""
        }
        return VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { i in
                        tableCell(cell(header, i), align: align(i), isHeader: true)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal).overlay(Color.white.opacity(0.22))
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { i in
                            tableCell(cell(row, i), align: align(i), isHeader: false)
                        }
                    }
                    // 行间细线，最后一行不画（下面已经是表格外框）
                    if index < rows.count - 1 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                            .overlay(Color.white.opacity(0.10))
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .textSelection(.enabled)
    }

    private func listView(_ items: [String],
                          marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: type.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: type.markerGap) {
                    // 项目符号压到 0.35：它是路标不是内容，跟正文一样亮会抢注意力
                    Text(marker(index))
                        .font(.system(size: fontSize, weight: type.secondaryWeight))
                        .foregroundColor(.white.opacity(0.35))
                    Text(MarkdownLite.inline(item, size: fontSize,
                                             weight: type.bodyWeight,
                                             emphasisWeight: type.emphasisWeight,
                                             base: type.bodyColor))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
