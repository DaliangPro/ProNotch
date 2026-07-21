import XCTest
@testable import ProNotch

/// hook 不再把已退出的 ProNotch 拉起来。
///
/// 病灶：脚本用 `open -g "pronotch://done?…"` 投递回调，而 `open` 遇到没在运行的 App
/// 会**先把它启动起来**。于是用户手动退出 ProNotch 后，只要 Agent 干完一轮活，
/// hook 就把它拉了回来——用户看到的是「关不掉，它自己又开了」。
/// `-g` 不抢焦点，窗口都不弹，只有菜单栏图标默默出现，更难归因。
///
/// 这里不满足于「脚本文本里有 pgrep」，而是真把脚本跑起来：
/// 把 open 换成落一个标记文件，再分别用「在跑的进程名」和「不存在的进程名」执行，
/// 看标记文件到底有没有产生。
final class HookDeliveryGuardTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 取脚本

    /// 装一套 hook 到临时目录，取回生成的四个脚本原文
    private func installedScripts() throws -> [String: String] {
        let paths = GlowHookPaths.rooted(at: tmp.path)
        for dir in [paths.scriptDir, paths.codexDir, paths.grokHooksDir,
                    (paths.claudeSettings as NSString).deletingLastPathComponent,
                    (paths.kimiConfig as NSString).deletingLastPathComponent] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // Kimi 只在 config.toml 已存在时才肯接入（那代表用户真装了 Kimi Code）
        try "model = \"kimi-k2\"\n".write(toFile: paths.kimiConfig, atomically: true, encoding: .utf8)

        for kind in [AgentKind.claude, .codex, .kimi, .grok] {
            XCTAssertTrue(GlowHookInstaller.setInstalled(kind, true, paths: paths),
                          "\(kind) hook 安装失败")
        }

        var out: [String: String] = [:]
        for (name, path) in ["claude": paths.claudeScript, "codex": paths.codexScript,
                             "kimi": paths.kimiScript, "grok": paths.grokScript] {
            out[name] = try String(contentsOfFile: path, encoding: .utf8)
        }
        return out
    }

    // MARK: - 静态守卫

    func test四个脚本都先确认ProNotch在运行才投递() throws {
        for (name, script) in try installedScripts() {
            XCTAssertTrue(script.contains("pgrep -x ProNotch"),
                          "\(name) 少了运行检查，会把用户刚关掉的 App 拉回来")
        }
    }

    func test投递语句一律被守卫包住_没有裸的open() throws {
        for (name, script) in try installedScripts() {
            for line in script.split(separator: "\n") where line.contains("open -g") {
                XCTAssertTrue(line.contains("pgrep"),
                              "\(name) 出现没被守卫的投递：\(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// Codex 脚本在投递之后还要 exec 转发给原有的 notify（用户可能同时装着别的 notify 工具）。
    /// 若守卫写成 `pgrep … || exit`，ProNotch 没开时会连别人的通知链一起掐断
    func testCodex守卫不会掐断后续转发链() throws {
        let script = try XCTUnwrap(try installedScripts()["codex"])
        let guardLine = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("pgrep") })
        XCTAssertFalse(guardLine.contains("exit"),
                       "守卫里 exit 会跳过后面的转发块，把别人的 notify 也干掉：\(guardLine)")
    }

    /// 不看文本看行为：ProNotch 没跑时，脚本必须仍然执行到最后一行
    func testCodex在App没跑时仍执行到脚本末尾() throws {
        var script = try XCTUnwrap(try installedScripts()["codex"])
        let ghost = "ProNotchGhost\(UUID().uuidString.prefix(8))"
        let end = tmp.appendingPathComponent("reached-end")
        script = script.replacingOccurrences(of: "pgrep -x ProNotch", with: "pgrep -x \(ghost)")
        script += "\ntouch '\(end.path)'\n"

        let file = tmp.appendingPathComponent("codex-end.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        _ = try run("/bin/bash", [file.path, #"{"type":"agent-turn-complete","thread-id":"t1"}"#])

        XCTAssertTrue(FileManager.default.fileExists(atPath: end.path),
                      "守卫让脚本提前退出了，后面的转发块（别人的 notify）会被一起掐掉")
    }

    func test格式号已升级_旧脚本会被判过期() throws {
        let script = try XCTUnwrap(try installedScripts()["claude"])
        XCTAssertTrue(script.contains("PRONOTCH_FMT=6"),
                      "改了脚本内容却不升格式号，老用户的旧脚本永远不会被重写")
        XCTAssertFalse(script.contains("PRONOTCH_FMT=5"))
    }

    func test四个脚本语法都合法() throws {
        for (name, script) in try installedScripts() {
            let file = tmp.appendingPathComponent("\(name)-syntax.sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertEqual(try run("/bin/bash", ["-n", file.path]).status, 0,
                           "\(name) 脚本语法不合法")
        }
    }

    // MARK: - 真实行为

    /// 把脚本里的 open 换成落标记文件，用指定进程名跑一遍，回报「是否投递」与退出码
    private func deliver(scriptNamed name: String, watching process: String) throws -> (delivered: Bool, status: Int32) {
        var script = try XCTUnwrap(try installedScripts()[name])
        let marker = tmp.appendingPathComponent("\(name)-\(process)-delivered")
        script = script
            .replacingOccurrences(of: "pgrep -x ProNotch", with: "pgrep -x \(process)")
            .replacingOccurrences(of: #"open -g "$url""#, with: "touch '\(marker.path)'")
        let file = tmp.appendingPathComponent("\(name)-\(process).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        // Claude/Kimi/Grok 从 stdin 读 JSON；Codex 从 $1 读 payload
        let payload = #"{"session_id":"abc123"}"#
        let args = name == "codex" ? [file.path, #"{"type":"agent-turn-complete","thread-id":"t1"}"#]
                                   : [file.path]
        let result = try run("/bin/bash", args, stdin: payload)
        return (FileManager.default.fileExists(atPath: marker.path), result.status)
    }

    func test进程不在时不投递_也就不会把App拉起来() throws {
        // 一个绝不会存在的进程名
        let ghost = "ProNotchGhost\(UUID().uuidString.prefix(8))"
        for name in ["claude", "codex", "kimi", "grok"] {
            let r = try deliver(scriptNamed: name, watching: ghost)
            XCTAssertFalse(r.delivered, "\(name) 在 App 没运行时仍然投递了，等于把它拉回来")
        }
    }

    func test进程在跑时照常投递_光晕功能没被守卫误伤() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        for name in ["claude", "codex", "kimi", "grok"] {
            let r = try deliver(scriptNamed: name, watching: probe.name)
            XCTAssertTrue(r.delivered, "\(name) 在 App 运行时没投递，光晕就不亮了")
        }
    }

    /// 守卫用的是 `pgrep -x`（按内核 p_comm 精确匹配，即可执行文件名）。
    /// 若这条命令认不出正在跑的进程，光晕会全程不亮——那比多拉起一次 App 更糟
    func testPgrep精确匹配能认出正在运行的进程() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        XCTAssertEqual(try run("/usr/bin/pgrep", ["-x", probe.name]).status, 0,
                       "pgrep -x 认不出正在跑的 \(probe.name)，守卫会把所有投递都挡掉")

        let ghost = "PNGhost\(UUID().uuidString.prefix(6))"
        XCTAssertNotEqual(try run("/usr/bin/pgrep", ["-x", ghost]).status, 0,
                          "pgrep 对不存在的进程也返回成功，守卫就形同虚设")
    }

    /// 起一个确定在跑的进程当参照。
    ///
    /// 用 `/bin/sleep` 原件而不是复制改名：系统二进制的签名存在 SIP 的分离签名库里，
    /// 一复制走就验不过，macOS 直接 Kill: 9，探针根本起不来。
    /// 于是进程名固定是 sleep——机器上可能还有别的 sleep，但这里要断言的是
    /// 「pgrep -x 认得出正在跑的进程」，有没有同名的不影响结论
    private func startProbe() throws -> (name: String, process: Process) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        // 等内核登记进程名，否则紧接着的 pgrep 可能扑空
        for _ in 0..<50 where try run("/usr/bin/pgrep", ["-x", "sleep"]).status != 0 {
            usleep(20_000)
        }
        return ("sleep", p)
    }

    /// Stop hook 返回非零会被 Claude Code 当成失败报错，
    /// 所以「没投递」必须是安静的成功，不能是 `pgrep` 的失败码漏出来
    func test没投递时退出码仍是0() throws {
        let ghost = "ProNotchGhost\(UUID().uuidString.prefix(8))"
        for name in ["claude", "kimi", "grok"] {
            XCTAssertEqual(try deliver(scriptNamed: name, watching: ghost).status, 0,
                           "\(name) 漏了非零退出码，Claude Code 会报 hook 失败")
        }
    }

    // MARK: - 跑进程

    private func run(_ tool: String, _ args: [String], stdin: String? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        if let stdin {
            let input = Pipe()
            p.standardInput = input
            try p.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
        } else {
            try p.run()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
