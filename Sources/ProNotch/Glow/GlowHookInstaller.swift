import Foundation

/// 把「完成提醒」接入 / 移出各家 Agent。机制各不相同：
/// - Claude Code：原生 Stop 钩子（`~/.claude/settings.json`），追加一条转发脚本。
/// - Codex：完成事件只走 `config.toml` 的 `notify`（单程序）。我们装一个转发脚本——
///   先 `open pronotch://` 点亮光晕，再把通知原样透传给原有的 `notify`（保留 computer-use
///   等下游不被打断）。原 `notify` 以 base64 存进脚本头部，卸载时据此还原。
/// - Kimi Code：`~/.kimi-code/config.toml` 的 `[[hooks]]` 数组表（官方 Stop 事件，
///   stdin JSON 带 session_id，与 Claude 同构）——追加带边界标记的一段，卸载时整段删除。
/// - Grok CLI：`~/.grok/hooks/` 全局钩子目录，每个应用一个独立 JSON 文件（Claude 同构
///   schema，机内 vibe-island.json 为实证）——我们写 `pronotch.json`，卸载时整文件删除。
///
/// 一致性原则（四家统一）：
/// 1. 改配置前先备份（两代轮换）。
/// 2. 配置一律经 `AtomicConfigWriter` 写：同目录临时文件 → 结构校验 → 原子替换，
///    失败时原文件字节不变。
/// 3. 安装时脚本先落到临时文件，配置替换成功后才把脚本原子挪到位；
///    卸载时先改配置，成功后才删脚本。任一步失败都不会留下「配置指向不存在的脚本」
///    或「脚本在但配置没接上」的半截状态。
/// 4. 无法唯一确定要删的范围时返回失败，保持原文件——宁可让用户手动清理，
///    也不能把别人的配置删掉。
enum GlowHookInstaller {

    // MARK: - 对外接口（按来源分流）

    static func isInstalled(_ source: AgentKind, paths: GlowHookPaths = .production) -> Bool {
        switch source {
        case .claude: return isClaudeInstalled(paths)
        case .codex:  return isCodexInstalled(paths)
        case .kimi:   return isKimiInstalled(paths)
        case .grok:   return isGrokInstalled(paths)
        }
    }

    @discardableResult
    static func setInstalled(_ source: AgentKind, _ on: Bool,
                             paths: GlowHookPaths = .production) -> Bool {
        switch source {
        case .claude: return setClaudeInstalled(on, paths)
        case .codex:  return setCodexInstalled(on, paths)
        case .kimi:   return setKimiInstalled(on, paths)
        case .grok:   return setGrokInstalled(on, paths)
        }
    }

    /// 升级迁移：仅把「已接入」的来源刷新到当前脚本格式，不改变接入与否
    static func migrateIfInstalled(_ source: AgentKind, paths: GlowHookPaths = .production) {
        guard isInstalled(source, paths: paths) else { return }
        setInstalled(source, true, paths: paths)
    }

    /// 清除早期版本（43640d8）写进 ~/.codex/hooks.json 的 pronotch Stop 钩子孤儿。
    /// 现在 Codex 完成提醒走 config.toml 的 notify，这条孤儿会让每次完成多发一个「无 host」
    /// 信号——表现为：终端在前台时光晕仍亮、且只能靠激活 Codex 桌面 App 才能熄灭。
    @discardableResult
    static func cleanCodexHooksOrphan(paths: GlowHookPaths = .production) -> Bool {
        let p = paths.codexHooks
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
        AtomicConfigWriter.backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return writeJSON(root, to: p)
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

    /// stdin JSON 型转发脚本（Claude / Kimi / Grok 三家同构）
    private static func stdinNotifyScript(source: String) -> String {
        """
        #!/bin/bash
        # ProNotch · \(source) 完成提醒（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        payload=$(cat)
        host=$(detect_host)
        sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        url="pronotch://done?source=\(source)"
        [ -n "$host" ] && url="$url&host=$host"
        [ -n "$sid" ] && url="$url&session=$sid"
        open -g "$url"
        """
    }

    /// JSON 配置的原子写入：序列化 + 回读校验，坏内容不落盘
    private static func writeJSON(_ root: [String: Any], to path: String) -> Bool {
        guard let out = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? JSONSerialization.jsonObject(with: out)) != nil else { return false }
        return AtomicConfigWriter.writeData(out, to: path).isSuccess
    }

    // MARK: - Claude Code（~/.claude/settings.json 的 Stop 钩子）

    private static func claudeCommand(_ paths: GlowHookPaths) -> String { "\"\(paths.claudeScript)\"" }

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

    private static func isClaudeInstalled(_ paths: GlowHookPaths) -> Bool {
        guard let data = FileManager.default.contents(atPath: paths.claudeSettings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains(where: entryIsOurs)
    }

    @discardableResult
    private static func setClaudeInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let p = paths.claudeSettings
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

        var staged: String?
        if on {
            // 已是当前格式（脚本最新 + 仅一条指向脚本的 Stop 条目）→ 幂等跳过
            if scriptIsCurrent(paths.claudeScript), oursEntries.count == 1,
               entryIsCurrentClaude(oursEntries[0]) { return true }
            staged = AtomicConfigWriter.stageScript(stdinNotifyScript(source: "claude"),
                                                    finalPath: paths.claudeScript)
            guard staged != nil else { return false }
            stop.removeAll(where: entryIsOurs)   // 清掉旧内联 / 重复条目，再装新版
            stop.append(["hooks": [["type": "command", "command": claudeCommand(paths)]]])
        } else {
            if oursEntries.isEmpty { return true }
            stop.removeAll(where: entryIsOurs)
        }

        AtomicConfigWriter.backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard writeJSON(root, to: p) else {
            AtomicConfigWriter.discardScript(staged)   // 配置没写成，脚本也不落位
            return false
        }
        if on {
            return AtomicConfigWriter.commitScript(from: staged!, to: paths.claudeScript)
        }
        try? fm.removeItem(atPath: paths.claudeScript)   // 配置改成功后才删脚本
        return true
    }

    // MARK: - Kimi Code（~/.kimi-code/config.toml 的 [[hooks]] Stop 事件）

    private static func kimiScriptMarker(_ paths: GlowHookPaths) -> String {
        (paths.kimiScript as NSString).lastPathComponent
    }

    /// 写进 config.toml 的整行 command（纯函数，可单测）。路径必须再套一层 shell 引号：
    /// Kimi 用 `spawn(command, [], { shell: true })` 执行，整串交给 shell 解析，而脚本躺在
    /// 「Application Support」里——裸路径会被空格切断成两截（sh: /Users/…/Library/Application:
    /// No such file），hook 静默失败、完成提醒就此失灵，且日志里什么都不留。
    /// 外层用 TOML 单引号（literal 串，不做转义），内层双引号原样落到 shell 手里。
    /// Claude / Codex / Grok 三家的 command 早已带引号，只有这里漏了
    nonisolated static func kimiHookCommandLine(for script: String) -> String {
        "command = '\"\(script)\"'"
    }

    private static func isKimiInstalled(_ paths: GlowHookPaths) -> Bool {
        guard let toml = try? String(contentsOfFile: paths.kimiConfig, encoding: .utf8) else { return false }
        return toml.contains(kimiScriptMarker(paths))
            && FileManager.default.fileExists(atPath: paths.kimiScript)
    }

    @discardableResult
    private static func setKimiInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let fm = FileManager.default
        // 没装 Kimi Code（config.toml 不存在）就无法接入
        guard fm.fileExists(atPath: paths.kimiConfig),
              let toml = try? String(contentsOfFile: paths.kimiConfig, encoding: .utf8) else { return false }
        let commandLine = kimiHookCommandLine(for: paths.kimiScript)
        let installed = toml.contains(kimiScriptMarker(paths))

        if on {
            // 幂等：已接入、脚本最新、且配置已是当前格式（带边界标记的块）→ 不动文件。
            // 必须连配置行一起验——只验脚本的话，早期写成裸路径的用户永远修不好
            if installed, fm.fileExists(atPath: paths.kimiScript), scriptIsCurrent(paths.kimiScript),
               toml.contains(commandLine), toml.contains(KimiHookBlock.beginMarker) { return true }

            // 已有引用但不是当前格式 → 先精确摘掉旧的，摘不干净就整笔放弃
            var base = toml
            if installed {
                switch KimiHookBlock.remove(from: toml, scriptPath: paths.kimiScript) {
                case .removed(let cleaned): base = cleaned
                case .notPresent:          break
                case .ambiguous:           return false
                }
            }
            guard let staged = AtomicConfigWriter.stageScript(stdinNotifyScript(source: "kimi"),
                                                              finalPath: paths.kimiScript) else { return false }
            AtomicConfigWriter.backup(paths.kimiConfig)
            let block = KimiHookBlock.render(commandLine: commandLine)
            let newToml = base.hasSuffix("\n") ? base + "\n" + block + "\n" : base + "\n\n" + block + "\n"
            let result = AtomicConfigWriter.write(newToml, to: paths.kimiConfig) { text in
                // 结构校验：写出去的必须能再被自己摘回来，否则说明拼错了
                text.contains(KimiHookBlock.beginMarker) && text.contains(KimiHookBlock.endMarker)
                    && text.contains(commandLine)
            }
            guard result.isSuccess else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            return AtomicConfigWriter.commitScript(from: staged, to: paths.kimiScript)
        }

        // 卸载
        switch KimiHookBlock.remove(from: toml, scriptPath: paths.kimiScript) {
        case .notPresent:
            try? fm.removeItem(atPath: paths.kimiScript)   // 残留脚本顺手清掉
            return true
        case .ambiguous:
            return false                                   // 定位不了就不动，宁可让用户手删
        case .removed(let cleaned):
            AtomicConfigWriter.backup(paths.kimiConfig)
            let result = AtomicConfigWriter.write(cleaned, to: paths.kimiConfig) { text in
                !text.contains(kimiScriptMarker(paths))
            }
            guard result.isSuccess else { return false }
            try? fm.removeItem(atPath: paths.kimiScript)
            return true
        }
    }

    // MARK: - Grok CLI（~/.grok/hooks/pronotch.json 独立钩子文件，Stop 事件 Claude 同构）

    private static func isGrokInstalled(_ paths: GlowHookPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.grokHookFile)
            && FileManager.default.fileExists(atPath: paths.grokScript)
    }

    @discardableResult
    private static func setGrokInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let fm = FileManager.default
        // 没装 Grok CLI（~/.grok 不存在）就无法接入
        guard fm.fileExists(atPath: paths.grokHome) else { return false }

        if on {
            // 幂等：钩子文件在 + 脚本最新 → 不动文件
            if isGrokInstalled(paths), scriptIsCurrent(paths.grokScript) { return true }
            guard let staged = AtomicConfigWriter.stageScript(stdinNotifyScript(source: "grok"),
                                                              finalPath: paths.grokScript) else { return false }
            try? fm.createDirectory(atPath: paths.grokHooksDir, withIntermediateDirectories: true)
            // 路径含空格（Application Support），command 经 shell 解释，须引号包裹
            let root: [String: Any] = ["hooks": ["Stop": [
                ["hooks": [["type": "command", "command": "\"\(paths.grokScript)\""]]]
            ]]]
            guard writeJSON(root, to: paths.grokHookFile) else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            return AtomicConfigWriter.commitScript(from: staged, to: paths.grokScript)
        }
        // pronotch.json 整个文件都是我们写的：直接删即还原（不碰别家的钩子文件）
        try? fm.removeItem(atPath: paths.grokHookFile)
        try? fm.removeItem(atPath: paths.grokScript)
        return true
    }

    // MARK: - Codex（config.toml 的 notify 转发器）

    /// 脚本文件名，用于在 notify 串里识别「是否引用了我们」——文件名不含斜杠，
    /// 无论路径在 TOML 里是否被转义（computer-use 套壳时会 JSON 转义斜杠）都能匹配。
    private static func codexScriptMarker(_ paths: GlowHookPaths) -> String {
        (paths.codexScript as NSString).lastPathComponent
    }

    private static func isCodexInstalled(_ paths: GlowHookPaths) -> Bool {
        guard let toml = try? String(contentsOfFile: paths.codexConfig, encoding: .utf8),
              let match = CodexNotifyParser.find(in: toml) else { return false }
        // notify 链中引用了我们的转发脚本（直接指向，或被 computer-use 等套在外层），且脚本在 → 已接入。
        // 旧版只认「首元素 = 脚本」，被套壳就误判「未接入」→ 重新勾选时酿成自引用死循环（光晕狂闪）。
        return match.rawValue.contains(codexScriptMarker(paths))
            && FileManager.default.fileExists(atPath: paths.codexScript)
    }

    @discardableResult
    private static func setCodexInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let fm = FileManager.default
        // 没装 Codex（config.toml 所在目录不存在）就无法接入
        guard fm.fileExists(atPath: paths.codexDir) else { return false }
        let toml = (try? String(contentsOfFile: paths.codexConfig, encoding: .utf8)) ?? ""

        let raw = CodexNotifyParser.find(in: toml)?.rawValue
        // notify 首元素就是我们的脚本
        let directlyOurs = CodexNotifyParser.parseStringArray(raw ?? "")?.first == paths.codexScript
        // 链中引用了我们（含被外层套壳）
        let inChain = raw?.contains(codexScriptMarker(paths)) == true

        if on {
            if inChain {
                // 已在 notify 链中。被 computer-use 等套在外层时，我们是「下游」，本就不该再向下转发；
                // 直接指向时，previous 取脚本自己记录的原值。绝不把「含我们自己的当前链」抓来当 previous，
                // 否则 exec 回自己 → 无限循环（这正是闪烁 bug 的根源）。脚本缺失或格式过期才重写。
                if !fm.fileExists(atPath: paths.codexScript) || !scriptIsCurrent(paths.codexScript) {
                    let prev = directlyOurs ? readPreviousFromForwarder(paths) : nil
                    guard let staged = stageForwarder(previous: prev, paths) else { return false }
                    return AtomicConfigWriter.commitScript(from: staged, to: paths.codexScript)
                }
                return true
            }
            // 全新接入：当前 notify（不含我们）整体作为 previous 透传
            guard let staged = stageForwarder(previous: raw, paths) else { return false }
            AtomicConfigWriter.backup(paths.codexConfig)
            let newToml = CodexNotifyParser.upsert(toml, value: "[\"\(paths.codexScript)\"]")
            let result = AtomicConfigWriter.write(newToml, to: paths.codexConfig) { text in
                // 结构校验：改完必须还能被解析出唯一顶层 notify，且指向我们
                guard let m = CodexNotifyParser.find(in: text) else { return false }
                return CodexNotifyParser.parseStringArray(m.rawValue)?.first == paths.codexScript
            }
            guard result.isSuccess else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            return AtomicConfigWriter.commitScript(from: staged, to: paths.codexScript)
        }

        if !inChain { return true }
        if directlyOurs {
            // notify 直接是我们：还原原 notify（或删整条）+ 删脚本
            AtomicConfigWriter.backup(paths.codexConfig)
            let prev = readPreviousFromForwarder(paths)
            let newToml = (prev?.isEmpty == false)
                ? CodexNotifyParser.upsert(toml, value: prev!)
                : CodexNotifyParser.remove(toml)
            let result = AtomicConfigWriter.write(newToml, to: paths.codexConfig) { text in
                CodexNotifyParser.find(in: text)?.rawValue.contains(codexScriptMarker(paths)) != true
            }
            guard result.isSuccess else { return false }
            try? fm.removeItem(atPath: paths.codexScript)
            return true
        }
        // 被外层套壳：notify 归上游（computer-use 等）管，不动它；只删我们的脚本即可
        // （上游转发到缺失脚本无害，不会再点亮光晕）。
        try? fm.removeItem(atPath: paths.codexScript)
        return true
    }

    // MARK: - 转发脚本生成 / 解析

    /// 生成转发脚本并暂存：点亮光晕 + 透传 previous；原 notify 以 base64 存进脚本头供还原
    private static func stageForwarder(previous: String?, _ paths: GlowHookPaths) -> String? {
        // 根部兜底防自引用死循环：previous 绝不能（间接）引用本脚本，否则 exec 回自己 → 无限循环。
        // 被 computer-use 套壳后原 notify 链里就含我们，这里统一剥掉，任何调用路径都断得了环。
        let previous = (previous?.contains(codexScriptMarker(paths)) == true) ? nil : previous
        let prevB64 = previous?.data(using: .utf8)?.base64EncodedString() ?? ""
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
        \(forwardExecBlock(previous: previous))
        """
        return AtomicConfigWriter.stageScript(script, finalPath: paths.codexScript)
    }

    /// 透传块：把原 notify 数组解析成 bash 参数 exec；无 previous 则空操作
    private static func forwardExecBlock(previous: String?) -> String {
        guard let previous, let elems = CodexNotifyParser.parseStringArray(previous),
              !elems.isEmpty else {
            return "# 原本无 notify，到此结束"
        }
        let quoted = elems.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        return "exec \(quoted) \"$payload\""
    }

    /// 从脚本头 `# PRONOTCH_PREV_B64=` 取回原 notify 数组串
    private static func readPreviousFromForwarder(_ paths: GlowHookPaths) -> String? {
        guard let script = try? String(contentsOfFile: paths.codexScript, encoding: .utf8) else { return nil }
        for line in script.split(separator: "\n") {
            if let r = line.range(of: "# PRONOTCH_PREV_B64=") {
                let b64 = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if b64.isEmpty { return nil }
                return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        return nil
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
