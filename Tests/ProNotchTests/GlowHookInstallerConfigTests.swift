import XCTest
@testable import ProNotch

/// Agent hook 配置的改写安全性。
///
/// 这些文件是用户自己的资产（`~/.codex/config.toml`、`~/.kimi-code/config.toml`），
/// 我们只往里加一条 hook。改坏的代价不是"功能不可用"，是用户的 Agent 起不来。
/// 全部用例都在临时目录里跑，绝不碰真实家目录。
final class GlowHookInstallerConfigTests: XCTestCase {

    private var root: String!
    private var paths: GlowHookPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = NSTemporaryDirectory() + "pronotch-hook-tests-" + UUID().uuidString
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        paths = GlowHookPaths.rooted(at: root)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func write(_ text: String, to path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    // MARK: - Codex notify 定位

    func testCodex单行notify() {
        let toml = """
        model = "gpt-5"
        notify = ["/usr/local/bin/mynotify", "--flag"]

        [tui]
        theme = "dark"
        """
        let m = CodexNotifyParser.find(in: toml)
        XCTAssertEqual(m?.rawValue, "[\"/usr/local/bin/mynotify\", \"--flag\"]")
        XCTAssertEqual(CodexNotifyParser.parseStringArray(m!.rawValue),
                       ["/usr/local/bin/mynotify", "--flag"])
    }

    func testCodex多行notify_整体替换不留残行() {
        // 老实现按行正则命中第一行就替换，剩下三行成为游离文本，整个 TOML 语法报废
        let toml = """
        model = "gpt-5"
        notify = [
          "/usr/local/bin/mynotify",
          "--flag",
        ]

        [tui]
        theme = "dark"
        """
        let m = CodexNotifyParser.find(in: toml)
        XCTAssertNotNil(m)
        XCTAssertEqual(CodexNotifyParser.parseStringArray(m!.rawValue),
                       ["/usr/local/bin/mynotify", "--flag"])

        let replaced = CodexNotifyParser.upsert(toml, value: "[\"/new.sh\"]")
        XCTAssertFalse(replaced.contains("mynotify"), "旧数组必须整体消失")
        XCTAssertFalse(replaced.contains("--flag"), "多行数组的中间行不能残留")
        XCTAssertTrue(replaced.contains("notify = [\"/new.sh\"]"))
        XCTAssertTrue(replaced.contains("[tui]"), "后续段落必须原样保留")
        XCTAssertEqual(CodexNotifyParser.parseStringArray(
            CodexNotifyParser.find(in: replaced)!.rawValue), ["/new.sh"])
    }

    func testCodex多行notify_删除后文件仍可解析() {
        let toml = """
        model = "gpt-5"
        notify = [
          "/a.sh",
          "/b.sh"
        ]
        approval = "never"
        """
        let removed = CodexNotifyParser.remove(toml)
        XCTAssertNil(CodexNotifyParser.find(in: removed))
        XCTAssertFalse(removed.contains("/a.sh"))
        XCTAssertFalse(removed.contains("]"), "数组闭合行不能留下")
        XCTAssertTrue(removed.contains("approval = \"never\""))
    }

    func testCodex注释里的notify不误命中() {
        let toml = """
        # notify = ["/evil.sh"]
        model = "gpt-5"
        """
        XCTAssertNil(CodexNotifyParser.find(in: toml))
    }

    func testCodex字符串里的notify不误命中() {
        let toml = """
        instructions = "把 notify = [\\"x\\"] 写进配置"
        model = "gpt-5"
        """
        XCTAssertNil(CodexNotifyParser.find(in: toml))
    }

    func testCodex段内的notify不算顶层() {
        let toml = """
        model = "gpt-5"

        [mcp_servers.foo]
        notify = ["/not-top-level.sh"]
        """
        XCTAssertNil(CodexNotifyParser.find(in: toml), "段内的同名键不是顶层 notify")
    }

    func testCodex字符串内的方括号不提前收尾() {
        let toml = #"notify = ["/bin/sh", "-c", "echo ] done"]"#
        let m = CodexNotifyParser.find(in: toml)
        XCTAssertEqual(CodexNotifyParser.parseStringArray(m!.rawValue),
                       ["/bin/sh", "-c", "echo ] done"])
    }

    func testCodex转义与行尾注释() {
        let toml = #"""
        notify = ["/path/with \"quote\"", "/b"]  # 行尾注释
        model = "gpt-5"
        """#
        let m = CodexNotifyParser.find(in: toml)
        XCTAssertEqual(CodexNotifyParser.parseStringArray(m!.rawValue),
                       ["/path/with \"quote\"", "/b"])
        let removed = CodexNotifyParser.remove(toml)
        XCTAssertFalse(removed.contains("行尾注释"), "行尾注释属于这条 notify，一并清掉")
        XCTAssertTrue(removed.contains("model"))
    }

    // MARK: - Codex 安装 / 卸载

    private func prepareCodex(_ toml: String) throws {
        try write(toml, to: paths.codexConfig)
    }

    func testCodex全新接入_原notify作为previous透传() throws {
        try prepareCodex("""
        model = "gpt-5"
        notify = ["/usr/local/bin/mynotify"]
        """)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        XCTAssertTrue(GlowHookInstaller.isInstalled(.codex, paths: paths))

        let config = read(paths.codexConfig)
        XCTAssertTrue(config.contains("notify = [\"\(paths.codexScript)\"]"))
        let script = read(paths.codexScript)
        XCTAssertTrue(script.contains("exec '/usr/local/bin/mynotify' \"$payload\""),
                      "原 notify 必须继续被调用，否则下游工具被我们打断")
        XCTAssertTrue(script.contains("PRONOTCH_PREV_B64="))
    }

    func testCodex卸载_还原原notify并删脚本() throws {
        try prepareCodex("""
        model = "gpt-5"
        notify = ["/usr/local/bin/mynotify"]
        """)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, false, paths: paths))

        let config = read(paths.codexConfig)
        XCTAssertTrue(config.contains("notify = [\"/usr/local/bin/mynotify\"]"))
        XCTAssertFalse(fm.fileExists(atPath: paths.codexScript))
    }

    func testCodex原本无notify_卸载后整条消失() throws {
        try prepareCodex("model = \"gpt-5\"\n")
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        XCTAssertTrue(read(paths.codexConfig).contains("notify ="))
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, false, paths: paths))
        XCTAssertFalse(read(paths.codexConfig).contains("notify ="))
        XCTAssertTrue(read(paths.codexConfig).contains("model = \"gpt-5\""))
    }

    func testCodex重复接入幂等_不套娃() throws {
        try prepareCodex("notify = [\"/usr/local/bin/mynotify\"]\n")
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        let first = read(paths.codexConfig)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        XCTAssertEqual(read(paths.codexConfig), first, "已接入应完全不动文件")
        XCTAssertTrue(read(paths.codexScript).contains("exec '/usr/local/bin/mynotify'"))
    }

    func testCodex被外层套壳_我们是下游不再转发() throws {
        // computer-use 之类把我们套在里层：notify 指向上游，上游再调我们
        try prepareCodex("notify = [\"/opt/wrapper\", \"\(paths.codexScript)\"]\n")
        try write("#!/bin/bash\n# PRONOTCH_FMT=0\n", to: paths.codexScript)

        XCTAssertTrue(GlowHookInstaller.isInstalled(.codex, paths: paths),
                      "被套壳也算已接入——误判成未接入会重新写入，酿成自引用死循环")
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))

        XCTAssertTrue(read(paths.codexConfig).contains("/opt/wrapper"), "上游的 notify 不该被我们改")
        let script = read(paths.codexScript)
        // 注意别用 contains("exec") 判断——脚本里的 /usr/libexec/PlistBuddy 会假阳性
        XCTAssertFalse(script.contains("\nexec "), "我们已是下游，再转发就绕回上游了")
        XCTAssertTrue(script.contains("原本无 notify，到此结束"))
    }

    func testCodex自引用previous被拒绝() throws {
        // 最恶劣的一种：previous 里含我们自己，exec 回自己 → 无限循环（光晕狂闪）
        try prepareCodex("notify = [\"\(paths.codexScript)\", \"--x\"]\n")
        try write("#!/bin/bash\n# PRONOTCH_FMT=0\n# PRONOTCH_PREV_B64=\n", to: paths.codexScript)

        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        let script = read(paths.codexScript)
        XCTAssertFalse(script.contains("exec '\(paths.codexScript)'"),
                       "绝不能 exec 回自己")
        XCTAssertTrue(script.contains("原本无 notify，到此结束"))
    }

    func testCodex被外层套壳时卸载_不动上游notify() throws {
        try prepareCodex("notify = [\"/opt/wrapper\", \"\(paths.codexScript)\"]\n")
        try write("#!/bin/bash\n# PRONOTCH_FMT=4\n", to: paths.codexScript)

        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, false, paths: paths))
        XCTAssertTrue(read(paths.codexConfig).contains("/opt/wrapper"))
        XCTAssertFalse(fm.fileExists(atPath: paths.codexScript))
    }

    // MARK: - Kimi 边界块

    func testKimi安装_写入带边界标记的块() throws {
        try write("model = \"kimi\"\n", to: paths.kimiConfig)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, true, paths: paths))

        let toml = read(paths.kimiConfig)
        XCTAssertTrue(toml.contains(KimiHookBlock.beginMarker))
        XCTAssertTrue(toml.contains(KimiHookBlock.endMarker))
        XCTAssertTrue(toml.contains(GlowHookInstaller.kimiHookCommandLine(for: paths.kimiScript)))
        XCTAssertTrue(toml.contains("model = \"kimi\""), "原内容必须原样保留")
        XCTAssertTrue(fm.fileExists(atPath: paths.kimiScript))
    }

    func testKimi卸载_按边界标记整段摘除且不留空行堆() throws {
        try write("model = \"kimi\"\n", to: paths.kimiConfig)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, true, paths: paths))
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, false, paths: paths))

        let toml = read(paths.kimiConfig)
        XCTAssertFalse(toml.contains("ProNotch"))
        XCTAssertFalse(toml.contains("[[hooks]]"))
        XCTAssertEqual(toml.trimmingCharacters(in: .whitespacesAndNewlines), "model = \"kimi\"")
        XCTAssertFalse(fm.fileExists(atPath: paths.kimiScript))
    }

    func testKimi升级_旧格式裸路径被换成带标记的新块() throws {
        // 早期版本写的是裸路径（会被 shell 从空格切断），且没有边界标记
        try write("""
        model = "kimi"

        # ProNotch 完成提醒（自动生成，卸载请在 ProNotch 设置里取消勾选）
        [[hooks]]
        event = "Stop"
        command = "\(paths.kimiScript)"
        timeout = 15
        """, to: paths.kimiConfig)
        try write("#!/bin/bash\n# PRONOTCH_FMT=0\n", to: paths.kimiScript)

        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, true, paths: paths))
        let toml = read(paths.kimiConfig)
        XCTAssertTrue(toml.contains(KimiHookBlock.beginMarker))
        XCTAssertTrue(toml.contains(GlowHookInstaller.kimiHookCommandLine(for: paths.kimiScript)))
        XCTAssertEqual(toml.components(separatedBy: "[[hooks]]").count - 1, 1,
                       "升级不能变成两段 hooks")
    }

    func testKimi保留用户自己的hooks段() throws {
        try write("""
        [[hooks]]
        event = "Stop"
        command = "/user/own.sh"
        """, to: paths.kimiConfig)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, true, paths: paths))
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, false, paths: paths))

        let toml = read(paths.kimiConfig)
        XCTAssertTrue(toml.contains("/user/own.sh"), "用户自己的 hook 一根汗毛都不能少")
        XCTAssertFalse(toml.contains("kimi-notify.sh"))
    }

    func testKimi边界标记残缺时拒绝删除() {
        // 用户手改把 END 删了：范围无法确定，宁可失败也不能猜
        let toml = """
        model = "kimi"
        \(KimiHookBlock.beginMarker)
        [[hooks]]
        command = '"/x/kimi-notify.sh"'
        """
        XCTAssertEqual(KimiHookBlock.remove(from: toml, scriptPath: "/x/kimi-notify.sh"), .ambiguous)
    }

    func testKimi旧格式多处引用时拒绝删除() {
        let toml = """
        [[hooks]]
        command = '"/x/kimi-notify.sh"'
        [[hooks]]
        command = '"/x/kimi-notify.sh"'
        """
        XCTAssertEqual(KimiHookBlock.remove(from: toml, scriptPath: "/x/kimi-notify.sh"), .ambiguous)
    }

    func testKimi无引用时报notPresent() {
        XCTAssertEqual(KimiHookBlock.remove(from: "model = \"kimi\"", scriptPath: "/x/kimi-notify.sh"),
                       .notPresent)
    }

    func testKimi定位不到时不动文件() throws {
        let original = """
        model = "kimi"
        \(KimiHookBlock.beginMarker)
        [[hooks]]
        command = '"\(paths.kimiScript)"'
        """
        try write(original, to: paths.kimiConfig)
        try write("#!/bin/bash\n", to: paths.kimiScript)

        XCTAssertFalse(GlowHookInstaller.setInstalled(.kimi, false, paths: paths),
                       "边界残缺应报失败")
        XCTAssertEqual(read(paths.kimiConfig), original, "失败时原文件必须字节不变")
        XCTAssertTrue(fm.fileExists(atPath: paths.kimiScript), "配置没改成，脚本也不该删")
    }

    // MARK: - Claude / Grok

    /// 读出 Claude settings.json 里 Stop 钩子的全部 command
    private func claudeStopCommands() -> [String] {
        guard let data = fm.contents(atPath: paths.claudeSettings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return [] }
        return stop.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testClaude安装与卸载_保留用户自己的钩子() throws {
        try write("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/user/own.sh"}]}]}}
        """, to: paths.claudeSettings)

        XCTAssertTrue(GlowHookInstaller.setInstalled(.claude, true, paths: paths))
        XCTAssertTrue(GlowHookInstaller.isInstalled(.claude, paths: paths))
        XCTAssertTrue(fm.fileExists(atPath: paths.claudeScript))
        XCTAssertEqual(claudeStopCommands(), ["/user/own.sh", "\"\(paths.claudeScript)\""],
                       "我们的条目追加在后，用户的排在前")

        XCTAssertTrue(GlowHookInstaller.setInstalled(.claude, false, paths: paths))
        // 按结构断言而非文本包含：JSONSerialization 会把 / 转义成 \/
        XCTAssertEqual(claudeStopCommands(), ["/user/own.sh"], "用户自己的钩子必须原样留下")
        XCTAssertFalse(fm.fileExists(atPath: paths.claudeScript))
    }

    func testGrok安装与卸载() throws {
        try fm.createDirectory(atPath: paths.grokHome, withIntermediateDirectories: true)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.grok, true, paths: paths))
        XCTAssertTrue(GlowHookInstaller.isInstalled(.grok, paths: paths))
        XCTAssertTrue(GlowHookInstaller.setInstalled(.grok, false, paths: paths))
        XCTAssertFalse(fm.fileExists(atPath: paths.grokHookFile))
        XCTAssertFalse(fm.fileExists(atPath: paths.grokScript))
    }

    // MARK: - 原子写入与权限

    func testValidate失败时原文件字节不变且不留临时文件() throws {
        let path = root + "/sample.toml"
        try write("original = 1\n", to: path)
        let result = AtomicConfigWriter.write("broken", to: path) { _ in false }
        guard case .failure(.validationFailed) = result else {
            return XCTFail("校验失败应整笔放弃，实际 \(result)")
        }
        XCTAssertEqual(read(path), "original = 1\n")

        let leftovers = (try? fm.contentsOfDirectory(atPath: root))?
            .filter { $0.hasPrefix(".pronotch-tmp-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "临时文件必须清干净：\(leftovers)")
    }

    func test备份保留两代() throws {
        let path = root + "/sample.toml"
        try write("v1\n", to: path)
        AtomicConfigWriter.backup(path)
        try write("v2\n", to: path)
        AtomicConfigWriter.backup(path)

        XCTAssertEqual(read(path + ".pronotch.bak"), "v2\n")
        XCTAssertEqual(read(path + ".pronotch.bak.1"), "v1\n")
    }

    func test备份权限不给其他人读写() throws {
        let path = root + "/sample.toml"
        try write("secret = \"token\"\n", to: path)
        AtomicConfigWriter.backup(path)
        let mode = (try fm.attributesOfItem(atPath: path + ".pronotch.bak"))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func test脚本可执行且不允许他人写() throws {
        try write("model = \"kimi\"\n", to: paths.kimiConfig)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, true, paths: paths))
        let mode = (try fm.attributesOfItem(atPath: paths.kimiScript))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func test原子写入沿用原文件权限() throws {
        let path = root + "/sample.toml"
        try write("a = 1\n", to: path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertTrue(AtomicConfigWriter.write("b = 2\n", to: path) { _ in true }.isSuccess)
        let mode = (try fm.attributesOfItem(atPath: path))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "写完不能把用户收紧过的权限放开")
    }
}
