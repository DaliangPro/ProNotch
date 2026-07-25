import Foundation

/// 一条待拍板的授权请求：hook 写下的 `<id>.request.json` 里能给人看、能回传的那部分。
///
/// 只留这几样：其余字段（tool_use_id / transcript_path / permission_mode…）刘海卡上用不着，
/// 多解一个就多一个要跟着上游改的地方
struct AgentPermissionRequest: Equatable, Sendable {
    /// 交换文件的 id（脚本用 16 字节随机数生成），答复要写回同一个 id
    let id: String
    /// 工具名：Bash / Write / WebFetch / mcp__…
    let tool: String
    /// 给人看的一行详情（Bash 看命令、写文件看路径、抓网页看 URL）
    let detail: String
    /// Claude 的 session_id，用于点「打开终端」时跳准那个会话
    let session: String
    /// 项目名（cwd 末段）
    let project: String
    /// 上游给的「不再询问」建议，一条一个按钮（见 `AgentPermissionOption`）
    let options: [AgentPermissionOption]

    /// 能不能「不再询问」：得上游真给了看得懂的建议才行（有些工具不给）
    var canAllowAlways: Bool { !options.isEmpty }
}

/// 上游给的一条建议 ＝ 卡上一个按钮。
///
/// 必须一条一个按钮、按下只写它自己那条：实测上游一次可能给好几条，粒度还完全不同——
/// 往「允许目录」之外写文件时它同时给 `addDirectories`（把这个目录加进允许清单）
/// 和 `setMode: acceptEdits`（本轮会话自动接受所有编辑），而终端里那是两个独立选项。
/// 一个按钮全塞回去，等于替大梁老师多授了一大截权
struct AgentPermissionOption: Equatable, Sendable {
    /// 按钮标题：按上游语义写，不自己发明说法
    let title: String
    /// 副标题：规则原文 / 目录名。照抄上游自己的写法，两处看到的是同一句
    let detail: String?
    /// 只回传这一条建议的原始 JSON（数组里的那一个对象）。不解释它的 schema，原样搬——
    /// 那是上游私有格式（`{type,rules,behavior,destination}`），照搬才不会因为它加字段而写废
    let payload: Data
}

/// 卡上各个按钮的答复
enum AgentPermissionDecision: Equatable, Sendable {
    /// 允许一次
    case allowOnce
    /// 按下第几条建议（「不再询问 Bash(git push:*)」这类），只写它自己那条
    case allowAlways(Int)
    /// 拒绝
    case deny
    /// 打开终端：不作决策，让终端照旧弹框
    case terminal

    /// 写日志用的短名。规则原文不进日志（那是用户在跑什么），只留按了哪一类
    var logLabel: String {
        switch self {
        case .allowOnce: return "allowOnce"
        case .allowAlways(let index): return "allowAlways#\(index)"
        case .deny: return "deny"
        case .terminal: return "terminal"
        }
    }
}

/// 拍板请求的经纪层：读 hook 写下的请求、把答复原子地写回去。
///
/// 为什么走文件不走 URL：入参里的 `tool_input` 可能是整个文件内容，
/// `permission_suggestions` 是要原样回传的嵌套 JSON——这两样都塞不进 URL，bash 也解不动。
/// 于是脚本只当一根管子（写请求 → 投一条带 id 的 URL → 等答复 → 原样吐出），
/// 全部 JSON 解析与拼装都在这里做。
///
/// 无状态 struct：路径可注入，纯文件操作，测试能整套跑在临时目录里
struct AgentPermissionBroker: Sendable {
    let paths: GlowHookPaths

    init(paths: GlowHookPaths = .production) {
        self.paths = paths
    }

    // MARK: - 校验

    private static let hexDigits = Set("0123456789abcdef")

    /// id 必须是脚本生成的 32 位小写 hex。
    ///
    /// 这个值来自 URL——不校验就等于让调用方拼路径，`req=../../x` 能让我们读写交换目录之外的文件。
    /// 令牌认证在更前面已经过了，这一层依然要有：便宜，且封死一整类问题
    static func isValidID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { hexDigits.contains($0) }
    }

    // MARK: - 解析请求

    /// 工具名 → 该看哪个入参
    private static let detailKeys: [String: String] = [
        "Bash": "command",
        "Write": "file_path", "Edit": "file_path", "MultiEdit": "file_path", "Read": "file_path",
        "NotebookEdit": "notebook_path",
        "WebFetch": "url", "WebSearch": "query",
        "Glob": "pattern", "Grep": "pattern",
        "Task": "description",
    ]

    /// 兜底顺序：MCP 工具（`mcp__server__tool`）和将来的新工具入参名五花八门，
    /// 但真正想给人看的那一项通常就在这几个里；一个都不命中才压平整个 JSON
    private static let fallbackKeys = ["command", "file_path", "path", "url", "query",
                                       "pattern", "prompt", "description"]

    /// 卡上留给详情的长度。命令可以是一整篇脚本、写文件的入参可以是整个文件内容——
    /// 不截就把整块屏幕顶满
    static let detailLimit = 240

    static func truncate(_ text: String) -> String {
        text.count <= detailLimit ? text : String(text.prefix(detailLimit)) + "…"
    }

    /// 从入参里挑一行给人看的详情
    static func detail(tool: String, input: [String: Any]) -> String {
        for key in [detailKeys[tool]].compactMap({ $0 }) + fallbackKeys {
            guard let raw = input[key] as? String else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return truncate(text) }
        }
        // 压平兜底：看不出是什么至少也别是空白一片，用户还能凭它判断要不要放行
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return truncate(text)
    }

    /// 建议规则 → 给人看的写法。
    /// 取的正是 Claude Code 自己在设置里用的格式（`toolName(ruleContent)`，
    /// 没有 ruleContent 时 `toolName(*)`）——照抄它，用户在两处看到的才是同一句话
    static func ruleLabels(_ suggestions: [[String: Any]]) -> [String] {
        suggestions.flatMap { suggestion -> [String] in
            (suggestion["rules"] as? [[String: Any]] ?? []).compactMap { rule in
                guard let tool = rule["toolName"] as? String, !tool.isEmpty else { return nil }
                let content = rule["ruleContent"] as? String ?? ""
                return "\(tool)(\(content.isEmpty ? "*" : content))"
            }
        }
    }

    /// 一条建议 → 一个按钮的文案。
    ///
    /// 照上游自己的语义翻，别另起说法：终端里给的是「Yes, and don't ask again for
    /// Bash(git push:*)」和「Yes, allow all edits during this session」，
    /// 卡上就得是同一件事，否则同一次授权在两处含义不同。
    /// 认不出的类型直接不摆按钮——按下去等于替用户同意一件我们自己都说不清的事
    static func option(_ suggestion: [String: Any]) -> AgentPermissionOption? {
        guard let payload = try? JSONSerialization.data(withJSONObject: suggestion) else { return nil }
        // destination=session 只管这一轮会话，写进设置的才是永久；差别不小，必须写在按钮上
        let scope = (suggestion["destination"] as? String) == "session" ? "本轮会话" : ""
        switch suggestion["type"] as? String ?? "" {
        case "addRules", "replaceRules":
            let labels = ruleLabels([suggestion])
            guard !labels.isEmpty else { return nil }
            return AgentPermissionOption(title: scope + "不再询问",
                                         detail: labels.joined(separator: " "), payload: payload)
        case "setMode":
            guard let title = modeTitle(suggestion["mode"] as? String ?? "") else { return nil }
            return AgentPermissionOption(title: title, detail: nil, payload: payload)
        case "addDirectories":
            let dirs = (suggestion["directories"] as? [String] ?? [])
                .map { ($0 as NSString).lastPathComponent }
                .filter { !$0.isEmpty }
            guard !dirs.isEmpty else { return nil }
            return AgentPermissionOption(title: scope + "允许访问目录",
                                         detail: dirs.joined(separator: " "), payload: payload)
        default:
            return nil
        }
    }

    /// 换权限模式那条建议的说法。措辞必须把「范围有多大」说清楚：
    /// 它不是放行这一次，而是这一轮会话里同类操作全部不再问
    private static func modeTitle(_ mode: String) -> String? {
        switch mode {
        case "acceptEdits": return "本轮会话自动接受所有编辑"
        case "dontAsk": return "本轮会话不再询问任何操作"
        case "bypassPermissions": return "本轮会话跳过全部授权"
        case "plan": return "切回计划模式"
        default: return nil
        }
    }

    /// 解请求 JSON。缺工具名就当解不出——那是卡面的主语，没有它整张卡无从下笔
    static func parse(_ data: Data, id: String) -> AgentPermissionRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool_name"] as? String, !tool.isEmpty else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let raw = obj["permission_suggestions"] as? [[String: Any]] ?? []
        let cwd = obj["cwd"] as? String ?? ""
        return AgentPermissionRequest(
            id: id, tool: tool, detail: detail(tool: tool, input: input),
            session: obj["session_id"] as? String ?? "",
            project: cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent,
            options: raw.compactMap(option))
    }

    // MARK: - 拼答复

    /// 空 Data ＝「不作决策」。
    ///
    /// 上游的判定是 `if (result.behavior === "allow" || "deny")` 才接手，其余一律落回终端弹框——
    /// 空 stdout 正好是这个效果，「打开终端」不必另发明一种信号
    static func responseJSON(_ decision: AgentPermissionDecision,
                             options: [AgentPermissionOption]) -> Data {
        var inner: [String: Any]
        switch decision {
        case .terminal:
            return Data()
        case .deny:
            // 不带 interrupt：终端里点「否」的默认行为也只是拒掉这一次、让它换个做法，
            // 而卡上没有输入框可以写「你该怎么做」，打断整轮反而更难收场
            inner = ["behavior": "deny", "message": "用户在 ProNotch 刘海上拒绝了这次授权"]
        case .allowOnce:
            inner = ["behavior": "allow"]
        case .allowAlways(let index):
            inner = ["behavior": "allow"]
            // 越界或解不出就退化成「允许一次」：宁可少同意一条，也不能写出让整份答复作废的 JSON
            if options.indices.contains(index),
               let rule = try? JSONSerialization.jsonObject(with: options[index].payload) {
                inner["updatedPermissions"] = [rule]
            }
        }
        let payload: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": inner],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    // MARK: - 文件往来

    private func requestPath(_ id: String) -> String { paths.permissionDir + "/\(id).request.json" }
    private func responsePath(_ id: String) -> String { paths.permissionDir + "/\(id).response.json" }

    /// 取走一条请求。
    ///
    /// 读完就删是有意的：脚本只写请求、只读答复，从不回头读请求，所以删早了不碍着它；
    /// 而留着就得另想办法回收——ProNotch 被强杀那一下，脚本自己的清理也跑不到
    func take(id: String) -> AgentPermissionRequest? {
        guard Self.isValidID(id) else { return nil }
        let path = requestPath(id)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        try? FileManager.default.removeItem(atPath: path)
        return Self.parse(data, id: id)
    }

    /// 落一条答复
    @discardableResult
    func answer(_ request: AgentPermissionRequest, _ decision: AgentPermissionDecision) -> Bool {
        write(id: request.id, decision: decision, options: request.options)
    }

    /// 放行：写一份空答复让终端照旧弹框。请求解析不出来、用户关了这个提醒、
    /// 或宿主本来就在眼前时走这条——绝不能一声不响地不答，那会让终端也不弹框、整轮干等
    @discardableResult
    func release(id: String) -> Bool {
        write(id: id, decision: .terminal, options: [])
    }

    /// 原子写：临时文件 → rename。脚本每 0.2 秒 `[ -f ]` 一次，
    /// 直接往目标路径写，写一半就被它看见，等于喂它一段非法 JSON
    private func write(id: String, decision: AgentPermissionDecision,
                       options: [AgentPermissionOption]) -> Bool {
        guard Self.isValidID(id) else { return false }
        let fm = FileManager.default
        let final = responsePath(id)
        let temp = paths.permissionDir + "/\(id).response.tmp"
        let data = Self.responseJSON(decision, options: options)
        guard fm.createFile(atPath: temp, contents: data,
                            attributes: [.posixPermissions: 0o600]) else { return false }
        do {
            // rename 覆盖同名是原子的，但 FileManager.moveItem 见到同名会直接抛
            if fm.fileExists(atPath: final) { try? fm.removeItem(atPath: final) }
            try fm.moveItem(atPath: temp, toPath: final)
            return true
        } catch {
            try? fm.removeItem(atPath: temp)
            return false
        }
    }

    /// 启动时收尾：把上一条命留下的请求全部放行成「照旧弹终端框」，并清掉陈旧答复。
    ///
    /// 卡的状态只在内存里（这是个「此刻」的信号，存盘恢复出来只会误导人），
    /// 所以 ProNotch 一重启，还挂着的那几条就再也没人来答了；而脚本认的是进程名，
    /// 看见新进程会继续等下去，最长等到 hook 自己的超时。与其让它干等，不如开机就放它走。
    ///
    /// 答复文件只删陈旧的：刚写下的那些，脚本 0.2 秒内就会取走并自行删除
    @discardableResult
    func releaseOrphans(staleAfter seconds: TimeInterval = 1800, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.permissionDir) else { return 0 }
        var released = 0
        for name in names where name.hasSuffix(".request.json") {
            let id = String(name.dropLast(".request.json".count))
            guard Self.isValidID(id) else { continue }
            try? fm.removeItem(atPath: requestPath(id))
            if release(id: id) { released += 1 }
        }
        for name in names where name.hasSuffix(".response.json") || name.hasSuffix(".response.tmp") {
            let path = paths.permissionDir + "/" + name
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > seconds else { continue }
            try? fm.removeItem(atPath: path)
        }
        return released
    }
}
