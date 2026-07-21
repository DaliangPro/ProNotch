import XCTest
@testable import ProNotch

/// 构建脚本不许在旧副本还跑着的时候动手。
///
/// 病灶：`build/ProNotch.app` 与 `/Applications` 版 bundle id 相同
///（com.daliangpro.ProNotch），两个实例于是共享 UserDefaults、App Support 存档
/// 和钥匙串，互相覆盖设置与剪贴板历史；AtomicFileStore 的串行写只在单进程内有效，
/// 跨进程管不着。而脚本还会 `rm -rf` 掉这个 bundle——删正在运行的 App 更没准。
/// 2026-07-21 实测：一个副本在后台跑了 10 小时没人发现。
final class BuildScriptGuardTests: XCTestCase {

    private var scriptsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts")
    }

    private func text(of name: String) throws -> String {
        try String(contentsOf: scriptsDir.appendingPathComponent(name), encoding: .utf8)
    }

    func test构建脚本会检测残留副本() throws {
        let script = try text(of: "build-app.sh")
        XCTAssertTrue(script.contains("lsof -t"),
                      "缺少残留副本检测，两个实例会共享存档互相覆盖数据")
        XCTAssertTrue(script.contains("exit 1"),
                      "检测到了却不中止，等于没检测")
    }

    /// 按命令行字符串找进程会漏：`open` 给的是绝对路径，手敲 `./build/…` 给的是相对路径，
    /// 同一个进程两种写法。2026-07-21 第一版守卫就是这么漏掉的
    func test副本检测按文件认而不是按命令行认() throws {
        let script = try text(of: "build-app.sh")
        let detectLine = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("STALE=") })
        XCTAssertFalse(detectLine.contains("pgrep -f"),
                       "pgrep -f 比的是命令行文本，启动方式一换就漏：\(detectLine)")
        XCTAssertTrue(detectLine.contains("ProNotch.app/Contents/MacOS/ProNotch"),
                      "得直接问那个可执行文件被谁持有")
    }

    func test检测在删除bundle之前() throws {
        let script = try text(of: "build-app.sh")
        let stale = try XCTUnwrap(script.range(of: "STALE=")).lowerBound
        let remove = try XCTUnwrap(script.range(of: #"rm -rf "$APP_DIR""#)).lowerBound
        XCTAssertLessThan(stale, remove,
                          "检测必须早于 rm -rf，否则正在运行的 bundle 已经被删了")
    }

    /// package-dmg.sh 自己不构建，靠调 build-app.sh——守卫写一处即可，
    /// 但这条关系断了就会绕过检测
    func test打包脚本仍然经由构建脚本() throws {
        let script = try text(of: "package-dmg.sh")
        XCTAssertTrue(script.contains("./Scripts/build-app.sh"),
                      "打包若改成自己构建，得把残留副本检测一并搬过去")
    }

    func test两个脚本语法都合法() throws {
        for name in ["build-app.sh", "package-dmg.sh"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", scriptsDir.appendingPathComponent(name).path]
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(name) 语法不合法")
        }
    }
}
