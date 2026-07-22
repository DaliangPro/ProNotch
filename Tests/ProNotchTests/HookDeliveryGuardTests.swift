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

    /// 不写死具体数字（每升一版这条就会假失败一次），只钉住「不许退回 v7 之前」——
    /// v7 是引入 background_tasks 过滤的那版，退回去等于把这次修的病放回来
    func test格式号不低于引入过滤的那版() throws {
        let script = try XCTUnwrap(try installedScripts()["claude"])
        let marker = try XCTUnwrap(
            script.range(of: #"PRONOTCH_FMT=\d+"#, options: .regularExpression),
            "脚本头少了 PRONOTCH_FMT 标记，迁移就无从判断新旧")
        let version = Int(script[marker].dropFirst("PRONOTCH_FMT=".count)) ?? 0
        XCTAssertGreaterThanOrEqual(version, 7,
                                    "格式号退回 v7 之前，老用户的脚本不会被刷新到带过滤的版本")
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
    private func deliver(scriptNamed name: String, watching process: String,
                         payload: String = #"{"session_id":"abc123"}"#)
    throws -> (delivered: Bool, status: Int32) {
        var script = try XCTUnwrap(try installedScripts()[name])
        // 同一个 name+process 会跑多次（只换载荷），标记文件名得各不相同，否则互相串味
        let slug = UUID().uuidString.prefix(8)
        let marker = tmp.appendingPathComponent("\(name)-\(slug)-delivered")
        script = script
            .replacingOccurrences(of: "pgrep -x ProNotch", with: "pgrep -x \(process)")
            .replacingOccurrences(of: #"open -g "$url""#, with: "touch '\(marker.path)'")
        let file = tmp.appendingPathComponent("\(name)-\(slug).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        // Claude/Kimi/Grok 从 stdin 读 JSON；Codex 从 $1 读 payload
        let args = name == "codex" ? [file.path, #"{"type":"agent-turn-complete","thread-id":"t1"}"#]
                                   : [file.path]
        let result = try run("/bin/bash", args, stdin: payload)
        return (FileManager.default.fileExists(atPath: marker.path), result.status)
    }

    /// 造一份 Claude Code 的 Stop 载荷。
    /// `tasks` 传 nil 表示整个 background_tasks 字段缺失（老版本 Claude Code 的样子）
    private func stopPayload(backgroundTasks tasks: String?, event: String? = "Stop") -> String {
        var parts = [#""session_id":"abc123""#]
        if let event { parts.append(#""hook_event_name":"\#(event)""#) }
        if let tasks { parts.append(#""background_tasks":\#(tasks)"#) }
        return "{\(parts.joined(separator: ","))}"
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

    // MARK: - 后台子任务没收口就别提醒

    /// 「主 Agent 回合结束」≠「任务完成」：派出后台子 Agent 的那一刻主回合就结束了，
    /// 触发一次货真价实的 Stop；此后每个子 Agent 完成还会各唤醒主循环一次、
    /// 各再触发一次 Stop。用户看到的就是「一个 sub Agent 干完就提醒，可任务还早着」
    func test后台子任务还在跑时不提醒() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let running = #"[{"id":"t1","type":"subagent","status":"running","description":"摸清槽位"}]"#
        let r = try deliver(scriptNamed: "claude", watching: probe.name,
                            payload: stopPayload(backgroundTasks: running))
        XCTAssertFalse(r.delivered, "后台还有子 Agent 在跑就提醒，正是这次要修的病")
        XCTAssertEqual(r.status, 0, "吞掉提醒也得安静地成功，非零会被 Claude Code 当成 hook 失败")
    }

    func test后台任务全部收口才提醒() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let r = try deliver(scriptNamed: "claude", watching: probe.name,
                            payload: stopPayload(backgroundTasks: "[]"))
        XCTAssertTrue(r.delivered, "空数组代表真的干完了，这一下必须响，否则提醒功能整个失效")
    }

    /// 老版本 Claude Code 的载荷根本没有这个字段。认不出来就得维持原行为——
    /// 不能因为读不到就把提醒全吞了
    func test没有background_tasks字段时照常提醒() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let r = try deliver(scriptNamed: "claude", watching: probe.name,
                            payload: stopPayload(backgroundTasks: nil))
        XCTAssertTrue(r.delivered, "字段缺失被当成「有后台任务」，老版本用户的提醒会全哑")
    }

    /// JSON 带不带空格因序列化实现而异，脚本先把空白压平再比对，换个排版不能就漏
    func test带空格的JSON排版一样认得出() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let spaced = #"{ "session_id" : "abc" , "background_tasks" : [ { "id" : "t1" } ] }"#
        let r = try deliver(scriptNamed: "claude", watching: probe.name, payload: spaced)
        XCTAssertFalse(r.delivered, "换一种 JSON 排版就认不出后台任务了")
    }

    /// 兜底：本脚本只处理主 Agent 的 Stop。ProNotch 目前只往 Stop 上注册，
    /// 但用户会自己往 hooks 里加东西（这台机器上 vibe-island 就挂了 13 个事件）
    func testClaude事件名不是Stop就丢弃() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let r = try deliver(scriptNamed: "claude", watching: probe.name,
                            payload: stopPayload(backgroundTasks: "[]", event: "SubagentStop"))
        XCTAssertFalse(r.delivered, "被挂到 SubagentStop 上也照报，等于没兜住")
        XCTAssertEqual(r.status, 0)
    }

    /// Kimi / Grok 的事件名取值没实证过，不能照搬 Claude 那套过滤——
    /// 万一它们发的不是 "Stop"，一过滤就把正常回调全吞了
    func testKimi和Grok不做事件名过滤() throws {
        let scripts = try installedScripts()
        for name in ["kimi", "grok"] {
            XCTAssertFalse(try XCTUnwrap(scripts[name]).contains("hook_event_name"),
                           "\(name) 的事件名取值没实证过，贸然过滤会把正常回调吞掉")
        }
    }

    /// Codex 走 notify + agent-turn-complete，与 Claude 的 Stop 完全两套机制，
    /// 载荷里没有 background_tasks 这类字段，子任务模型也不同——本轮不动它
    func testCodex本轮不接背景任务过滤() throws {
        let script = try XCTUnwrap(try installedScripts()["codex"])
        XCTAssertFalse(script.contains("background_tasks"),
                       "Codex 载荷里没这个字段，加了过滤只是白跑一趟且容易误伤")
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
