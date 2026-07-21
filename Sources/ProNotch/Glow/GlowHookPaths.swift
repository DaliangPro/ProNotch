import Foundation

/// hook 安装涉及的全部路径。
///
/// 抽出来是为了让安装 / 卸载逻辑可以在临时目录里跑测试——
/// 这些代码改的是用户自己的 `~/.codex/config.toml`、`~/.claude/settings.json`，
/// 拿真实家目录当测试场地不可接受
struct GlowHookPaths: Sendable {
    var scriptDir: String
    var claudeSettings: String
    var kimiConfig: String
    var codexDir: String
    var grokHome: String

    var codexConfig: String { codexDir + "/config.toml" }
    var codexHooks: String { codexDir + "/hooks.json" }
    var grokHooksDir: String { grokHome + "/hooks" }
    var grokHookFile: String { grokHooksDir + "/pronotch.json" }

    var claudeScript: String { scriptDir + "/claude-notify.sh" }
    var kimiScript: String { scriptDir + "/kimi-notify.sh" }
    var grokScript: String { scriptDir + "/grok-notify.sh" }
    var codexScript: String { scriptDir + "/codex-notify.sh" }

    static var production: GlowHookPaths {
        let home = NSHomeDirectory()
        return GlowHookPaths(
            scriptDir: home + "/Library/Application Support/ProNotch",
            claudeSettings: home + "/.claude/settings.json",
            kimiConfig: home + "/.kimi-code/config.toml",
            codexDir: home + "/.codex",
            grokHome: home + "/.grok")
    }

    /// 把所有路径挪到指定根目录下（测试用）
    static func rooted(at root: String) -> GlowHookPaths {
        GlowHookPaths(
            scriptDir: root + "/Library/Application Support/ProNotch",
            claudeSettings: root + "/.claude/settings.json",
            kimiConfig: root + "/.kimi-code/config.toml",
            codexDir: root + "/.codex",
            grokHome: root + "/.grok")
    }
}
