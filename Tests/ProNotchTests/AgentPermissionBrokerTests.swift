import XCTest
@testable import ProNotch

/// 「在刘海上直接拍板」的经纪层。
///
/// 这里每一条断言都对着同一件事：**大梁老师在卡上按的那一下，必须变成 Claude Code 认得的答复**。
/// 拼错一个键名、少一层嵌套、`updatedPermissions` 没原样回传——上游一律当成「没决策」，
/// 用户看到的就是「我在刘海上按了允许，终端还是又问了我一遍」，而且毫无报错可查。
///
/// 输出契约与规则形状都是从本机 claude 二进制里抠出来的（`hookSpecificOutput.decision`、
/// `{type:"addRules",rules:[{toolName,ruleContent}],behavior,destination}`），不是猜的
final class AgentPermissionBrokerTests: XCTestCase {

    private var tmp: URL!
    private var broker: AgentPermissionBroker!
    private var dir: String!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perm-broker-\(UUID().uuidString)")
        let paths = GlowHookPaths.rooted(at: tmp.path)
        dir = paths.permissionDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        broker = AgentPermissionBroker(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private let id = String(repeating: "ab", count: 16)   // 32 位 hex

    private func writeRequest(_ json: String, id: String? = nil) throws {
        try json.write(toFile: dir + "/\((id ?? self.id)).request.json",
                       atomically: true, encoding: .utf8)
    }

    private func response(_ id: String? = nil) -> [String: Any]? {
        let path = dir + "/\((id ?? self.id)).response.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func decision(_ id: String? = nil) -> [String: Any]? {
        (response(id)?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    }

    private static let suggestion = """
    [{"type":"addRules","behavior":"allow","destination":"localSettings",\
    "rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}]
    """

    // MARK: - id 校验

    /// id 来自 URL。不校验就等于让调用方拼路径——`req=../../../x` 能让我们读写交换目录之外的文件。
    /// 令牌认证在更前面已经过了，这一层依然要有
    func test只认32位小写hex的id() {
        XCTAssertTrue(AgentPermissionBroker.isValidID(id))
        for bad in ["", "abc", "../../etc/passwd", String(repeating: "A", count: 32),
                    String(repeating: "z", count: 32), String(repeating: "a", count: 33),
                    "a/b" + String(repeating: "c", count: 29)] {
            XCTAssertFalse(AgentPermissionBroker.isValidID(bad), "\(bad) 不该被放行")
        }
    }

    func test路径穿越的id取不到也写不了() throws {
        XCTAssertNil(broker.take(id: "../../../etc/passwd"))
        XCTAssertFalse(broker.release(id: "../../../tmp/pwned"))
    }

    // MARK: - 解请求

    func test解出工具名与要给人看的详情() throws {
        try writeRequest("""
        {"tool_name":"Bash","tool_input":{"command":"git push origin main","description":"推一下"},
         "session_id":"s-1","cwd":"/Users/x/我的 项目","permission_suggestions":\(Self.suggestion)}
        """)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertEqual(r.tool, "Bash")
        XCTAssertEqual(r.detail, "git push origin main", "Bash 该看命令，不是 description")
        XCTAssertEqual(r.session, "s-1")
        XCTAssertEqual(r.project, "我的 项目", "项目名取 cwd 末段，中文空格都不能坏")
        XCTAssertEqual(r.options.map(\.title), ["不再询问"])
        XCTAssertEqual(r.options.map(\.detail), ["Bash(git push:*)"])
        XCTAssertTrue(r.canAllowAlways)
    }

    /// 每个工具该看哪个入参不一样。挑错了卡上就是一句看不懂的话，
    /// 而用户正要凭它决定放不放行
    func test各类工具各看自己的关键入参() {
        let cases: [(String, [String: Any], String)] = [
            ("Write", ["file_path": "/tmp/a.txt", "content": "整个文件内容"], "/tmp/a.txt"),
            ("Edit", ["file_path": "/tmp/b.swift"], "/tmp/b.swift"),
            ("NotebookEdit", ["notebook_path": "/tmp/c.ipynb"], "/tmp/c.ipynb"),
            ("WebFetch", ["url": "https://example.com/x", "prompt": "读一下"], "https://example.com/x"),
            ("WebSearch", ["query": "刘海 通知"], "刘海 通知"),
            ("Grep", ["pattern": "TODO", "path": "/tmp"], "TODO"),
        ]
        for (tool, input, expected) in cases {
            XCTAssertEqual(AgentPermissionBroker.detail(tool: tool, input: input), expected,
                           "\(tool) 挑错了入参")
        }
    }

    /// 数组套字典的入参（AskUserQuestion 的 questions、TodoWrite 的 todos）要挑出人话。
    /// 少这一层就掉到压平 JSON：大梁老师实测看到的就是一坨带转义引号的入参
    func test数组套字典的入参挑出人话() {
        let questions: [String: Any] = ["questions": [
            ["header": "版本号", "question": "版本号定哪个？", "multiSelect": false],
            ["header": "发布", "question": "现在发吗？"],
        ]]
        XCTAssertEqual(AgentPermissionBroker.detail(tool: "AskUserQuestion", input: questions),
                       "版本号定哪个？ / 现在发吗？")
        let todos: [String: Any] = ["todos": [["content": "跑一遍测试", "status": "pending"]]]
        XCTAssertEqual(AgentPermissionBroker.detail(tool: "TodoWrite", input: todos), "跑一遍测试")
        // 一项都挑不出来时仍要落到压平兜底，不能返回空
        let opaque: [String: Any] = ["questions": [["header": "只有标题"]]]
        XCTAssertTrue(AgentPermissionBroker.detail(tool: "AskUserQuestion", input: opaque)
            .hasPrefix("{"), "挑不出人话时该退回压平 JSON")
    }

    /// MCP 工具与将来的新工具入参名五花八门，一个都不命中时压平 JSON——
    /// 看不出是什么也别给一片空白，用户至少还能凭它判断
    func test认不出的工具压平入参兜底() {
        let flat = AgentPermissionBroker.detail(tool: "mcp__x__do", input: ["zzz": 1, "aaa": "b"])
        XCTAssertEqual(flat, #"{"aaa":"b","zzz":1}"#, "键要排序，否则每次渲染顺序都在跳")
        XCTAssertEqual(AgentPermissionBroker.detail(tool: "Unknown", input: [:]), "")
    }

    /// 命令可以是一整篇脚本、写文件的入参可以是整个文件内容。不截就把整块屏幕顶满
    func test超长详情被截断() {
        let long = String(repeating: "x", count: 5000)
        let out = AgentPermissionBroker.detail(tool: "Bash", input: ["command": long])
        XCTAssertEqual(out.count, AgentPermissionBroker.detailLimit + 1, "多的那一个字符是省略号")
        XCTAssertTrue(out.hasSuffix("…"))
    }

    /// 缺工具名等于卡面没了主语，整张卡无从下笔——这时只能放回终端问
    func test缺工具名或坏JSON时解不出() throws {
        try writeRequest(#"{"tool_input":{"command":"ls"}}"#)
        XCTAssertNil(broker.take(id: id))
        try writeRequest("这不是 JSON")
        XCTAssertNil(broker.take(id: id))
    }

    /// 读完立刻删请求文件：脚本只写请求、只读答复，从不回头读它。
    /// 而这个「消失」同时是脚本判断「投递成功」的唯一信号（见拍板脚本第一段等待）
    func test取走后请求文件即刻消失() throws {
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        XCTAssertNotNil(broker.take(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/\(id).request.json"))
        XCTAssertNil(broker.take(id: id), "取过的请求不能再取出来一次")
    }

    /// 上游没给建议规则时不能显示「不再询问」：按下去写不进任何规则，是个假按钮
    func test没有建议规则时不能不再询问() throws {
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"ls"},"permission_suggestions":[]}"#)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertFalse(r.canAllowAlways)
        XCTAssertTrue(r.options.isEmpty)
    }

    /// 规则文案照抄上游在设置里用的写法，用户在两处看到的才是同一句话
    func test规则文案沿用上游写法() {
        XCTAssertEqual(AgentPermissionBroker.ruleLabels([
            ["rules": [["toolName": "Bash", "ruleContent": "git push:*"]]],
            ["rules": [["toolName": "WebFetch"]]],
        ]), ["Bash(git push:*)", "WebFetch(*)"])
    }

    // MARK: - 一条建议一个按钮

    /// 上游一次可能给好几条建议，粒度还完全不同：往允许目录之外写文件时它同时给
    /// `addDirectories`（把这个目录加进清单）和 `setMode: acceptEdits`（本轮会话自动接受所有编辑），
    /// 而终端里那是两个独立选项。合成一个按钮全塞回去，等于替大梁老师多授了一大截权
    func test多条建议各出一个按钮() throws {
        try writeRequest("""
        {"tool_name":"Write","tool_input":{"file_path":"/Users/x/OrbitOS Vault/a.md"},
         "permission_suggestions":[
           {"type":"addDirectories","directories":["/Users/x/OrbitOS Vault"],"destination":"session"},
           {"type":"setMode","mode":"acceptEdits","destination":"session"}]}
        """)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertEqual(r.options.map(\.title), ["本轮会话允许访问目录", "本轮会话自动接受所有编辑"],
                       "两条建议必须各是一个按钮，顺序照上游给的来")
        XCTAssertEqual(r.options.first?.detail, "OrbitOS Vault", "目录只显示末段，全路径把卡撑爆")
    }

    /// 按下第 n 个按钮就只写第 n 条建议。写多了就是替用户多授权，
    /// 而他按的那一下明明只同意了一件事
    func test按下某条建议只回传它自己() throws {
        try writeRequest("""
        {"tool_name":"Write","tool_input":{"file_path":"/tmp/a"},
         "permission_suggestions":[
           {"type":"addDirectories","directories":["/tmp"],"destination":"session"},
           {"type":"setMode","mode":"acceptEdits","destination":"session"}]}
        """)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertTrue(broker.answer(r, .allowAlways(1)))

        let updated = try XCTUnwrap(decision()?["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(updated.count, 1, "只该写按下的那一条")
        XCTAssertEqual(updated.first?["type"] as? String, "setMode")
        XCTAssertNil(updated.first?["directories"], "另一条建议不该跟着混进来")
    }

    /// 换权限模式那条的措辞必须把范围说清楚：它不是放行这一次，
    /// 而是这一轮会话里同类操作全部不再问
    func test换模式的按钮写明范围() {
        let titles = ["acceptEdits", "dontAsk", "bypassPermissions", "plan"].map {
            AgentPermissionBroker.option(["type": "setMode", "mode": $0])?.title
        }
        XCTAssertEqual(titles, ["本轮会话自动接受所有编辑", "本轮会话不再询问任何操作",
                                "本轮会话跳过全部授权", "切回计划模式"])
    }

    /// 认不出的建议类型直接不摆按钮：按下去等于替用户同意一件我们自己都说不清的事。
    /// 上游加了新类型时，宁可少一个按钮，也不能出现一个语义不明的按钮
    func test认不出的建议不摆按钮() {
        for bad: [String: Any] in [["type": "removeRules"], ["type": "setMode", "mode": "新模式"],
                                   ["type": "addRules", "rules": []],
                                   ["type": "addDirectories", "directories": []], [:]] {
            XCTAssertNil(AgentPermissionBroker.option(bad), "\(bad) 不该变成按钮")
        }
    }

    /// destination=session 只管这一轮，写进设置的才是永久。差别不小，必须写在按钮上
    func test本轮会话的范围写在按钮上() {
        let rules: [String: Any] = ["type": "addRules",
                                    "rules": [["toolName": "Bash", "ruleContent": "ls:*"]]]
        XCTAssertEqual(AgentPermissionBroker.option(rules)?.title, "不再询问")
        XCTAssertEqual(
            AgentPermissionBroker.option(rules.merging(["destination": "session"]) { _, b in b })?.title,
            "本轮会话不再询问")
    }

    // MARK: - 拼答复

    func test允许一次只说允许() throws {
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"ls"},"permission_suggestions":\#(Self.suggestion)}"#)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertTrue(broker.answer(r, .allowOnce))

        let d = try XCTUnwrap(decision())
        XCTAssertEqual(d["behavior"] as? String, "allow")
        XCTAssertNil(d["updatedPermissions"], "「一次」不该顺手把规则写进用户配置")
        // 外层键名错一个字，上游就当成没决策——它不会报错，只会又弹一次终端框
        XCTAssertEqual((response()?["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String,
                       "PermissionRequest")
    }

    /// 「不再询问」要回传的规则是入参里那份建议的**原样透传**。
    /// 自己重新建模等于抄一份上游的私有 schema，它加个字段我们就写出半条非法规则
    func test不再询问原样回传建议规则() throws {
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"git push"},"permission_suggestions":\#(Self.suggestion)}"#)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertTrue(broker.answer(r, .allowAlways(0)))

        let d = try XCTUnwrap(decision())
        XCTAssertEqual(d["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(d["updatedPermissions"] as? [[String: Any]])
        let expected = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(Self.suggestion.utf8)) as? [[String: Any]])
        XCTAssertEqual(updated as NSArray, expected as NSArray, "规则被改写过，写进配置的就不是它建议的那条")
    }

    /// 拒绝不带 interrupt：终端里点「否」的默认行为也只是拒掉这一次、让它换个做法。
    /// 卡上没有输入框可以写「你该怎么做」，打断整轮反而更难收场
    func test拒绝不打断整轮() {
        let data = AgentPermissionBroker.responseJSON(.deny, options: [])
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let d = (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(d?["behavior"] as? String, "deny")
        XCTAssertNotNil(d?["message"], "不说一句为什么，模型只知道被拒了")
        XCTAssertNil(d?["interrupt"])
    }

    /// 「打开终端」＝不作决策。上游只认 allow / deny，其余一律落回终端弹框，
    /// 空 stdout 正好是这个效果——不必另发明一种信号
    func test打开终端写的是空文件() throws {
        XCTAssertEqual(AgentPermissionBroker.responseJSON(.terminal, options: []), Data())
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertTrue(broker.answer(r, .terminal))

        let path = dir + "/\(id).response.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "文件必须在，脚本等的就是它出现")
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data())
    }

    /// 建议规则解不出来、或按到了越界的下标时退化成「允许一次」：宁可少同意一条规则，
    /// 也不能写出一份让整条答复作废的 JSON——那会让用户以为按了没反应
    func test建议规则坏掉或越界时退成允许一次() throws {
        let broken = AgentPermissionOption(title: "不再询问", detail: nil, payload: Data("坏的".utf8))
        for (decision, options) in [(AgentPermissionDecision.allowAlways(0), [broken]),
                                    (.allowAlways(3), [broken]),
                                    (.allowAlways(0), [])] {
            let data = AgentPermissionBroker.responseJSON(decision, options: options)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let d = try XCTUnwrap(
                (json["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
            XCTAssertEqual(d["behavior"] as? String, "allow")
            XCTAssertNil(d["updatedPermissions"], "\(decision) 该退成「允许一次」")
        }
    }

    /// 答复文件权限 0600：同机别的用户能读到的话，等于把用户在跑什么命令摊给他看
    func test答复文件不给其他人读() throws {
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertTrue(broker.answer(r, .allowOnce))
        let mode = (try FileManager.default.attributesOfItem(atPath: dir + "/\(id).response.json")[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)
    }

    /// 脚本每 0.2 秒 `[ -f ]` 一次。直接往目标路径写，写一半就被它看见，
    /// 等于喂给上游一段非法 JSON——所以只能临时文件写完再 rename
    func test答复原子落地_不留临时文件() throws {
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        let r = try XCTUnwrap(broker.take(id: id))
        XCTAssertTrue(broker.answer(r, .allowOnce))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "临时文件没清干净：\(leftovers)")
    }

    // MARK: - 重启收尾

    /// 卡的状态只在内存里，ProNotch 一重启就没人来答了；而脚本认的是进程名，
    /// 看见新进程会继续等下去，最长等到钩子超时。开机就得放它们回终端问
    func test启动时把残留请求放回终端询问() throws {
        let other = String(repeating: "cd", count: 16)
        try writeRequest(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        try writeRequest(#"{"tool_name":"Write","tool_input":{"file_path":"/tmp/a"}}"#, id: other)

        XCTAssertEqual(broker.releaseOrphans(), 2)
        for each in [id, other] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/\(each).request.json"))
            XCTAssertEqual(FileManager.default.contents(atPath: dir + "/\(each).response.json"),
                           Data(), "放行写的是空答复，终端才会照旧弹框")
        }
    }

    /// 刚写下的答复不能扫掉：脚本 0.2 秒内就会取走并自行删除，
    /// 扫早了它就永远等不到，等于把刚放行的那一条又锁回去
    func test收尾不动新鲜的答复文件() throws {
        try #"{"x":1}"#.write(toFile: dir + "/\(id).response.json", atomically: true, encoding: .utf8)
        _ = broker.releaseOrphans()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/\(id).response.json"))
    }

    /// 陈旧答复的主人早就不在了（被强杀那一下脚本自己的清理也跑不到），留着只是垃圾
    func test收尾清掉陈旧答复文件() throws {
        let path = dir + "/\(id).response.json"
        try #"{"x":1}"#.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: path)
        _ = broker.releaseOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func test交换目录不存在时收尾不炸() {
        let ghost = AgentPermissionBroker(paths: .rooted(at: tmp.path + "/nope"))
        XCTAssertEqual(ghost.releaseOrphans(), 0)
    }

    // MARK: - 能力口径

    /// 提醒只要上游肯发信号，拍板还要求上游肯**收答复**——严一档。
    /// 实测：Kimi 的同名事件走 fireAndForgetTrigger（发完就走），Codex / Grok 没这个事件
    func test只有ClaudeCode能在卡上拍板() {
        XCTAssertTrue(AgentKind.claude.supportsPermissionCard)
        for kind in [AgentKind.kimi, .codex, .grok] {
            XCTAssertFalse(kind.supportsPermissionCard, "\(kind) 收不了答复，摆按钮就是骗人")
        }
        // 能拍板的必然也能提醒，反过来不成立
        for kind in AgentKind.allCases where kind.supportsPermissionCard {
            XCTAssertTrue(kind.supportsWaitNotice)
        }
    }
}
