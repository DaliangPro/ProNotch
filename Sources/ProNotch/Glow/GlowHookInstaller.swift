import Foundation

/// 把 `open "pronotch://done?source=…"` 接入 / 移出 Claude / Codex 的 Stop 钩子。
///
/// 「提醒来源」开关用它来开启 / 关闭某个 App 的自动提醒。
/// 安全策略：只动我们自己追加的那条（保留用户已有的 confirmo / peon-ping 等），写前备份 `.pronotch.bak`。
enum GlowHookInstaller {
    private static func path(for source: GlowSource) -> String {
        switch source {
        case .claude: return ("~/.claude/settings.json" as NSString).expandingTildeInPath
        case .codex:  return ("~/.codex/hooks.json" as NSString).expandingTildeInPath
        }
    }

    private static func command(for source: GlowSource) -> String {
        "open \"pronotch://done?source=\(source.rawValue)\""
    }

    private static func entryHasOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("pronotch://done") == true
        } == true
    }

    /// 该来源是否已接入（Stop 钩子里已含我们的 pronotch 命令）
    static func isInstalled(_ source: GlowSource) -> Bool {
        guard let data = FileManager.default.contents(atPath: path(for: source)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains(where: entryHasOurs)
    }

    /// 开启 / 关闭某来源的自动提醒（装 / 卸钩子）。返回是否成功落盘。
    @discardableResult
    static func setInstalled(_ source: GlowSource, _ on: Bool) -> Bool {
        let p = path(for: source)
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
            if hasOurs { return true }   // 幂等
            stop.append(["hooks": [["type": "command", "command": command(for: source)]]])
        } else {
            if !hasOurs { return true }
            stop.removeAll(where: entryHasOurs)   // 只移我们追加的那条，保留别人的
        }

        // 备份后写回
        if let current = fm.contents(atPath: p) {
            try? current.write(to: URL(fileURLWithPath: p + ".pronotch.bak"))
        }
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard let out = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: p))) != nil else { return false }
        return true
    }
}
