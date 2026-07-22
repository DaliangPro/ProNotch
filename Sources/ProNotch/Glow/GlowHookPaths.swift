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

    /// 「开始工作」信号脚本，四家共用一个，来源由注册时的 $1 传入。
    ///
    /// 不跟着完成脚本一家一份：内容完全相同（只差那个参数），四份就是四份要同步刷新的副本。
    /// 也不跟完成脚本合成一个文件按事件名分支——Kimi / Grok 的事件名取值没实证过，
    /// 分支不可靠，而分开注册是各家配置本来就支持的
    var busyScript: String { scriptDir + "/agent-busy.sh" }

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
