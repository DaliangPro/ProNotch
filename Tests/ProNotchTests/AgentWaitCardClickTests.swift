import XCTest
import SwiftUI
@testable import ProNotch

/// 「等你拍板」卡上的按钮**真按得下去吗**。
///
/// 这类病离屏渲染和普通单测都照不出来：卡渲染得一模一样、store 的方法也全对，
/// 可实机上一个按钮都点不动（实际发生过——刘海黑形状的 `clipShape` 只裁画面不裁点击，
/// 把垫在底下的整张卡的点击全吃了，见 NotchContainerView 的 contentShape 注释）。
/// 所以这里往真实视图树里合成鼠标点击，按落地的答复文件反推「到底按到了没有、按到了哪个」。
///
/// 容器层（黑形状盖住卡）的那道防线在 App 里另有探针：
/// `-snapshotPanel collapsed -notchCardScene 单条建议 -notchCardHitProbe`
@MainActor
final class AgentWaitCardClickTests: XCTestCase {

    private var tmp: URL!
    private var paths: GlowHookPaths!

    override func setUpWithError() throws {
        // 合成事件要走 AppKit 的分发；测试进程默认没建 NSApplication，
        // 不先建起来 SwiftUI 的手势系统压根收不到事件（会误报成「点不到」）
        NSApplication.shared.setActivationPolicy(.accessory)
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("card-click-\(UUID().uuidString)")
        paths = GlowHookPaths.rooted(at: tmp.path)
        try FileManager.default.createDirectory(atPath: paths.permissionDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    private static let requestID = String(repeating: "c", count: 32)

    /// 摆一张真卡：真 ViewModel、真 store、真 broker（只把落盘目录换到临时目录）
    private func hostCard() -> (NSWindow, NSHostingView<AnyView>, AgentWaitStore, CGSize) {
        let vm = NotchViewModel(notchRect: CGRect(x: 380, y: 0, width: 200, height: 38))
        let wait = AgentWaitStore(broker: AgentPermissionBroker(paths: paths))
        wait.present(
            AgentWaitNotice(
                source: .claude, session: "s1", host: nil, project: "ProNotch",
                request: AgentPermissionRequest(
                    id: Self.requestID, tool: "Bash", detail: "git push",
                    session: "s1", project: "ProNotch",
                    options: [AgentPermissionOption(title: "不再询问", detail: "Bash(git push:*)",
                                                    payload: Data("{}".utf8))])),
            frontmost: nil)
        let size = vm.expandedShapeSize
        let root = AnyView(
            ZStack(alignment: .top) { AgentWaitCardView() }
                .environmentObject(vm)
                .environmentObject(wait)
                .environmentObject(AgentSessionsStore())
                // 必须 .top：卡是从屏幕顶边的刘海长出来的，
                // 用默认居中会让整卡下移一半，按钮就不在真实位置上了
                .frame(width: size.width, height: size.height, alignment: .top))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        // 事件路由要求窗口在场；挪到屏幕外再现身，跑测试时不会有窗口闪出来
        win.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        win.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        spin(0.4)   // 等揭示动画走到终态，按钮才在它该在的位置上
        return (win, hosting, wait, size)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func click(_ win: NSWindow, _ point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            win.sendEvent(event)
        }
        spin(0.01)
    }

    private var response: [String: Any]? {
        let path = paths.permissionDir + "/\(Self.requestID).response.json"
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    }

    /// 卡最下面那行按钮，从左往右第一个是「允许一次」。
    /// 逐点扫是必要的：写死一个坐标，日后按钮挪 10pt 测试就变成假绿灯
    func test卡上第一个按钮真按得下去且答的是允许() throws {
        let (win, _, wait, size) = hostCard()
        defer { win.close() }
        let cardWidth: CGFloat = 560
        // 卡高随建议条数变（多一条建议多一行），扫描起点跟着算，别写死
        let grown = wait.notice?.request.map(AgentWaitCardView.grownHeight(for:)) ?? 176
        let cardBottom = size.height - 38 - grown
        var pressed: NSPoint?
        outer: for y in stride(from: cardBottom + 4, through: cardBottom + 60, by: 6) {
            for x in stride(from: (size.width - cardWidth) / 2 + 8,
                            through: (size.width - cardWidth) / 2 + 120, by: 8) {
                click(win, NSPoint(x: x, y: y))
                if wait.notice == nil { pressed = NSPoint(x: x, y: y); break outer }
            }
        }
        XCTAssertNotNil(pressed, "卡上按钮区域的点击全被吞掉了——实机上就是「弹出来了但点不动」")
        XCTAssertEqual(response?["behavior"] as? String, "allow",
                       "按到的应该是「允许一次」，答复必须是 allow")
        XCTAssertNil(response?["updatedPermissions"], "「允许一次」不写永久规则")
    }
}
