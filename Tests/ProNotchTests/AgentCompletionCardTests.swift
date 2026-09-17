import XCTest
import SwiftUI
@testable import ProNotch

/// 完成提醒选「顶部弹窗」时的任务完成卡（大梁老师 2026-09-16 定）：
/// 一直挂着，点它或切回对应 App 才收；新完成的顶掉旧的
@MainActor
final class AgentCompletionCardTests: XCTestCase {

    private func notice(_ session: String, source: AgentKind = .claude,
                        host: String? = "com.mitchellh.ghostty") -> AgentCompletionNotice {
        AgentCompletionNotice(source: source, session: session, host: host, project: "ProNotch", tintHex: nil)
    }

    func test完成卡一直挂着() async throws {
        let store = AgentCompletionStore()
        store.present(notice("s1"))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(store.notice, "没人点、没切回那个 App，就一直挂着")
    }

    func test新的完成卡顶掉旧的() {
        let store = AgentCompletionStore()
        store.present(notice("s1"))
        store.present(notice("s2"))
        XCTAssertEqual(store.notice?.session, "s2")
    }

    func test切回宿主App收卡_切到别的App不收() {
        let store = AgentCompletionStore()
        store.present(notice("s1"))
        store.dismiss(activated: "com.apple.Safari")
        XCTAssertNotNil(store.notice, "切到无关 App 不算看过")
        store.dismiss(activated: "com.mitchellh.ghostty")
        XCTAssertNil(store.notice)
    }

    func test宿主抓空时认桌面版() {
        let store = AgentCompletionStore()
        store.present(notice("s1", source: .claude, host: nil))
        store.dismiss(activated: "com.mitchellh.ghostty")
        XCTAssertNotNil(store.notice)
        store.dismiss(activated: "com.anthropic.claudefordesktop")
        XCTAssertNil(store.notice)
    }

    func test宿主和桌面版都没有时切到任意App即收() {
        let store = AgentCompletionStore()
        store.present(notice("s1", source: .kimi, host: nil))
        store.dismiss(activated: "com.apple.Safari")
        XCTAssertNil(store.notice, "无从知道该等谁，不能留一张永远收不掉的卡")
    }

    func test按条件收卡只收命中的() {
        let store = AgentCompletionStore()
        store.present(notice("s1"))
        store.withdraw { $0.session == AgentCompletionNotice.previewSession }
        XCTAssertNotNil(store.notice, "真实的完成卡不该被「收预览卡」带走")
        store.present(notice(AgentCompletionNotice.previewSession))
        store.withdraw { $0.session == AgentCompletionNotice.previewSession }
        XCTAssertNil(store.notice)
    }

    // MARK: - 项目名解码

    /// 项目名里有空格、中文、括号都很常见，直接拼进 URL 会被 open / URLComponents 打断，
    /// 所以脚本先 base64url 编码。解不回来就是卡面上一串乱码
    func test项目名base64url往返() {
        for name in ["ProNotch", "我的 项目", "app (v2)", "a+b/c", "日本語のプロジェクト"] {
            let encoded = Data(name.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(AgentCompletionNotice.decodeProject(encoded), name)
        }
    }

    func test项目名为空或解不出时退成空串() {
        XCTAssertEqual(AgentCompletionNotice.decodeProject(""), "")
        XCTAssertEqual(AgentCompletionNotice.decodeProject("!!!not-base64!!!"), "")
    }

    /// 脚本里 `base64 | tr -d '\n'` 偶有残留换行的余地，解出来不能带着空白进卡面
    func test解码后去掉首尾空白() {
        let encoded = Data(" ProNotch \n".utf8).base64EncodedString()
        XCTAssertEqual(AgentCompletionNotice.decodeProject(encoded), "ProNotch")
    }

    // MARK: - 卡真点得到吗

    /// 这类病离屏渲染和普通单测都照不出来：卡渲染得一模一样、store 的方法也全对，
    /// 可实机上点不动（实际发生过——刘海黑形状的 `clipShape` 只裁画面不裁点击，
    /// 把垫在底下的整张卡的点击全吃了，见 NotchContainerView 的 contentShape 注释）。
    /// 所以往真实视图树里合成鼠标点击，看卡有没有被点掉。
    ///
    /// 容器层（黑形状盖住卡）的那道防线在 App 里另有探针：
    /// `-snapshotPanel -notchCardScene 任务完成 -notchCardHitProbe`
    func test卡真点得到() throws {
        // 合成事件要走 AppKit 的分发；测试进程默认没建 NSApplication，
        // 不先建起来 SwiftUI 的手势系统压根收不到事件（会误报成「点不到」）
        NSApplication.shared.setActivationPolicy(.accessory)
        let vm = NotchViewModel(notchRect: CGRect(x: 380, y: 0, width: 200, height: 38))
        let store = AgentCompletionStore()
        // 预览会话：点到了只收卡，不会真的跳去别的 App
        store.present(notice(AgentCompletionNotice.previewSession))
        let size = vm.expandedShapeSize
        let root = AnyView(
            ZStack(alignment: .top) { AgentCompletionCardView() }
                .environmentObject(vm)
                .environmentObject(store)
                .environmentObject(AgentSessionsStore())
                // 必须 .top：卡是从屏幕顶边的刘海长出来的，默认居中会让整卡下移一半
                .frame(width: size.width, height: size.height, alignment: .top))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        defer { win.close() }
        // 事件路由要求窗口在场；挪到屏幕外再现身，跑测试时不会有窗口闪出来
        win.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        win.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))   // 等揭示动画走到终态

        // 卡在窗口顶部（AppKit 坐标 y 向上），逐点扫：写死一个坐标，日后卡挪 10pt 就成假绿灯
        let cardWidth = AgentCompletionCardView.cardWidth
        let cardBottom = size.height - 38 - 132
        var pressed = false
        outer: for y in stride(from: cardBottom + 10, through: size.height - 45, by: 12) {
            for x in stride(from: (size.width - cardWidth) / 2 + 20,
                            through: (size.width + cardWidth) / 2 - 20, by: 40) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: win.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    win.sendEvent(event)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if store.notice == nil { pressed = true; break outer }
            }
        }
        XCTAssertTrue(pressed, "卡区域的点击全被吞掉了——实机上就是「弹出来了但点不动」")
    }
}

/// 完成信号带上项目名（钩子格式 v14）。把生成的脚本真跑起来，看投递出去的 URL
final class CompletionHookProjectTests: XCTestCase {

    private var root: String!
    private var paths: GlowHookPaths!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "pronotch-done-project-" + UUID().uuidString
        paths = GlowHookPaths.rooted(at: root)
        for dir in [paths.scriptDir, paths.codexDir, (paths.kimiConfig as NSString).deletingLastPathComponent] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// 投递那一步换成把 URL 写进文件
    private func runDelivering(_ script: String, args: [String], stdin: String?) throws -> URLComponents? {
        let marker = root + "/url.txt"
        let patched = script.replacingOccurrences(
            of: #"if /usr/bin/pgrep -x ProNotch >/dev/null 2>&1; then open -g "$url"; fi"#,
            with: "printf '%s' \"$url\" > '\(marker)'")
        let file = root + "/hook.sh"
        try patched.write(toFile: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [file] + args
        p.environment = ["HOME": root, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard let url = try? String(contentsOfFile: marker, encoding: .utf8) else { return nil }
        return URLComponents(string: url)
    }

    private func project(_ c: URLComponents?) -> String {
        AgentCompletionNotice.decodeProject(c?.queryItems?.first { $0.name == "project" }?.value ?? "")
    }

    /// 目录名带空格和中文是常态，编码走 base64url，解回来必须一字不差
    func testCodex完成信号带项目名() throws {
        XCTAssertTrue(GlowHookInstaller.setInstalled(.codex, true, paths: paths))
        let script = try String(contentsOfFile: paths.codexScript, encoding: .utf8)
        let payload = #"{"type":"agent-turn-complete","turn-id":"x","cwd":"/Users/x/Coding/我的 项目"}"#
        let c = try runDelivering(script, args: [payload], stdin: nil)
        XCTAssertEqual(c?.host, "done")
        XCTAssertEqual(project(c), "我的 项目")
    }

    func testKimi完成信号带项目名() throws {
        try "".write(toFile: paths.kimiConfig, atomically: true, encoding: .utf8)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, true, paths: paths))
        let script = try String(contentsOfFile: paths.kimiScript, encoding: .utf8)
        let c = try runDelivering(script, args: [],
                                  stdin: #"{"session_id":"s1","cwd":"/Users/x/Coding/ProNotch"}"#)
        XCTAssertEqual(c?.queryItems?.first { $0.name == "session" }?.value, "s1")
        XCTAssertEqual(project(c), "ProNotch")
    }

    func test载荷没有cwd时照常投递只是不带项目名() throws {
        try "".write(toFile: paths.kimiConfig, atomically: true, encoding: .utf8)
        XCTAssertTrue(GlowHookInstaller.setInstalled(.kimi, true, paths: paths))
        let script = try String(contentsOfFile: paths.kimiScript, encoding: .utf8)
        let c = try runDelivering(script, args: [], stdin: #"{"session_id":"s1"}"#)
        XCTAssertEqual(c?.host, "done", "抠不到项目名不能连提醒一起丢")
        XCTAssertNil(c?.queryItems?.first { $0.name == "project" })
    }
}
