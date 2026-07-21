import Foundation

/// `~/.codex/config.toml` 里顶层 `notify` 的定位与改写。
///
/// 原实现按行正则找 `^\s*notify\s*=`，三种情况会出错：
/// - 多行数组只替换掉第一行，剩下的元素变成游离行，整个 config.toml 语法报废
/// - 注释里或字符串里出现 `notify =` 被当成真的命中
/// - `[some.table]` 段内的 `notify` 被误认为顶层
///
/// 这里换成按 TOML 词法扫描：识别注释、基本串/字面串（含多行三引号）、数组与内联表，
/// 找到顶层 `notify` 后返回它在原文中的完整范围，替换与删除都按这个范围整体来。
enum CodexNotifyParser {

    /// 一次命中：`keyStart..<valueEnd` 覆盖从 `notify` 到值末尾的全部字符
    struct Match: Equatable {
        let keyStart: Int
        let valueEnd: Int
        /// 值的原样文本（如 `["/path/a.sh"]`）
        let rawValue: String
    }

    // MARK: - 定位

    static func find(in toml: String) -> Match? {
        let c = Array(toml)
        var i = 0
        while i < c.count {
            i = skipTrivia(c, i)
            guard i < c.count else { return nil }
            // 段头意味着顶层区结束——TOML 里顶层键只能出现在第一个表头之前
            if c[i] == "[" { return nil }

            let keyStart = i
            guard let afterKey = scanKey(c, i) else { return nil }
            let key = String(c[keyStart..<afterKey]).trimmingCharacters(in: .whitespaces)
            var j = skipInlineSpaces(c, afterKey)
            guard j < c.count, c[j] == "=" else { return nil }   // 不是键值对，无从解析
            j = skipInlineSpaces(c, j + 1)
            guard let valueEnd = scanValue(c, j) else { return nil }

            if key == "notify" || key == "\"notify\"" || key == "'notify'" {
                return Match(keyStart: keyStart, valueEnd: valueEnd,
                             rawValue: String(c[j..<valueEnd]))
            }
            i = valueEnd
        }
        return nil
    }

    // MARK: - 改写

    /// 替换或新增顶层 notify。新增时插到第一个段头之前（顶层区）
    static func upsert(_ toml: String, value: String) -> String {
        let c = Array(toml)
        if let m = find(in: toml) {
            return String(c[0..<m.keyStart]) + "notify = \(value)" + String(c[m.valueEnd...])
        }
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let at = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        lines.insert("notify = \(value)", at: at)
        return lines.joined(separator: "\n")
    }

    /// 删除顶层 notify 整条（连同它后面的换行，不留空行）
    static func remove(_ toml: String) -> String {
        guard let m = find(in: toml) else { return toml }
        let c = Array(toml)
        var end = m.valueEnd
        // 吃掉值后面的行内空白与行尾注释，直到换行为止
        while end < c.count, c[end] == " " || c[end] == "\t" { end += 1 }
        if end < c.count, c[end] == "#" {
            while end < c.count, c[end] != "\n" { end += 1 }
        }
        if end < c.count, c[end] == "\n" { end += 1 }
        return String(c[0..<m.keyStart]) + String(c[end...])
    }

    // MARK: - 值解析

    /// 解析 TOML 字符串数组 `["a","b"]` → [String]；不是数组则 nil
    static func parseStringArray(_ raw: String) -> [String]? {
        let c = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard c.first == "[", c.last == "]" else { return nil }
        var out: [String] = []
        var i = 1
        let end = c.count - 1
        while i < end {
            i = skipTrivia(c, i)
            guard i < end else { break }
            if c[i] == "," { i += 1; continue }
            guard let (text, next) = readString(c, i) else { return nil }
            out.append(text)
            i = next
        }
        return out
    }

    // MARK: - 词法扫描

    /// 跳过空白、换行与整行/行尾注释
    private static func skipTrivia(_ c: [Character], _ start: Int) -> Int {
        var i = start
        while i < c.count {
            if c[i] == " " || c[i] == "\t" || c[i] == "\n" || c[i] == "\r" { i += 1 }
            else if c[i] == "#" { while i < c.count, c[i] != "\n" { i += 1 } }
            else { break }
        }
        return i
    }

    private static func skipInlineSpaces(_ c: [Character], _ start: Int) -> Int {
        var i = start
        while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
        return i
    }

    /// 扫过一个键（裸键、点分键或带引号的键），返回键结束后的下标
    private static func scanKey(_ c: [Character], _ start: Int) -> Int? {
        var i = start
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" {
                guard let (_, next) = readString(c, i) else { return nil }
                i = next
            } else if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." {
                i += 1
            } else {
                break
            }
        }
        return i > start ? i : nil
    }

    /// 扫过一个值，返回值结束后的下标
    private static func scanValue(_ c: [Character], _ start: Int) -> Int? {
        guard start < c.count else { return nil }
        switch c[start] {
        case "\"", "'":
            return readString(c, start)?.1
        case "[":
            return scanBracketed(c, start, open: "[", close: "]")
        case "{":
            return scanBracketed(c, start, open: "{", close: "}")
        default:
            // 裸值（数字、布尔、日期）：到行尾或注释为止
            var i = start
            while i < c.count, c[i] != "\n", c[i] != "#" { i += 1 }
            return i
        }
    }

    /// 扫过配对括号，内部的字符串与注释不参与配对计数——
    /// 否则 `notify = ["echo ]"]` 会在字符串里的 `]` 提前收尾
    private static func scanBracketed(_ c: [Character], _ start: Int,
                                      open: Character, close: Character) -> Int? {
        var depth = 0
        var i = start
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" {
                guard let (_, next) = readString(c, i) else { return nil }
                i = next
                continue
            }
            if ch == "#" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            if ch == open { depth += 1 }
            if ch == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return nil   // 括号没闭合，整个文件当作不可解析，宁可不动
    }

    /// 读一个字符串字面量，返回（解码后的内容，结束后下标）。
    /// 支持基本串（`\` 转义）、字面串（无转义）与两者的三引号多行形式
    private static func readString(_ c: [Character], _ start: Int) -> (String, Int)? {
        guard start < c.count else { return nil }
        let quote = c[start]
        guard quote == "\"" || quote == "'" else { return nil }
        let isMultiline = start + 2 < c.count && c[start + 1] == quote && c[start + 2] == quote
        let delimiterLength = isMultiline ? 3 : 1
        var i = start + delimiterLength
        var text = ""

        while i < c.count {
            let ch = c[i]
            if ch == "\\", quote == "\"" {            // 字面串不做转义
                guard i + 1 < c.count else { return nil }
                switch c[i + 1] {
                case "\"": text.append("\"")
                case "\\": text.append("\\")
                case "/":  text.append("/")
                case "n":  text.append("\n")
                case "t":  text.append("\t")
                case "r":  text.append("\r")
                default:   text.append(c[i + 1])
                }
                i += 2
                continue
            }
            if ch == quote {
                if isMultiline {
                    if i + 2 < c.count, c[i + 1] == quote, c[i + 2] == quote {
                        return (text, i + 3)
                    }
                } else {
                    return (text, i + 1)
                }
            }
            if !isMultiline, ch == "\n" { return nil }   // 单行串不能跨行
            text.append(ch)
            i += 1
        }
        return nil
    }
}
