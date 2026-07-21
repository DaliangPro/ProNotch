import XCTest
@testable import ProNotch

/// Kimi 完成提醒 hook 的 command 行格式。
/// 修复背景：脚本装在「~/Library/Application Support/ProNotch/」，而 Kimi 用
/// `spawn(command, [], { shell: true })` 把整串交给 shell 解析。早期写的是裸路径，
/// 被空格从中间切断（sh: /Users/…/Library/Application: No such file），hook 静默不执行、
/// 日志里也不留痕——表现为「Kimi 勾了却从来不提醒」，而 Claude / Codex / Grok 都正常。
final class GlowHookCommandTests: XCTestCase {
    private let scriptPath = "/Users/x/Library/Application Support/ProNotch/kimi-notify.sh"

    /// 模拟 shell 的 word splitting：不带引号时，第一个空格之后都成了参数
    private func shellFirstWord(_ command: String) -> String {
        String(command.split(separator: " ").first ?? "")
    }

    func test命令行给路径套了shell引号() {
        XCTAssertEqual(GlowHookInstaller.kimiHookCommandLine(for: scriptPath),
                       "command = '\"/Users/x/Library/Application Support/ProNotch/kimi-notify.sh\"'")
    }

    /// 反向断言：证明这层引号不是多余的——裸路径确实会被 shell 切断
    func test裸路径会被shell从空格处切断() {
        XCTAssertEqual(shellFirstWord(scriptPath), "/Users/x/Library/Application",
                       "裸路径交给 shell 只剩这一截，命令自然不存在")
    }

    /// TOML 外层单引号是 literal 串定界符，解析后值本身仍带双引号，空格才受保护
    func test剥掉TOML定界符后值仍被双引号包住() {
        let line = GlowHookInstaller.kimiHookCommandLine(for: scriptPath)
        let value = line.replacingOccurrences(of: "command = ", with: "")
        XCTAssertTrue(value.hasPrefix("'") && value.hasSuffix("'"), "外层应是 TOML literal 串")
        let unwrapped = String(value.dropFirst().dropLast())
        XCTAssertEqual(unwrapped, "\"\(scriptPath)\"", "剥掉 TOML 定界符后，shell 拿到的仍是带引号的完整路径")
    }

    /// 路径不含空格时也照样加引号：格式统一，且将来路径变了不会突然失效
    func test无空格路径同样加引号() {
        XCTAssertEqual(GlowHookInstaller.kimiHookCommandLine(for: "/tmp/a.sh"),
                       "command = '\"/tmp/a.sh\"'")
    }
}
