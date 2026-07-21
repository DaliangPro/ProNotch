import XCTest
@testable import ProNotch

/// 签名私钥的授权范围。
///
/// 病灶：创建证书的脚本原先用 `security import … -A`。`-A` 的含义是
/// **本机任意程序都能拿这把私钥签名**——任何跑在该账号下的进程（随手装的一个脚本、
/// 一个 npm 包）都能签出一个「ProNotch Local Signing」的 App。
/// 而这个签名身份正是 macOS 记忆隐私授权的依据：伪造它就能继承 ProNotch 已拿到的
/// 录屏、辅助功能授权。
///
/// 这里守的是脚本文本本身——它是发版链路的一部分，跑不进单元测试，
/// 但「有没有 -A」是能静态断言的。
final class SigningScriptTests: XCTestCase {

    private var scriptsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts")
    }

    private func text(of name: String) throws -> String {
        try String(contentsOf: scriptsDir.appendingPathComponent(name), encoding: .utf8)
    }

    func test创建证书脚本不再把私钥开给所有程序() throws {
        let script = try text(of: "create-signing-cert.sh")
        for line in script.split(separator: "\n") where line.contains("security import") {
            XCTAssertFalse(line.contains(" -A"),
                           "security import 带 -A 等于把签名身份交给本机任意程序：\(line)")
        }
    }

    func test私钥只授权给codesign() throws {
        let script = try text(of: "create-signing-cert.sh")
        let importLine = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("security import") })
        XCTAssertTrue(importLine.contains("-T /usr/bin/codesign"),
                      "得留一个明确的授权对象，否则每次签名都要手点密码框")
        // -T 只出现一次：多授权一个工具就多一条伪造路径
        XCTAssertEqual(importLine.components(separatedBy: "-T ").count - 1, 1)
    }

    func test改用分区列表免弹框而不是放开授权() throws {
        let script = try text(of: "create-signing-cert.sh")
        XCTAssertTrue(script.contains("set-key-partition-list"),
                      "去掉 -A 之后要有替代方案，否则等于把弹框问题甩给用户")
        let partitionLine = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("set-key-partition-list") })
        XCTAssertTrue(partitionLine.contains("-S "), "分区列表必须显式限定范围")
        for allowed in ["apple-tool:", "apple:", "codesign:"] {
            XCTAssertTrue(partitionLine.contains(allowed), "缺少 \(allowed)")
        }
    }

    func test钥匙串密码不写进脚本() throws {
        // 只看 set-key-partition-list 那条语句：它的 -k 才是登录密码，
        // security import 的 -k 是钥匙串路径，两者同名不同义
        let statement = try logicalStatement(containing: "set-key-partition-list",
                                             in: "create-signing-cert.sh")
        XCTAssertFalse(statement.contains(" -k "),
                       "-k <密码> 会把登录密码留在脚本与 shell 历史里，该交给系统对话框：\(statement)")
    }

    /// 取出含关键字的整条语句（把行尾反斜杠续行接上）
    private func logicalStatement(containing keyword: String, in file: String) throws -> String {
        let lines = try text(of: file).split(separator: "\n", omittingEmptySubsequences: false)
        let start = try XCTUnwrap(lines.firstIndex { $0.contains(keyword) })
        var statement = "", i = start
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            statement += (statement.isEmpty ? "" : " ") + line.replacingOccurrences(of: "\\", with: "")
            if !line.hasSuffix("\\") { break }
            i += 1
        }
        return statement
    }

    func test脚本仍是幂等的() throws {
        let script = try text(of: "create-signing-cert.sh")
        XCTAssertTrue(script.contains("find-identity"), "重复执行必须先检测已有证书")
        XCTAssertTrue(script.contains("exit 0"), "已存在时要早退，不能重复导入")
    }

    func test其余脚本没有引入宽泛授权() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: scriptsDir.path)
            .filter { $0.hasSuffix(".sh") }
        XCTAssertGreaterThan(names.count, 2, "没扫到脚本的话这条测试等于空转")

        for name in names {
            for line in try text(of: name).split(separator: "\n")
            where line.contains("security import") || line.contains("security add-generic-password") {
                XCTAssertFalse(line.contains(" -A"), "\(name) 出现宽泛授权：\(line)")
            }
        }
    }
}
