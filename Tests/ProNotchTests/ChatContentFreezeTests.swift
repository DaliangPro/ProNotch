import XCTest
import AppKit
@testable import ProNotch

/// 内容列宽度冻结的状态机（拖缩流畅性的地基）。
///
/// 由来（大梁老师 2026-07-31）：卡死修完后拖边缘缩放、开合侧栏「非常卡顿」——
/// 宽度每变一帧，全量渲染的正文就整列重新断行一帧。修法是变宽期间把内容列
/// 钉在原宽（纯位移，零断行），结束后一次断行到位。这里锁状态机本身
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

    func test侧栏开合冻一小段自动放开() {
        let c = ChatWindowController.shared
        c.freezeContentBriefly(0.05)
        XCTAssertTrue(c.contentFrozen)
        let exp = expectation(description: "到点自动放开")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertFalse(c.contentFrozen)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    /// 短冻期间开始真实拖缩：拖缩的「结束」说了算，不能被此前的定时器提前放开
    func test拖缩接管短冻定时器() {
        let c = ChatWindowController.shared
        c.freezeContentBriefly(0.05)
        c.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification,
                                                 object: dummy))
        let exp = expectation(description: "定时器过点后仍冻着")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertTrue(c.contentFrozen, "拖缩还没结束，旧定时器不许把冻结偷偷解开")
            c.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification,
                                                  object: self.dummy))
            XCTAssertFalse(c.contentFrozen)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    /// 连点历史按钮：每次都重新计时，不许第一次的定时器把第二次的冻结提前解开
    func test连续短冻重新计时() {
        let c = ChatWindowController.shared
        c.freezeContentBriefly(0.05)
        c.freezeContentBriefly(10)   // 第二次冻很久
        let exp = expectation(description: "第一次的定时器不生效")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertTrue(c.contentFrozen, "第二次还在冻，第一次的定时器该被作废")
            c.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification,
                                                  object: self.dummy))   // 收尾复位
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
