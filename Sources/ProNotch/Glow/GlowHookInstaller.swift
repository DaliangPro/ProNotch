import Foundation

/// 把「完成提醒」接入 / 移出 Claude / Codex。两者机制不同：
/// - Claude Code：原生 Stop 钩子（`~/.claude/settings.json`），追加一条 `open pronotch://`。
/// - Codex：完成事件只走 `config.toml` 的 `notify`（单程序）。我们装一个转发脚本——
///   先 `open pronotch://` 点亮光晕，再把通知原样透传给原有的 `notify`（保留 computer-use
///   等下游不被打断）。原 `notify` 以 base64 存进脚本头部，卸载时据此还原。
///
/// 安全策略：写前备份 `.pronotch.bak`；Claude 只动我们自己追加的那条、Codex 只动 `notify`
/// 一行；全部可还原。
enum GlowHookInstaller {

    // MARK: - 对外接口（按来源分流）

    static func isInstalled(_ source: GlowSource) -> Bool {
        switch source {
        case .claude: return isClaudeInstalled()
        case .codex:  return isCodexInstalled()
        }
    }

    @discardableResult
    static func setInstalled(_ source: GlowSource, _ on: Bool) -> Bool {
        switch source {
        case .claude: return setClaudeInstalled(on)
        case .codex:  return setCodexInstalled(on)
        }
    }

    private static func command(for source: GlowSource) -> String {
        "open \"pronotch://done?source=\(source.rawValue)\""
    }

    private static func backup(_ path: String) {
        if let cur = FileManager.default.contents(atPath: path) {
            try? cur.write(to: URL(fileURLWithPath: path + ".pronotch.bak"))
        }
    }

    // MARK: - Claude Code（~/.claude/settings.json 的 Stop 钩子）

    private static let claudePath = ("~/.claude/settings.json" as NSString).expandingTildeInPath

    private static func entryHasOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("pronotch://done") == true
        } == true
    }

    private static func isClaudeInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: claudePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains(where: entryHasOurs)
    }

    @discardableResult
    private static func setClaudeInstalled(_ on: Bool) -> Bool {
        let p = claudePath
        let fm = FileManager.default
        guard fm.fileExists(atPath: (p as NSString).deletingLastPathComponent) else { return false }

        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: p) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        let hasOurs = stop.contains(where: entryHasOurs)

        if on {
            if hasOurs { return true }
            stop.append(["hooks": [["type": "command", "command": command(for: .claude)]]])
        } else {
            if !hasOurs { return true }
            stop.removeAll(where: entryHasOurs)
        }

        backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard let out = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: p))) != nil else { return false }
        return true
    }

    // MARK: - Codex（config.toml 的 notify 转发器）

    private static let codexConfig = ("~/.codex/config.toml" as NSString).expandingTildeInPath

    /// 转发脚本路径：放应用支持目录，跨重装稳定
    private static var codexScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/codex-notify.sh"
    }

    private static func isCodexInstalled() -> Bool {
        guard let toml = try? String(contentsOfFile: codexConfig, encoding: .utf8),
              let line = notifyLine(in: toml) else { return false }
        return line.contains(codexScript)
    }

    @discardableResult
    private static func setCodexInstalled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        // 没装 Codex（config.toml 所在目录不存在）就无法接入
        guard fm.fileExists(atPath: (codexConfig as NSString).deletingLastPathComponent) else { return false }
        let toml = (try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? ""

        if on {
            if isCodexInstalled() { return true }   // 幂等
            // 当前 notify（原样 TOML 数组串，nil = 无）作为 previous 写进脚本
            let prev = notifyArray(in: toml)
            guard writeForwarder(previous: prev) else { return false }
            backup(codexConfig)
            let newToml = upsertNotifyLine(toml, value: "[\"\(codexScript)\"]")
            return (try? newToml.write(toFile: codexConfig, atomically: true, encoding: .utf8)) != nil
        } else {
            if !isCodexInstalled() { return true }
            let prev = readPreviousFromForwarder()   // 从脚本取回原 notify
            backup(codexConfig)
            let newToml: String
            if let prev, !prev.isEmpty {
                newToml = upsertNotifyLine(toml, value: prev)
            } else {
                newToml = removeNotifyLine(toml)
            }
            let ok = (try? newToml.write(toFile: codexConfig, atomically: true, encoding: .utf8)) != nil
            if ok { try? fm.removeItem(atPath: codexScript) }
            return ok
        }
    }

    // MARK: - Codex TOML 辅助（只处理顶层单行 notify，Codex 实际就是单行）

    private static let notifyRegex = #"^\s*notify\s*="#

    /// 顶层 notify 行（行首 `notify =`）
    private static func notifyLine(in toml: String) -> String? {
        toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .first { $0.range(of: notifyRegex, options: .regularExpression) != nil }
    }

    /// notify 等号右侧的数组串 `[...]`（原样），无则 nil
    private static func notifyArray(in toml: String) -> String? {
        guard let line = notifyLine(in: toml), let eq = line.firstIndex(of: "=") else { return nil }
        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return val.isEmpty ? nil : val
    }

    /// 替换或新增顶层 notify 行
    private static func upsertNotifyLine(_ toml: String, value: String) -> String {
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLine = "notify = \(value)"
        if let i = lines.firstIndex(where: { $0.range(of: notifyRegex, options: .regularExpression) != nil }) {
            lines[i] = newLine
        } else {
            // 插到第一个 [section] 之前（顶层区），没有 section 就插到末尾
            let at = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert(newLine, at: at)
        }
        return lines.joined(separator: "\n")
    }

    private static func removeNotifyLine(_ toml: String) -> String {
        toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { $0.range(of: notifyRegex, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }

    // MARK: - 转发脚本生成 / 解析

    /// 生成转发脚本：点亮光晕 + 透传 previous；原 notify 以 base64 存进脚本头供还原
    private static func writeForwarder(previous: String?) -> Bool {
        let fm = FileManager.default
        let dir = (codexScript as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let prevB64 = previous?.data(using: .utf8)?.base64EncodedString() ?? ""
        let execBlock = forwardExecBlock(previous: previous)
        let script = """
        #!/bin/bash
        # ProNotch · Codex 完成提醒转发器（ProNotch 自动生成，请勿手改）
        # 还原：把 ~/.codex/config.toml 的 notify 改回下面 base64 的解码值，再删除本文件。
        # PRONOTCH_PREV_B64=\(prevB64)
        payload="$1"
        case "$payload" in
          *agent-turn-complete*) open "pronotch://done?source=codex" ;;
        esac
        \(execBlock)
        """
        guard (try? script.write(toFile: codexScript, atomically: true, encoding: .utf8)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexScript)
        return true
    }

    /// 透传块：把原 notify 数组解析成 bash 参数 exec；无 previous 则空操作
    private static func forwardExecBlock(previous: String?) -> String {
        guard let previous, let elems = parseTomlStringArray(previous), !elems.isEmpty else {
            return "# 原本无 notify，到此结束"
        }
        let quoted = elems.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        return "exec \(quoted) \"$payload\""
    }

    /// 从脚本头 `# PRONOTCH_PREV_B64=` 取回原 notify 数组串
    private static func readPreviousFromForwarder() -> String? {
        guard let script = try? String(contentsOfFile: codexScript, encoding: .utf8) else { return nil }
        for line in script.split(separator: "\n") {
            if let r = line.range(of: "# PRONOTCH_PREV_B64=") {
                let b64 = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if b64.isEmpty { return nil }
                return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        return nil
    }

    /// 解析 TOML 字符串数组 `["a","b",...]` → [String]（处理 \" \\ \/ \n \t 常见转义）
    private static func parseTomlStringArray(_ s: String) -> [String]? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = Array(t.dropFirst().dropLast())
        var result: [String] = []
        var i = 0
        while i < inner.count {
            while i < inner.count, inner[i] != "\"" { i += 1 }   // 找开引号
            guard i < inner.count else { break }
            i += 1
            var elem = ""
            while i < inner.count, inner[i] != "\"" {
                if inner[i] == "\\", i + 1 < inner.count {
                    switch inner[i + 1] {
                    case "\"": elem.append("\"")
                    case "\\": elem.append("\\")
                    case "/":  elem.append("/")
                    case "n":  elem.append("\n")
                    case "t":  elem.append("\t")
                    default:   elem.append(inner[i + 1])
                    }
                    i += 2
                } else {
                    elem.append(inner[i]); i += 1
                }
            }
            i += 1   // 跳过闭引号
            result.append(elem)
        }
        return result
    }
}
