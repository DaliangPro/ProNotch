import Foundation

/// 「一键接入」：往 Claude / Codex 的 Stop 钩子各追加一条 `open "pronotch://done?source=…"`，
/// 使其任务完成时点亮 ProNotch 光晕。
///
/// 安全策略：保留用户已有钩子（只追加不覆盖）、写前备份 `.pronotch.bak`、幂等（已接入不重复）。
enum GlowHookInstaller {
    struct Result { let claude: String; let codex: String }

    static func install() -> Result {
        Result(
            claude: installOne(
                path: (("~/.claude/settings.json") as NSString).expandingTildeInPath,
                command: "open \"pronotch://done?source=claude\""),
            codex: installOne(
                path: (("~/.codex/hooks.json") as NSString).expandingTildeInPath,
                command: "open \"pronotch://done?source=codex\"")
        )
    }

    private static func installOne(path: String, command: String) -> String {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: dir) else { return "未找到配置目录，跳过" }

        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: path) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "配置无法解析，未改动"
            }
            root = obj
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []

        // 幂等：已含 pronotch 命令则跳过
        let already = stop.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("pronotch://done") == true
            } == true
        }
        if already { return "已接入（未重复添加）" }

        // 备份当前文件
        if let current = fm.contents(atPath: path) {
            try? current.write(to: URL(fileURLWithPath: path + ".pronotch.bak"))
        }

        stop.append(["hooks": [["type": "command", "command": command]]])
        hooks["Stop"] = stop
        root["hooks"] = hooks

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return "序列化失败，未改动"
        }
        do {
            try out.write(to: URL(fileURLWithPath: path))
            return "已接入 ✅"
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
    }
}
