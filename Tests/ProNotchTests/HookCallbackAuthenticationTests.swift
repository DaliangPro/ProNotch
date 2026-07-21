import XCTest
@testable import ProNotch

/// `pronotch://done` 回调的认证。
///
/// 病灶：这条 URL 谁都能调。本机上任何进程、任何网页里的一条
/// `<a href="pronotch://done?source=claude&host=com.evil.app&session=…">`
/// 都会被当成「Agent 干完活了」——点亮光晕是小事，它还会往会话表里写宿主映射，
/// 而宿主映射决定用户点 Agent 卡片时跳去哪个 App。
///
/// 全部用例在临时目录里跑，绝不碰真实家目录。
final class HookCallbackAuthenticationTests: XCTestCase {

    private var root: String!
    private var paths: GlowHookPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = NSTemporaryDirectory() + "pronotch-hook-token-" + UUID().uuidString
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        paths = GlowHookPaths.rooted(at: root)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// 造出四家 Agent 的「已安装」现场，安装器才肯接入
    private func prepareAgentHomes() throws {
        try fm.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.codex", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.kimi-code", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.grok", withIntermediateDirectories: true)
        try "".write(toFile: paths.kimiConfig, atomically: true, encoding: .utf8)
        try "model = \"gpt-5\"\n".write(toFile: paths.codexConfig, atomically: true, encoding: .utf8)
    }

    // MARK: - 放行与拒绝

    func test正确令牌放行() {
        let token = GlowHookToken.generate()
        XCTAssertEqual(GlowCallbackAuth.decide(token: token, expected: token), .accept)
    }

    func test缺令牌拒绝() {
        let token = GlowHookToken.generate()
        guard case .reject = GlowCallbackAuth.decide(token: nil, expected: token) else {
            return XCTFail("不带令牌的回调必须丢弃")
        }
    }

    func test空令牌拒绝() {
        let token = GlowHookToken.generate()
        guard case .reject = GlowCallbackAuth.decide(token: "", expected: token) else {
            return XCTFail("token= 空值也是没有令牌")
        }
    }

    func test错误令牌拒绝() {
        let token = GlowHookToken.generate()
        guard case .reject = GlowCallbackAuth.decide(token: GlowHookToken.generate(),
                                                     expected: token) else {
            return XCTFail("令牌对不上就得丢弃")
        }
    }

    func test令牌只差一位也拒绝() {
        let token = GlowHookToken.generate()
        var tampered = Array(token)
        tampered[tampered.count - 1] = tampered.last == "0" ? "1" : "0"
        guard case .reject = GlowCallbackAuth.decide(token: String(tampered), expected: token) else {
            return XCTFail("差一位就是错的")
        }
    }

    func test令牌是正确值的前缀也拒绝() {
        let token = GlowHookToken.generate()
        guard case .reject = GlowCallbackAuth.decide(token: String(token.dropLast()),
                                                     expected: token) else {
            return XCTFail("截断的令牌不能算数")
        }
    }

    func test本机尚未生成令牌时一律拒绝() {
        // 没装过 hook 却收到回调 —— 只可能是别人发的
        guard case .reject = GlowCallbackAuth.decide(token: "whatever", expected: nil) else {
            return XCTFail("没有可比对的令牌时不能放行")
        }
        guard case .reject = GlowCallbackAuth.decide(token: nil, expected: "") else {
            return XCTFail("空的期望值等同于没有令牌")
        }
    }

    func test调试旁路只在显式开启时放行() {
        // 正式版这条分支恒为 false（编译期就没有），这里只验判定函数本身的语义
        XCTAssertEqual(GlowCallbackAuth.decide(token: nil, expected: nil, allowUnsigned: true),
                       .accept)
        XCTAssertEqual(GlowCallbackAuth.decide(token: nil, expected: "abc", allowUnsigned: true),
                       .accept)
    }

    // MARK: - 恒定时间比较

    func test恒定时间比较的正确性() {
        XCTAssertTrue(GlowCallbackAuth.constantTimeEquals("abc", "abc"))
        XCTAssertTrue(GlowCallbackAuth.constantTimeEquals("", ""))
        XCTAssertFalse(GlowCallbackAuth.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(GlowCallbackAuth.constantTimeEquals("abc", "abcd"), "长度不同必为假")
        XCTAssertFalse(GlowCallbackAuth.constantTimeEquals("abcd", "abc"))
        XCTAssertFalse(GlowCallbackAuth.constantTimeEquals("abc", ""))
    }

    func test首字节不同与末字节不同都判假() {
        // 普通 == 遇到第一个不同字节就返回，按耗时可以逐位试出令牌；
        // 这两例的结果必须一致地为假
        let token = String(repeating: "a", count: 64)
        XCTAssertFalse(GlowCallbackAuth.constantTimeEquals("b" + token.dropFirst(), token))
        XCTAssertFalse(GlowCallbackAuth.constantTimeEquals(token.dropLast() + "b", token))
    }

    // MARK: - 令牌本身

    func test生成的令牌够长且每次都不同() {
        let a = GlowHookToken.generate()
        let b = GlowHookToken.generate()
        XCTAssertEqual(a.count, 64, "32 字节的十六进制串")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit }, "必须 URL 安全，不能带需转义的字符")
    }

    func test令牌文件权限为0600() throws {
        let token = try XCTUnwrap(GlowHookToken.ensure(paths))
        XCTAssertFalse(token.isEmpty)

        let attrs = try fm.attributesOfItem(atPath: GlowHookToken.path(paths))
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perm, 0o600, "别的用户能读到就等于没有令牌")
    }

    func test重复ensure返回同一枚令牌() throws {
        let first = try XCTUnwrap(GlowHookToken.ensure(paths))
        let second = try XCTUnwrap(GlowHookToken.ensure(paths))
        XCTAssertEqual(first, second, "每次安装都换一枚的话，已装好的其它家全部失效")
        XCTAssertEqual(GlowHookToken.current(paths), first)
    }

    func test没有令牌文件时current返回nil() {
        XCTAssertNil(GlowHookToken.current(paths))
    }

    func test令牌文件为空视同没有令牌() throws {
        try fm.createDirectory(atPath: paths.scriptDir, withIntermediateDirectories: true)
        try "   \n".write(toFile: GlowHookToken.path(paths), atomically: true, encoding: .utf8)
        XCTAssertNil(GlowHookToken.current(paths), "空白内容不能被当成一枚合法令牌")
    }

    // MARK: - 四家脚本都带令牌

    func test四家脚本的URL都带上当前令牌() throws {
        try prepareAgentHomes()
        for kind in AgentKind.allCases where kind.supportsGlow {
            XCTAssertTrue(GlowHookInstaller.setInstalled(kind, true, paths: paths),
                          "\(kind.rawValue) 应当安装成功")
        }
        let token = try XCTUnwrap(GlowHookToken.current(paths))

        for script in [paths.claudeScript, paths.kimiScript, paths.grokScript, paths.codexScript] {
            let text = read(script)
            XCTAssertTrue(text.contains("token=\(token)"),
                          "\((script as NSString).lastPathComponent) 没带令牌")
            XCTAssertTrue(text.contains("pronotch://done?source="),
                          "\((script as NSString).lastPathComponent) 的回调 URL 变了形")
        }
    }

    func test脚本里的令牌与文件里的一致() throws {
        try prepareAgentHomes()
        XCTAssertTrue(GlowHookInstaller.setInstalled(.claude, true, paths: paths))

        // 从脚本里把令牌抠出来，必须与磁盘上那枚逐字节相同
        let text = read(paths.claudeScript)
        let marker = "token="
        let start = try XCTUnwrap(text.range(of: marker)).upperBound
        let inScript = String(text[start...].prefix(64))
        XCTAssertEqual(inScript, GlowHookToken.current(paths))
    }

    // MARK: - 老脚本升级

    func test老格式脚本迁移后带上令牌() throws {
        try prepareAgentHomes()
        // 先造一份 v4 现场：脚本无 token，配置已接入
        XCTAssertTrue(GlowHookInstaller.setInstalled(.claude, true, paths: paths))
        // 用正则改格式号而不是写死「5」：脚本格式每升一版这条测试就会失效一次
        let legacy = read(paths.claudeScript)
            .replacingOccurrences(of: #"PRONOTCH_FMT=\d+"#, with: "PRONOTCH_FMT=4",
                                  options: .regularExpression)
            .replacingOccurrences(of: "&token=\(GlowHookToken.current(paths)!)", with: "")
        try legacy.write(toFile: paths.claudeScript, atomically: true, encoding: .utf8)
        XCTAssertFalse(read(paths.claudeScript).contains("token="), "前置条件：老脚本确实没令牌")

        GlowHookInstaller.migrateIfInstalled(.claude, paths: paths)

        let token = try XCTUnwrap(GlowHookToken.current(paths))
        let upgraded = read(paths.claudeScript)
        XCTAssertFalse(upgraded.contains("PRONOTCH_FMT=4"), "老格式号必须被刷掉")
        XCTAssertTrue(upgraded.contains("token=\(token)"), "迁移后必须带上令牌，否则老用户的光晕再也不亮")
    }

    func test未接入的家不会被迁移顺手装上() throws {
        try prepareAgentHomes()
        GlowHookInstaller.migrateIfInstalled(.grok, paths: paths)
        XCTAssertFalse(fm.fileExists(atPath: paths.grokScript), "迁移只刷新已接入的，不改变接入与否")
    }

    func test令牌轮换后旧脚本会被重写() throws {
        try prepareAgentHomes()
        XCTAssertTrue(GlowHookInstaller.setInstalled(.claude, true, paths: paths))
        let old = try XCTUnwrap(GlowHookToken.current(paths))

        // 模拟令牌被轮换（用户手删了令牌文件、或换机后重新生成）
        try fm.removeItem(atPath: GlowHookToken.path(paths))
        let new = try XCTUnwrap(GlowHookToken.ensure(paths))
        XCTAssertNotEqual(old, new)

        GlowHookInstaller.migrateIfInstalled(.claude, paths: paths)

        let text = read(paths.claudeScript)
        XCTAssertTrue(text.contains("token=\(new)"), "脚本得换成新令牌")
        XCTAssertFalse(text.contains("token=\(old)"), "旧令牌不能留在脚本里")
    }

    func test重复安装不重写脚本也不换令牌() throws {
        try prepareAgentHomes()
        XCTAssertTrue(GlowHookInstaller.setInstalled(.claude, true, paths: paths))
        let token = try XCTUnwrap(GlowHookToken.current(paths))
        let first = read(paths.claudeScript)

        XCTAssertTrue(GlowHookInstaller.setInstalled(.claude, true, paths: paths))
        XCTAssertEqual(read(paths.claudeScript), first, "幂等：内容一个字节都不该变")
        XCTAssertEqual(GlowHookToken.current(paths), token)
    }

    // MARK: - 令牌不进日志

    func test拒绝理由里不出现令牌值() {
        let token = GlowHookToken.generate()
        let wrong = GlowHookToken.generate()
        let cases: [GlowCallbackAuth.Decision] = [
            GlowCallbackAuth.decide(token: nil, expected: token),
            GlowCallbackAuth.decide(token: wrong, expected: token),
            GlowCallbackAuth.decide(token: wrong, expected: nil),
        ]
        for case .reject(let reason) in cases {
            XCTAssertFalse(reason.contains(token), "日志里出现一次，令牌就等于公开了")
            XCTAssertFalse(reason.contains(wrong), "错误的那枚也不该回显——它可能是别处的真令牌")
            XCTAssertFalse(reason.isEmpty)
        }
    }
}
