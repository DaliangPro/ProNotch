import XCTest
@testable import ProNotch

/// 快捷操作必须等子进程真的退出，并且只认退出码 0。
///
/// 病灶：原实现 `try task.run()` 之后立刻翻开关。`run()` 只保证进程起来了，
/// 不保证干成了——osascript 没拿到自动化授权、`defaults write` 被拒、
/// `killall Finder` 找不到进程，全都静默失败，而界面已经说「净屏已开启」了。
/// 用户看着满屏图标，开关是亮的。
@MainActor
final class ProcessRunnerTests: XCTestCase {

    // MARK: - 替身

    /// 用 actor 而不是 `@unchecked Sendable` 包一个可变对象：调用要跨线程，
    /// 记录也要跨线程，隔离交给编译器管
    private actor StubRunner: ProcessRunning {
        struct Invocation: Sendable {
            let executable: String
            let arguments: [String]
        }
        enum Outcome: Sendable {
            case exit(Int32, stderr: String)
            case launchFailure
        }

        private var outcomes: [Outcome]
        private(set) var invocations: [Invocation] = []

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func run(executable: String, arguments: [String]) async throws -> ProcessResult {
            invocations.append(Invocation(executable: executable, arguments: arguments))
            switch outcomes.isEmpty ? .exit(0, stderr: "") : outcomes.removeFirst() {
            case .exit(let status, let stderr):
                return ProcessResult(status: status, stderr: stderr)
            case .launchFailure:
                throw CocoaError(.fileNoSuchFile)
            }
        }
    }

    /// 假的「系统真实状态」。默认**不跟着命令变**——
    /// 这正是要考的点：命令说成功，状态没变，UI 就不该变
    @MainActor
    private final class FakeSystem {
        var iconsHidden = false
        var mode: QuickActionsStore.AppearanceMode = .light

        var probe: SystemStateProbe {
            SystemStateProbe(desktopIconsHidden: { self.iconsHidden },
                             appearanceMode: { self.mode })
        }
    }

    private var system: FakeSystem!
    private var store: QuickActionsStore!

    override func setUp() {
        super.setUp()
        system = FakeSystem()
    }

    override func tearDown() {
        store?.stop()
        store = nil
        super.tearDown()
    }

    private func makeStore(_ outcomes: [StubRunner.Outcome]) -> StubRunner {
        let runner = StubRunner(outcomes)
        store = QuickActionsStore(runner: runner, probe: system.probe)
        return runner
    }

    // MARK: - 退出码非 0

    func test净屏命令退出码非0_开关不翻并给出错误() async {
        _ = makeStore([.exit(1, stderr: "defaults: 权限不足")])
        XCTAssertFalse(store.desktopIconsHidden)

        store.toggleDesktopIcons()
        await store.waitForPendingAction()

        XCTAssertFalse(store.desktopIconsHidden, "命令失败了，开关不能自己翻过去")
        XCTAssertNotNil(store.actionError)
    }

    func test外观命令退出码非0_模式不变并提示去授权自动化() async {
        _ = makeStore([.exit(1, stderr: "execution error: Not authorized to send Apple events (-1743)")])

        store.setAppearance(.dark)
        await store.waitForPendingAction()

        XCTAssertEqual(store.appearanceMode, .light, "脚本没跑成，外观状态保持原样")
        XCTAssertEqual(store.actionError,
                       "外观切换失败：系统未授权 ProNotch 控制「系统事件」，请到系统设置 → 隐私与安全性 → 自动化中勾选。")
    }

    func test进程根本没起来_状态同样不变() async {
        _ = makeStore([.launchFailure])

        store.toggleDesktopIcons()
        await store.waitForPendingAction()

        XCTAssertFalse(store.desktopIconsHidden)
        XCTAssertEqual(store.actionError, "净屏切换失败：无法启动系统命令。")
    }

    // MARK: - 退出码 0

    func test净屏成功后按系统真实状态更新() async {
        let runner = makeStore([.exit(0, stderr: "")])
        system.iconsHidden = true   // 命令确实改到了系统

        store.toggleDesktopIcons()
        await store.waitForPendingAction()

        XCTAssertTrue(store.desktopIconsHidden)
        XCTAssertNil(store.actionError, "成功要把上一次的错误清掉")

        let calls = await runner.invocations
        XCTAssertEqual(calls.first?.executable, "/bin/sh")
        XCTAssertEqual(calls.first?.arguments.last,
                       "defaults write com.apple.finder CreateDesktop -bool false && killall Finder")
    }

    func test命令报成功但系统状态没变_UI也不许变() async {
        _ = makeStore([.exit(0, stderr: "")])
        // system.iconsHidden 保持 false：killall 跑了，偏好却没落地

        store.toggleDesktopIcons()
        await store.waitForPendingAction()

        XCTAssertFalse(store.desktopIconsHidden,
                       "状态要从系统重新读，不能把预设的 hide 当成既成事实")
    }

    func test外观成功后按系统真实状态更新() async {
        _ = makeStore([.exit(0, stderr: "")])
        system.mode = .dark

        store.setAppearance(.dark)
        await store.waitForPendingAction()

        XCTAssertEqual(store.appearanceMode, .dark)
        XCTAssertNil(store.actionError)
    }

    func test连点两次只跑一条命令() async {
        let runner = makeStore([.exit(0, stderr: ""), .exit(0, stderr: "")])

        store.toggleDesktopIcons()
        store.toggleDesktopIcons()   // 第二下必须被吞掉：两条相反的偏好写入会互相打架
        await store.waitForPendingAction()

        let calls = await runner.invocations
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - stderr 脱敏

    func test错误提示不回显stderr原文() {
        let leaky = ProcessResult(
            status: 1,
            stderr: "/Users/daliang/Library/Application Support/ProNotch/token=sk-live-9f3a 写入失败")
        let text = ProcessFailureMessage.text(action: "净屏切换", result: leaky)

        XCTAssertFalse(text.contains("/Users/"), "绝对路径带用户名，不能进界面")
        XCTAssertFalse(text.contains("sk-live-9f3a"), "stderr 里可能夹着密钥")
        XCTAssertFalse(text.contains("Application Support"))
        XCTAssertEqual(text, "净屏切换失败（退出码 1）。", "认不出的失败只报动作和退出码")
    }

    func test已知失败签名转成可执行的指引() {
        let cases: [(String, String)] = [
            ("execution error: … (-1743)", "自动化"),
            ("execution error: … (-1728)", "系统版本差异"),
            ("No matching processes belonging to you were found", "访达"),
            ("defaults: Operation not permitted", "权限不足"),
        ]
        for (stderr, expected) in cases {
            let text = ProcessFailureMessage.text(
                action: "净屏切换", result: ProcessResult(status: 1, stderr: stderr))
            XCTAssertTrue(text.contains(expected), "「\(stderr)」应给出含「\(expected)」的指引，实得：\(text)")
        }
    }

    // MARK: - 真进程

    func test真进程的退出码被如实带回() async throws {
        let result = try await SystemProcessRunner().run(
            executable: "/bin/sh", arguments: ["-c", "exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.succeeded == false)
    }

    func test真进程的stderr被收集且确实等到了退出() async throws {
        // sleep 让「没等退出就返回」这种实现必然读不到 stderr
        let result = try await SystemProcessRunner().run(
            executable: "/bin/sh", arguments: ["-c", "sleep 0.2; echo 出事了 >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.stderr.contains("出事了"))
    }

    func test真进程成功时退出码为0() async throws {
        let result = try await SystemProcessRunner().run(
            executable: "/bin/sh", arguments: ["-c", "true"])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stderr, "")
    }

    func test可执行文件不存在时抛错而不是返回结果() async {
        do {
            _ = try await SystemProcessRunner().run(
                executable: "/nonexistent/pronotch-not-a-real-binary", arguments: [])
            XCTFail("起不来的进程不该返回一个「成功」的结果")
        } catch {
            // 预期路径
        }
    }
}
