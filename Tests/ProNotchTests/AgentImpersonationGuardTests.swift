import XCTest
@testable import ProNotch

/// 顶着 claude 名义进来的事件必须自证出身，不然丢弃。
///
/// 由来（大梁老师 2026-08-09）：「终端里的 Grok Build 完成任务的时候，有时候会弹出
/// 黄色的光晕提醒，把它误认为是 Claude Code。」
///
/// 病灶：Grok Build 自带 Claude 兼容层，会**实时执行** `~/.claude/settings.json` 里的
/// 钩子。我们装给 Claude 的脚本被它调起，而 source 是装的时候写死的——ProNotch 收到的
/// 就是一条如假包换的 claude 事件。Grok 自家钩子随后又发一条真的，两条赛跑后到的定色，
/// 所以是「有时候」黄。
///
/// 判据：真 Claude Code 的每个 hook 事件都带指向 ~/.claude/ 的 transcript_path
/// （本机二进制 strings 有 10 处），Grok 的载荷里一个都没有（strings 0 处）。
/// 全部用例把脚本真跑起来看投递结果，不满足于文本里有没有那几行
final class AgentImpersonationGuardTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("impersonation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 载荷夹具

    /// 真 Claude Code 的 Stop 载荷：带指向 ~/.claude/ 的 transcript_path
    private let claudePayload =
        #"{"session_id":"abc","transcript_path":"/Users/x/.claude/projects/p/abc.jsonl","hook_event_name":"Stop","background_tasks":[]}"#

    /// Grok Build 借道时的载荷：事件名拼写与 Claude 相同，但没有 transcript_path
    private let grokImpersonation =
        #"{"session_id":"grok-1","hook_event_name":"Stop","background_tasks":[]}"#

    /// 未来若有别家带上 transcript_path，只要指向的不是 ~/.claude/ 一样要拦
    private let foreignTranscript =
        #"{"session_id":"g2","transcript_path":"/Users/x/.grok/sessions/g2.jsonl","hook_event_name":"Stop"}"#

    // MARK: - 完成提醒

    func test真Claude载荷照常投递() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        XCTAssertTrue(try deliver("claude", watching: probe.name, payload: claudePayload).delivered,
                      "出身校验把真 Claude 的完成提醒也吞了，提醒功能整个失效")
    }

    func test冒名载荷被丢弃_光晕不再张冠李戴() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let r = try deliver("claude", watching: probe.name, payload: grokImpersonation)
        XCTAssertFalse(r.delivered, "Grok 借道发的事件仍被当成 claude 投递，黄色光晕会继续张冠李戴")
        XCTAssertEqual(r.status, 0, "丢弃也得安静成功，非零会被调用方当成 hook 失败报错")
    }

    func test档案指向别家目录的也拦() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        XCTAssertFalse(try deliver("claude", watching: probe.name, payload: foreignTranscript).delivered)
    }

    /// Kimi / Grok 自家的脚本只被自家配置引用，没有被借道的入口；
    /// 它们的载荷本来就没有 transcript_path，照搬校验会把正常回调全吞掉
    func testKimi和Grok自家脚本不做出身校验() throws {
        let scripts = try installedScripts()
        for name in ["kimi", "grok"] {
            XCTAssertFalse(try XCTUnwrap(scripts[name]).contains("transcript_path"),
                           "\(name) 的载荷没有这个字段，加了校验等于把它自家的提醒全关掉")
        }
    }

    // MARK: - 开工信号

    func test开工信号同样验出身() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        XCTAssertFalse(try deliver("busy", watching: probe.name, payload: grokImpersonation).delivered,
                       "Grok 借道的开工信号被记成 claude，槽位和 Agent 页会显示错的家")
        XCTAssertTrue(try deliver("busy", watching: probe.name, payload: claudePayload).delivered,
                      "真 Claude 的开工信号不能误伤")
    }

    /// 共用脚本只对 claude 来源做校验：别家（如 grok 自报家门）的载荷没有 transcript_path
    func test别家来源的开工信号不受影响() throws {
        let probe = try startProbe()
        defer { probe.process.terminate() }
        let r = try deliver("busy", watching: probe.name, payload: grokImpersonation, source: "grok")
        XCTAssertTrue(r.delivered, "grok 自报家门的开工信号被误拦，它自己的状态显示就没了")
    }

    // MARK: - 夹具

    /// 装一套 hook 到临时目录，取回生成的脚本原文
    private func installedScripts() throws -> [String: String] {
        let paths = GlowHookPaths.rooted(at: tmp.path)
        for dir in [paths.scriptDir, paths.codexDir, paths.grokHooksDir,
                    (paths.claudeSettings as NSString).deletingLastPathComponent,
                    (paths.kimiConfig as NSString).deletingLastPathComponent] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try "model = \"kimi-k2\"\n".write(toFile: paths.kimiConfig, atomically: true, encoding: .utf8)
        for kind in [AgentKind.claude, .codex, .kimi, .grok] {
            XCTAssertTrue(GlowHookInstaller.setInstalled(kind, true, paths: paths),
                          "\(kind) hook 安装失败")
        }
        var out: [String: String] = [:]
        for (name, path) in ["claude": paths.claudeScript, "kimi": paths.kimiScript,
                             "grok": paths.grokScript, "busy": paths.busyScript] {
            out[name] = try String(contentsOfFile: path, encoding: .utf8)
        }
        return out
    }

    /// 把脚本的 open 换成落标记文件真跑一遍；共用的 busy 脚本经 $1 传来源
    private func deliver(_ name: String, watching process: String,
                         payload: String, source: String = "claude") throws
    -> (delivered: Bool, status: Int32, out: String) {
        var script = try XCTUnwrap(try installedScripts()[name])
        let slug = UUID().uuidString.prefix(8)
        let marker = tmp.appendingPathComponent("\(name)-\(slug)-delivered")
        script = script
            .replacingOccurrences(of: "pgrep -x ProNotch", with: "pgrep -x \(process)")
            .replacingOccurrences(of: #"open -g "$url""#, with: "touch '\(marker.path)'")
        let file = tmp.appendingPathComponent("\(name)-\(slug).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        var args = [file.path]
        if name == "busy" { args.append(source) }
        let result = try run("/bin/bash", args, stdin: payload)
        return (FileManager.default.fileExists(atPath: marker.path), result.status, result.out)
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

    private func run(_ tool: String, _ args: [String], stdin: String? = nil) throws
    -> (status: Int32, out: String) {
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
