import Foundation

/// Kimi Code `config.toml` 里我们那段 `[[hooks]]` 的生成与摘除。
///
/// 原实现靠"找到含脚本名的行，向上找 `[[hooks]]`，向下找到下一个 `[`"来定位删除范围。
/// 这在正常文件上没问题，但用户手改过、缩进异常、或有多段 hooks 时，
/// 上下边界都可能跑飞，一刀下去把别人的配置也删了。
/// 新写入的块带明确边界标记，按标记删；旧格式没有标记，就只在能唯一确认时才删，
/// 确认不了宁可失败也不猜。
enum KimiHookBlock {
    static let beginMarker = "# >>> ProNotch managed hook BEGIN"
    static let endMarker = "# <<< ProNotch managed hook END"

    static func render(commandLine: String) -> String {
        """
        \(beginMarker)
        # ProNotch 完成提醒（自动生成，卸载请在 ProNotch 设置里取消勾选）
        [[hooks]]
        event = "Stop"
        \(commandLine)
        timeout = 15
        \(endMarker)
        """
    }

    enum Removal: Equatable {
        case removed(String)
        /// 文件里本来就没有我们的块
        case notPresent
        /// 有引用，但边界无法唯一确定——保持原文件不动，交由上层报失败
        case ambiguous
    }

    /// 摘除我们的块。`scriptPath` 用于旧格式的精确匹配
    static func remove(from toml: String, scriptPath: String) -> Removal {
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let begins = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == beginMarker }
        let ends = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == endMarker }
        if !begins.isEmpty || !ends.isEmpty {
            // 有标记就必须成对且唯一，残缺说明文件被手改过，不猜
            guard begins.count == 1, ends.count == 1, begins[0] < ends[0] else { return .ambiguous }
            lines.removeSubrange(trimLeadingBlanks(lines, from: begins[0])...ends[0])
            return .removed(lines.joined(separator: "\n"))
        }

        // 旧格式：没有边界标记，只认"唯一一行精确引用我们的脚本"
        let marker = (scriptPath as NSString).lastPathComponent
        let hits = lines.indices.filter { lines[$0].contains(marker) }
        guard !hits.isEmpty else { return .notPresent }
        guard hits.count == 1 else { return .ambiguous }
        let hit = hits[0]

        // 这一行必须是 command 且精确指向我们的脚本，不能只是"提到了文件名"
        let trimmed = lines[hit].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("command"), trimmed.contains(scriptPath) else { return .ambiguous }

        // 向上找本段的 [[hooks]] 段头：中途撞上别的段头说明这行不在 hooks 段里
        var start = hit
        while start > 0 {
            let line = lines[start].trimmingCharacters(in: .whitespaces)
            if line == "[[hooks]]" { break }
            if line.hasPrefix("[") { return .ambiguous }
            start -= 1
        }
        guard lines[start].trimmingCharacters(in: .whitespaces) == "[[hooks]]" else { return .ambiguous }

        // 向下到下一个段头或文件尾
        var end = hit + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }

        // 段前紧邻的 ProNotch 注释与空行一并回收
        var head = start
        while head > 0 {
            let prev = lines[head - 1].trimmingCharacters(in: .whitespaces)
            if prev.isEmpty || prev.hasPrefix("# ProNotch") { head -= 1 } else { break }
        }
        lines.removeSubrange(head..<end)
        return .removed(lines.joined(separator: "\n"))
    }

    /// 把块前紧邻的空行一起纳入删除范围，避免卸载后留下一堆空行
    private static func trimLeadingBlanks(_ lines: [String], from index: Int) -> Int {
        var head = index
        while head > 0, lines[head - 1].trimmingCharacters(in: .whitespaces).isEmpty { head -= 1 }
        return head
    }
}
