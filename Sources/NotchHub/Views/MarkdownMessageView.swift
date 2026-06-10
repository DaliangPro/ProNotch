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
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
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
        }

        for rawLine in text.components(separatedBy: "\n") {
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

    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
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

    /// 行内 Markdown（加粗/斜体/行内代码/链接）解析，失败退回纯文本
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownLite.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownLite.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownLite.inline(text))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(MarkdownLite.inline(text))
                .font(.system(size: level <= 1 ? 15 : (level == 2 ? 14 : 13),
                              weight: .semibold))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.top, 2)
        case .bullets(let items):
            listView(items) { _ in "•" }
        case .ordered(let items):
            listView(items) { "\($0 + 1)." }
        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.88))
                .textSelection(.enabled)
                // 滚动容器测量时可能压缩 Text 高度导致截断，固定纵向自适应
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.4)))
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 2)
                Text(MarkdownLite.inline(text))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .textSelection(.enabled)
            }
        }
    }

    private func listView(_ items: [String],
                          marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(index))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                    Text(MarkdownLite.inline(item))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
