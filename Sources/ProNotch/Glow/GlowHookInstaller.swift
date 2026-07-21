import Foundation

/// 把「完成提醒」接入 / 移出各家 Agent。机制各不相同：
/// - Claude Code：原生 Stop 钩子（`~/.claude/settings.json`），追加一条转发脚本。
/// - Codex：完成事件只走 `config.toml` 的 `notify`（单程序）。我们装一个转发脚本——
///   先 `open pronotch://` 点亮光晕，再把通知原样透传给原有的 `notify`（保留 computer-use
///   等下游不被打断）。原 `notify` 以 base64 存进脚本头部，卸载时据此还原。
/// - Kimi Code：`~/.kimi-code/config.toml` 的 `[[hooks]]` 数组表（官方 Stop 事件，
///   stdin JSON 带 session_id，与 Claude 同构）——追加我们自己的一段，卸载时整段删除。
/// - Grok CLI：`~/.grok/hooks/` 全局钩子目录，每个应用一个独立 JSON 文件（Claude 同构
///   schema，机内 vibe-island.json 为实证）——我们写 `pronotch.json`，卸载时整文件删除。
///
/// 安全策略：写前备份 `.pronotch.bak`；每家只动我们自己写入的内容；全部可还原。
enum GlowHookInstaller {

    // MARK: - 对外接口（按来源分流）

    static func isInstalled(_ source: AgentKind) -> Bool {
        switch source {
        case .claude: return isClaudeInstalled()
        case .codex:  return isCodexInstalled()
        case .kimi:   return isKimiInstalled()
        case .grok:   return isGrokInstalled()
        }
    }

    @discardableResult
    static func setInstalled(_ source: AgentKind, _ on: Bool) -> Bool {
        switch source {
        case .claude: return setClaudeInstalled(on)
        case .codex:  return setCodexInstalled(on)
        case .kimi:   return setKimiInstalled(on)
        case .grok:   return setGrokInstalled(on)
        }
    }

    /// 升级迁移：仅把「已接入」的来源刷新到当前脚本格式，不改变接入与否
    static func migrateIfInstalled(_ source: AgentKind) {
        guard isInstalled(source) else { return }
        setInstalled(source, true)
    }

    /// 清除早期版本（43640d8）写进 ~/.codex/hooks.json 的 pronotch Stop 钩子孤儿。
    /// 现在 Codex 完成提醒走 config.toml 的 notify，这条孤儿会让每次完成多发一个「无 host」
    /// 信号——表现为：终端在前台时光晕仍亮、且只能靠激活 Codex 桌面 App 才能熄灭。
    @discardableResult
    static func cleanCodexHooksOrphan() -> Bool {
        let p = codexHooksPath
        guard let data = FileManager.default.contents(atPath: p),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any],
              var stop = hooks["Stop"] as? [[String: Any]] else { return false }
        let before = stop.count
        stop.removeAll { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("pronotch://done") == true
            } == true
        }
        guard stop.count != before else { return false }   // 无孤儿则不动文件
        backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: p))) != nil else { return false }
        return true
    }

    /// hook 脚本格式版本：升级时 +1，启动迁移据此把旧脚本刷新到新格式
    /// v4：URL 追加 session（Claude 读 stdin 的 session_id / Codex 读 payload 的 thread-id），供 Agent 页瞬时点亮
    private static let scriptFormat = 4

    /// 沿进程链向上找到「Agent 实际所在的 GUI App」bundle id。只认 /Applications 下的 app
    /// （借此排除 claude-code 的 CLI 包装 app）；终端 / IDE / 桌面 App 通用，找不到回空。
    private static let hostDetectSnippet = """
    detect_host() {
      local pid=$PPID ppid path app bid
      for _ in $(seq 1 15); do
        [ "$pid" -le 1 ] && break
        read -r ppid path < <(ps -o ppid=,comm= -p "$pid" 2>/dev/null)
        [ -z "$ppid" ] && break
        case "$path" in
          */Applications/*.app/Contents/*)
            app="${path%%.app/Contents/*}.app"
            bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)
            [ -n "$bid" ] && { printf '%s' "$bid"; return; } ;;
        esac
        pid=$ppid
      done
    }
    """

    /// 脚本是否已是当前格式（含 host 探测）：据脚本头的 PRONOTCH_FMT 标记判断
    private static func scriptIsCurrent(_ path: String) -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return s.contains("PRONOTCH_FMT=\(scriptFormat)")
    }

    private static func backup(_ path: String) {
        if let cur = FileManager.default.contents(atPath: path) {
            try? cur.write(to: URL(fileURLWithPath: path + ".pronotch.bak"))
        }
    }

    // MARK: - Claude Code（~/.claude/settings.json 的 Stop 钩子）

    private static let claudePath = ("~/.claude/settings.json" as NSString).expandingTildeInPath

    /// Claude 转发脚本：探测宿主 App + open -g 点亮（放应用支持目录，跨重装稳定）
    private static var claudeScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/claude-notify.sh"
    }
    private static var claudeCommand: String { "\"\(claudeScript)\"" }

    /// 旧版（内联 open pronotch://）或新版（指向脚本）都算「我们的」——卸载/迁移时一并处理
    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            let c = ($0["command"] as? String) ?? ""
            return c.contains("pronotch://done") || c.contains("claude-notify.sh")
        } == true
    }
    /// 仅新版（command 指向我们的脚本）
    private static func entryIsCurrentClaude(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("claude-notify.sh") == true
        } == true
    }

    /// 生成 Claude 转发脚本（内容幂等）
    @discardableResult
    private static func writeClaudeScript() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (claudeScript as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # ProNotch · Claude 完成提醒（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        payload=$(cat)
        host=$(detect_host)
        sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        url="pronotch://done?source=claude"
        [ -n "$host" ] && url="$url&host=$host"
        [ -n "$sid" ] && url="$url&session=$sid"
        open -g "$url"
        """
        guard (try? script.write(toFile: claudeScript, atomically: true, encoding: .utf8)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeScript)
        return true
    }

    private static func isClaudeInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: claudePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains(where: entryIsOurs)
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
        let oursEntries = stop.filter(entryIsOurs)

        if on {
            // 已是当前格式（脚本最新 + 仅一条指向脚本的 Stop 条目）→ 幂等跳过
            if scriptIsCurrent(claudeScript), oursEntries.count == 1, entryIsCurrentClaude(oursEntries[0]) {
                return true
            }
            guard writeClaudeScript() else { return false }
            stop.removeAll(where: entryIsOurs)   // 清掉旧内联 / 重复条目，再装新版
            stop.append(["hooks": [["type": "command", "command": claudeCommand]]])
        } else {
            if oursEntries.isEmpty { return true }
            stop.removeAll(where: entryIsOurs)
            try? fm.removeItem(atPath: claudeScript)
        }

        backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard let out = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: p))) != nil else { return false }
        return true
    }

    // MARK: - Kimi Code（~/.kimi-code/config.toml 的 [[hooks]] Stop 事件）

    private static let kimiConfig = ("~/.kimi-code/config.toml" as NSString).expandingTildeInPath

    private static var kimiScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/kimi-notify.sh"
    }
    private static var kimiScriptMarker: String { (kimiScript as NSString).lastPathComponent }

    /// 写进 config.toml 的整行 command（纯函数，可单测）。路径必须再套一层 shell 引号：
    /// Kimi 用 `spawn(command, [], { shell: true })` 执行，整串交给 shell 解析，而脚本躺在
    /// 「Application Support」里——裸路径会被空格切断成两截（sh: /Users/…/Library/Application:
    /// No such file），hook 静默失败、完成提醒就此失灵，且日志里什么都不留。
    /// 外层用 TOML 单引号（literal 串，不做转义），内层双引号原样落到 shell 手里。
    /// Claude / Codex / Grok 三家的 command 早已带引号，只有这里漏了
    nonisolated static func kimiHookCommandLine(for script: String) -> String {
        "command = '\"\(script)\"'"
    }

    private static var kimiCommandLine: String { kimiHookCommandLine(for: kimiScript) }

    /// Kimi 转发脚本：与 Claude 同构（Stop 事件 stdin JSON 带 session_id）
    @discardableResult
    private static func writeKimiScript() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (kimiScript as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # ProNotch · Kimi 完成提醒（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        payload=$(cat)
        host=$(detect_host)
        sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        url="pronotch://done?source=kimi"
        [ -n "$host" ] && url="$url&host=$host"
        [ -n "$sid" ] && url="$url&session=$sid"
        open -g "$url"
        """
        guard (try? script.write(toFile: kimiScript, atomically: true, encoding: .utf8)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kimiScript)
        return true
    }

    private static func isKimiInstalled() -> Bool {
        guard let toml = try? String(contentsOfFile: kimiConfig, encoding: .utf8) else { return false }
        return toml.contains(kimiScriptMarker) && FileManager.default.fileExists(atPath: kimiScript)
    }

    @discardableResult
    private static func setKimiInstalled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        // 没装 Kimi Code（config.toml 不存在）就无法接入
        guard fm.fileExists(atPath: kimiConfig),
              let toml = try? String(contentsOfFile: kimiConfig, encoding: .utf8) else { return false }
        let installed = toml.contains(kimiScriptMarker)

        if on {
            // 幂等：已接入、脚本最新、且配置行已是当前格式 → 不动文件。
            // 必须连配置行一起验——只验脚本的话，早期写成裸路径的用户永远修不好
            if installed, fm.fileExists(atPath: kimiScript), scriptIsCurrent(kimiScript),
               toml.contains(kimiCommandLine) { return true }
            guard writeKimiScript() else { return false }
            backup(kimiConfig)
            // 已有引用但不是当前格式（早期的裸路径）→ 整段删掉重写；全新安装则直接追加。
            // [[hooks]] 数组表追加到文件尾：不影响既有段落，TOML 语义安全
            let base = installed ? removeKimiHookBlock(toml) : toml
            let block = """


            # ProNotch 完成提醒（自动生成，卸载请在 ProNotch 设置里取消勾选）
            [[hooks]]
            event = "Stop"
            \(kimiCommandLine)
            timeout = 15
            """
            let newToml = base.hasSuffix("\n") ? base + block.dropFirst() : base + block
            return (try? newToml.write(toFile: kimiConfig, atomically: true, encoding: .utf8)) != nil
        } else {
            if !installed {
                try? fm.removeItem(atPath: kimiScript)   // 残留脚本顺手清掉
                return true
            }
            backup(kimiConfig)
            let newToml = removeKimiHookBlock(toml)
            guard (try? newToml.write(toFile: kimiConfig, atomically: true, encoding: .utf8)) != nil else { return false }
            try? fm.removeItem(atPath: kimiScript)
            return true
        }
    }

    /// 删除我们写入的 [[hooks]] 段：从「command 引用我们脚本」所在段的 `[[hooks]]` 行起，
    /// 到下一个段头（`[` 开头行）或文件尾；段前紧邻的 ProNotch 注释行一并清掉
    private static func removeKimiHookBlock(_ toml: String) -> String {
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let cmdIdx = lines.firstIndex(where: { $0.contains(kimiScriptMarker) }) else { return toml }
        // 向上找本段的 [[hooks]] 段头
        var start = cmdIdx
        while start > 0, lines[start].trimmingCharacters(in: .whitespaces) != "[[hooks]]" { start -= 1 }
        // 向下找段尾（下一个段头前）
        var end = cmdIdx + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        // 段前的 ProNotch 注释与空行一并回收
        var head = start
        while head > 0 {
            let prev = lines[head - 1].trimmingCharacters(in: .whitespaces)
            if prev.isEmpty || prev.hasPrefix("# ProNotch") { head -= 1 } else { break }
        }
        lines.removeSubrange(head..<end)
        return lines.joined(separator: "\n")
    }

    // MARK: - Grok CLI（~/.grok/hooks/pronotch.json 独立钩子文件，Stop 事件 Claude 同构）

    private static let grokHome = ("~/.grok" as NSString).expandingTildeInPath
    private static let grokHooksDir = ("~/.grok/hooks" as NSString).expandingTildeInPath
    private static let grokHookFile = ("~/.grok/hooks/pronotch.json" as NSString).expandingTildeInPath

    private static var grokScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/grok-notify.sh"
    }

    /// Grok 转发脚本：与 Claude 同构（Stop 事件 stdin JSON，session_id 抓不到也不影响点亮）
    @discardableResult
    private static func writeGrokScript() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (grokScript as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # ProNotch · Grok 完成提醒（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        payload=$(cat)
        host=$(detect_host)
        sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        url="pronotch://done?source=grok"
        [ -n "$host" ] && url="$url&host=$host"
        [ -n "$sid" ] && url="$url&session=$sid"
        open -g "$url"
        """
        guard (try? script.write(toFile: grokScript, atomically: true, encoding: .utf8)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grokScript)
        return true
    }

    private static func isGrokInstalled() -> Bool {
        FileManager.default.fileExists(atPath: grokHookFile)
            && FileManager.default.fileExists(atPath: grokScript)
    }

    @discardableResult
    private static func setGrokInstalled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        // 没装 Grok CLI（~/.grok 不存在）就无法接入
        guard fm.fileExists(atPath: grokHome) else { return false }

        if on {
            // 幂等：钩子文件在 + 脚本最新 → 不动文件
            if isGrokInstalled(), scriptIsCurrent(grokScript) { return true }
            guard writeGrokScript() else { return false }
            try? fm.createDirectory(atPath: grokHooksDir, withIntermediateDirectories: true)
            // 路径含空格（Application Support），command 经 shell 解释，须引号包裹
            let root: [String: Any] = ["hooks": ["Stop": [
                ["hooks": [["type": "command", "command": "\"\(grokScript)\""]]]
            ]]]
            guard let out = try? JSONSerialization.data(
                    withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                  (try? out.write(to: URL(fileURLWithPath: grokHookFile))) != nil else { return false }
            return true
        } else {
            // pronotch.json 整个文件都是我们写的：直接删即还原（不碰别家的钩子文件）
            try? fm.removeItem(atPath: grokHookFile)
            try? fm.removeItem(atPath: grokScript)
            return true
        }
    }

    // MARK: - Codex（config.toml 的 notify 转发器）

    private static let codexConfig = ("~/.codex/config.toml" as NSString).expandingTildeInPath
    private static let codexHooksPath = ("~/.codex/hooks.json" as NSString).expandingTildeInPath

    /// 转发脚本路径：放应用支持目录，跨重装稳定
    private static var codexScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/codex-notify.sh"
    }
    /// 脚本文件名，用于在 notify 串里识别「是否引用了我们」——文件名不含斜杠，
    /// 无论路径在 TOML 里是否被转义（computer-use 套壳时会 JSON 转义斜杠）都能匹配。
    private static var codexScriptMarker: String { (codexScript as NSString).lastPathComponent }

    private static func isCodexInstalled() -> Bool {
        guard let toml = try? String(contentsOfFile: codexConfig, encoding: .utf8),
              let arr = notifyArray(in: toml) else { return false }
        // notify 链中引用了我们的转发脚本（直接指向，或被 computer-use 等套在外层），且脚本在 → 已接入。
        // 旧版只认「首元素 = 脚本」，被套壳就误判「未接入」→ 重新勾选时酿成自引用死循环（光晕狂闪）。
        return arr.contains(codexScriptMarker) && FileManager.default.fileExists(atPath: codexScript)
    }

    @discardableResult
    private static func setCodexInstalled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        // 没装 Codex（config.toml 所在目录不存在）就无法接入
        guard fm.fileExists(atPath: (codexConfig as NSString).deletingLastPathComponent) else { return false }
        let toml = (try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? ""

        let arr = notifyArray(in: toml)
        let directlyOurs = arr?.hasPrefix("[\"\(codexScript)\"") == true   // notify 首元素就是我们的脚本
        let inChain = arr?.contains(codexScriptMarker) == true             // 链中引用了我们（含被外层套壳）

        if on {
            if inChain {
                // 已在 notify 链中。被 computer-use 等套在外层时，我们是「下游」，本就不该再向下转发；
                // 直接指向时，previous 取脚本自己记录的原值。绝不把「含我们自己的当前链」抓来当 previous，
                // 否则 exec 回自己 → 无限循环（这正是闪烁 bug 的根源）。脚本缺失或格式过期才重写。
                if !fm.fileExists(atPath: codexScript) || !scriptIsCurrent(codexScript) {
                    return writeForwarder(previous: directlyOurs ? readPreviousFromForwarder() : nil)
                }
                return true
            }
            // 全新接入：当前 notify（不含我们）整体作为 previous 透传
            guard writeForwarder(previous: arr) else { return false }
            backup(codexConfig)
            let newToml = upsertNotifyLine(toml, value: "[\"\(codexScript)\"]")
            return (try? newToml.write(toFile: codexConfig, atomically: true, encoding: .utf8)) != nil
        } else {
            if !inChain { return true }
            if directlyOurs {
                // notify 直接是我们：还原原 notify（或删整条）+ 删脚本
                backup(codexConfig)
                let prev = readPreviousFromForwarder()
                let newToml = (prev?.isEmpty == false) ? upsertNotifyLine(toml, value: prev!) : removeNotifyLine(toml)
                let ok = (try? newToml.write(toFile: codexConfig, atomically: true, encoding: .utf8)) != nil
                if ok { try? fm.removeItem(atPath: codexScript) }
                return ok
            }
            // 被外层套壳：notify 归上游（computer-use 等）管，不动它；只删我们的脚本即可
            // （上游转发到缺失脚本无害，不会再点亮光晕）。
            try? fm.removeItem(atPath: codexScript)
            return true
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

    /// 删除顶层 notify 行（恢复「无 notify」原状）
    private static func removeNotifyLine(_ toml: String) -> String {
        toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { $0.range(of: notifyRegex, options: .regularExpression) == nil }
            .joined(separator: "\n")
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

    // MARK: - 转发脚本生成 / 解析

    /// 生成转发脚本：点亮光晕 + 透传 previous；原 notify 以 base64 存进脚本头供还原
    private static func writeForwarder(previous: String?) -> Bool {
        // 根部兜底防自引用死循环：previous 绝不能（间接）引用本脚本，否则 exec 回自己 → 无限循环。
        // 被 computer-use 套壳后原 notify 链里就含我们，这里统一剥掉，任何调用路径都断得了环。
        let previous = (previous?.contains(codexScriptMarker) == true) ? nil : previous
        let fm = FileManager.default
        let dir = (codexScript as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let prevB64 = previous?.data(using: .utf8)?.base64EncodedString() ?? ""
        let execBlock = forwardExecBlock(previous: previous)
        let script = """
        #!/bin/bash
        # ProNotch · Codex 完成提醒转发器（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        # 还原：把 ~/.codex/config.toml 的 notify 改回下面 base64 的解码值，再删除本文件。
        # PRONOTCH_PREV_B64=\(prevB64)
        \(hostDetectSnippet)
        payload="$1"
        case "$payload" in
          *agent-turn-complete*)
            # 跳过 Codex Desktop 自动生成会话标题的内部任务——它在你刚发消息时就完成，会让光晕「一开始就亮」
            case "$payload" in
              *"Generate a concise UI title"*) : ;;
              *)
                host=$(detect_host)
                tid=$(printf '%s' "$payload" | sed -n 's/.*"thread-id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
                url="pronotch://done?source=codex"
                [ -n "$host" ] && url="$url&host=$host"
                [ -n "$tid" ] && url="$url&session=$tid"
                open -g "$url" ;;
            esac ;;
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
