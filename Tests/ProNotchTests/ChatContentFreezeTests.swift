import XCTest
import AppKit
@testable import ProNotch

/// 内容列宽度冻结的状态机（拖缩流畅性的地基）。
///
/// 由来（大梁老师 2026-07-31）：卡死修完后拖边缘缩放「非常卡顿」——
/// 宽度每变一帧，全量渲染的正文就整列重新断行一帧。修法是拖缩期间把内容列
/// 钉在原宽（纯位移，零断行），结束后一次断行到位。这里锁起止映射。
/// （曾有「侧栏开合短冻」的定时器变体及三条用例，侧栏改悬浮层后一并退役）
@MainActor
final class ChatContentFreezeTests: XCTestCase {

    private var dummy: NSWindow { NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                           styleMask: [.titled, .resizable],
                                           backing: .buffered, defer: true) }

    func test实时拖缩起止映射冻结() {
        let c = ChatWindowController.shared
        c.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification,
                                                 object: dummy))
        XCTAssertTrue(c.contentFrozen, "开始拖就该冻住")
        c.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification,
                                              object: dummy))
        XCTAssertFalse(c.contentFrozen, "拖完必须立刻放开，正文才能断行到位")
    }
}
