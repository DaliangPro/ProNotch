import XCTest
@testable import ProNotch

/// Codex 子代理线程收工不点灯——只有对话窗自己的任务跑完才提醒。
///
/// 由来（大梁老师 2026-08-09）：「桌面端 Codex 调用子 Agent 完成任务的时候，还是会有
/// 光晕提醒。可实际上咱们需要的是对话窗口任务运行完毕才提醒，而不是过程中的
/// 子 Agent 完成了就提醒。」
///
/// 病灶：notify 是全局配置，每个线程（包括子代理线程）回合结束都发一条一模一样的
/// agent-turn-complete，载荷里没有任何主/子标记（引擎二进制实证，只带 thread-id /
/// turn-id / cwd 等几个键）。唯一判据在线程自己的 rollout 档案头部：thread_source
/// 字段 user=主对话、subagent=子代理（本机 633 份会话实证仅这两种取值）。
///
/// 全部用例把转发器脚本真跑起来：假 HOME 里造档案，看投递结果
final class CodexSubagentFilterTests: XCTestCase {

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

    /// 档案找不到（会话目录被挪、CODEX_HOME 改了）就当主对话放行——
    /// 宁可多亮一次，不能吞正主的提醒
    func test档案找不到时放行() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        XCTAssertTrue(try deliver(threadID: "019fe000-cccc-7000-8000-000000000003",
                                  watching: probe.name).delivered)
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

    /// 造一份线程 rollout 档案，首行结构仿真实引擎（0.147.0）的 session_meta
    private func writeRollout(ownID: String, sessionID: String, threadSource: String?) throws {
        var payload = #""session_id":"\#(sessionID)","id":"\#(ownID)","cwd":"/Users/x/proj","originator":"Codex Desktop","cli_version":"0.147.0""#
        if let threadSource { payload += #","thread_source":"\#(threadSource)""# }
        payload += #","base_instructions":{"text":"You are Codex"}"#
        let line = #"{"timestamp":"2026-08-09T00:00:00.000Z","type":"session_meta","payload":{\#(payload)}}"#
        let file = home.appendingPathComponent(
            ".codex/sessions/2026/08/09/rollout-2026-08-09T00-00-00-\(ownID).jsonl")
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
