import XCTest
@testable import ProNotch

/// 只有对话窗自己的任务跑完才点灯——Codex 起的其余线程收工一律不打扰。
///
/// 由来（大梁老师 2026-08-09）：「桌面端 Codex 调用子 Agent 完成任务的时候，还是会有
/// 光晕提醒。可实际上咱们需要的是对话窗口任务运行完毕才提醒，而不是过程中的
/// 子 Agent 完成了就提醒。」2026-08-16 桌面端升到 0.148 后又犯：「Codex 只要一开始
/// 运行，它就开始有这种呼吸的光晕提示。」
///
/// 病灶：notify 是全局配置，每个线程回合结束都发一条一模一样的 agent-turn-complete，
/// 载荷里没有任何主/内部标记。判据只能查线程自己的 rollout 档案（实机抓的 9 条载荷）：
/// 主对话有档案且 thread_source=user；子代理是 subagent；生成标题、写「活动摘要」
/// 这类桌面端内部任务**根本不落盘**——它们在你刚发完消息时就完成，光晕于是一开始就亮。
///
/// 因此判据是白名单：确认是主对话才放行。上一版靠匹配内部任务的提示词原文来挡，
/// 0.148 一改文案就整个空转，这组用例把「档案缺失」这一类也钉死。
///
/// 全部用例把转发器脚本真跑起来：假 HOME 里造档案，看投递结果
final class CodexNotifyFilterTests: XCTestCase {

    private var tmp: URL!
    /// 脚本里 `$HOME/.codex/sessions` 的假家目录
    private var home: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-sub-\(UUID().uuidString)")
        home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions/2026/08/09"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 用例

    /// 就是大梁老师踩的那一次：子代理干完一小段，光晕就亮
    func test子代理线程收工不点灯() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let tid = "019fe000-aaaa-7000-8000-000000000001"
        // 实证过的坑：子代理档案的 session_id 写的是**父线程** id，自己的 id 在 "id"
        // 字段并与文件名一致——脚本按文件名找档案，找的就是子线程自己的
        try writeRollout(ownID: tid, sessionID: "019fe000-bbbb-7000-8000-0000000000ff",
                         threadSource: "subagent")
        let r = try deliver(threadID: tid, watching: probe.name)
        XCTAssertFalse(r.delivered, "子代理收工还点灯，对话窗任务没完就被打扰——正是要修的病")
        XCTAssertEqual(r.status, 0, "吞掉提醒也得安静成功")
    }

    func test主对话线程照常点灯() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let tid = "019fe000-aaaa-7000-8000-000000000002"
        try writeRollout(ownID: tid, sessionID: tid, threadSource: "user")
        XCTAssertTrue(try deliver(threadID: tid, watching: probe.name).delivered,
                      "主对话的完成提醒被误吞，整个功能就哑了")
    }

    /// 桌面端 0.148 那次的病根：生成标题、写「活动摘要」这些内部线程不落盘，
    /// 而它们在你刚发完消息时就收工——放行就等于「一开始运行就亮」
    func test不落盘的内部任务线程不点灯() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        // 目录里得有别的会话档案，否则会走「落盘机制整个不可用」那条兜底
        try writeRollout(ownID: "019fe000-1111-7000-8000-00000000000a",
                         sessionID: "019fe000-1111-7000-8000-00000000000a", threadSource: "user")
        let r = try deliver(threadID: "019fe000-cccc-7000-8000-000000000003", watching: probe.name)
        XCTAssertFalse(r.delivered, "内部任务收工就点灯，光晕在你刚发完消息时就亮起来了")
        XCTAssertEqual(r.status, 0)
    }

    /// 会话目录一份档案都没有：落盘机制本身没在工作（CODEX_HOME 改了、会话记录关了），
    /// 这时判不了主次，照旧放行——宁可多亮一次，不能让整条提醒哑掉
    func test落盘机制不可用时放行() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        XCTAssertTrue(try deliver(threadID: "019fe000-cccc-7000-8000-000000000003",
                                  watching: probe.name).delivered)
    }

    /// 非 user 的取值一律不点灯（实时语音线程是实机见过的第三种），
    /// 这样引擎日后再添新类型，白名单会自动把它挡在外面
    func test非主对话来源一律不点灯() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let tid = "019fe000-ffff-7000-8000-000000000006"
        try writeRollout(ownID: tid, sessionID: tid, threadSource: "realtime_voice")
        XCTAssertFalse(try deliver(threadID: tid, watching: probe.name).delivered)
    }

    /// 归档过的会话续跑：档案挪进了平铺的 archived_sessions，一样要认得出是主对话
    func test归档会话的主对话照常点灯() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let tid = "019fe000-9999-7000-8000-000000000007"
        try writeRollout(ownID: tid, sessionID: tid, threadSource: "user", archived: true)
        XCTAssertTrue(try deliver(threadID: tid, watching: probe.name).delivered)
    }

    /// 老版本引擎的档案没有 thread_source 字段：读不出就放行，理由同上
    func test老档案没有thread_source字段时放行() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let tid = "019fe000-dddd-7000-8000-000000000004"
        try writeRollout(ownID: tid, sessionID: tid, threadSource: nil)
        XCTAssertTrue(try deliver(threadID: tid, watching: probe.name).delivered)
    }

    /// 载荷里抓不到 thread-id 时维持原行为（照常投递）——判别的前提没了，
    /// 不能顺手把提醒也关了
    func test载荷没有threadID时维持原行为() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let r = try deliver(payload: #"{"type":"agent-turn-complete"}"#, watching: probe.name)
        XCTAssertTrue(r.delivered)
    }

    /// 吞掉子代理提醒之后，脚本必须仍执行到末尾——后面挂着别人的 notify 转发链
    func test子代理被吞时转发链仍走到底() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let tid = "019fe000-eeee-7000-8000-000000000005"
        try writeRollout(ownID: tid, sessionID: "parent", threadSource: "subagent")

        var script = try forwarderScript()
        let end = tmp.appendingPathComponent("reached-end")
        script = patched(script, watching: probe.name, marker: tmp.appendingPathComponent("m"))
        script += "\ntouch '\(end.path)'\n"
        let file = tmp.appendingPathComponent("chain.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let r = try run("/bin/bash", [file.path, payloadFor(threadID: tid)],
                        env: ["HOME": home.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: end.path),
                      "吞提醒时提前退出了，别人的 notify 会被一起掐断")
        XCTAssertEqual(r.status, 0)
    }

    // MARK: - 夹具

    /// 造一份线程 rollout 档案，首行结构仿真实引擎（0.148.0-alpha.9）的 session_meta。
    /// `archived` 落到平铺的 archived_sessions（会话归档后档案就搬到那儿）
    private func writeRollout(ownID: String, sessionID: String, threadSource: String?,
                              archived: Bool = false) throws {
        var payload = #""session_id":"\#(sessionID)","id":"\#(ownID)","cwd":"/Users/x/proj","originator":"codex_work_desktop","cli_version":"0.148.0-alpha.9""#
        if let threadSource { payload += #","thread_source":"\#(threadSource)""# }
        payload += #","base_instructions":{"text":"You are Codex"}"#
        let line = #"{"timestamp":"2026-08-09T00:00:00.000Z","type":"session_meta","payload":{\#(payload)}}"#
        let dir = home.appendingPathComponent(
            archived ? ".codex/archived_sessions" : ".codex/sessions/2026/08/09")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2026-08-09T00-00-00-\(ownID).jsonl")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func payloadFor(threadID: String) -> String {
        #"{"type":"agent-turn-complete","thread-id":"\#(threadID)","turn-id":"x","cwd":"/Users/x/proj"}"#
    }

    /// 装一次 hook 拿到转发器脚本原文
    private func forwarderScript() throws -> String {
        let paths = GlowHookPaths.rooted(at: tmp.path)
        for dir in [paths.scriptDir, paths.codexDir] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        return try String(contentsOfFile: paths.codexScript, encoding: .utf8)
    }

    private func patched(_ script: String, watching process: String, marker: URL) -> String {
        script
            .replacingOccurrences(of: "pgrep -x ProNotch", with: "pgrep -x \(process)")
            .replacingOccurrences(of: #"open -g "$url""#, with: "touch '\(marker.path)'")
    }

    /// 用假 HOME 跑一遍转发器，回报是否投递
    private func deliver(threadID: String? = nil, payload: String? = nil,
                         watching process: String) throws -> (delivered: Bool, status: Int32) {
        let slug = UUID().uuidString.prefix(8)
        let marker = tmp.appendingPathComponent("delivered-\(slug)")
        let script = patched(try forwarderScript(), watching: process, marker: marker)
        let file = tmp.appendingPathComponent("codex-\(slug).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let arg = payload ?? payloadFor(threadID: threadID ?? "")
        let r = try run("/bin/bash", [file.path, arg], env: ["HOME": home.path])
        return (FileManager.default.fileExists(atPath: marker.path), r.status)
    }

    private func startProbe() throws -> (name: String, process: Process) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        for _ in 0..<50 where try run("/usr/bin/pgrep", ["-x", "sleep"]).status != 0 {
            usleep(20_000)
        }
        return ("sleep", p)
    }

    private func run(_ tool: String, _ args: [String], env: [String: String]? = nil) throws
    -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let env {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
