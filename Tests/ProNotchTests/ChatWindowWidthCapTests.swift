import XCTest
import AppKit
@testable import ProNotch

/// 闪问窗口的宽度上限。
///
/// 由来（大梁老师 2026-07-31）：上一版只设了 `panel.maxSize`，他反馈「并没有做限制」。
/// 探针实测确认 `maxSize` 夹不住尺寸——设成 1180 之后 `setContentSize(1600)` 照出 1600，
/// 它只负责让边角光标显示「不能再宽」。真闸门是 `windowWillResize`，这组用例锁的就是它
@MainActor
final class ChatWindowWidthCapTests: XCTestCase {

    private var panel: NSWindow { NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                                           styleMask: [.titled, .resizable],
                                           backing: .buffered, defer: true) }

    func test超过上限被夹回() {
        let c = ChatWindowController.shared
        let out = c.windowWillResize(panel, to: NSSize(width: 1600, height: 700))
        XCTAssertEqual(out.width, ChatWindowController.maxWindowWidth)
    }

    /// 由来（大梁老师 2026-07-31「620 停不住」）：实现了 windowWillResize 委托后
    /// 系统不再执行 minSize，下限必须由委托自己夹。这条拖穿过一次，别再放行
    func test窄于下限被抬回() {
        let c = ChatWindowController.shared
        let out = c.windowWillResize(panel, to: NSSize(width: 300, height: 700))
        XCTAssertEqual(out.width, ChatWindowController.minWindowSize.width)
    }

    /// 高度下限同理归委托管（矮于 380 抬回）
    func test矮于下限被抬回() {
        let c = ChatWindowController.shared
        let out = c.windowWillResize(panel, to: NSSize(width: 800, height: 200))
        XCTAssertEqual(out.height, ChatWindowController.minWindowSize.height)
    }

    func test上限以内原样放行() {
        let c = ChatWindowController.shared
        let out = c.windowWillResize(panel, to: NSSize(width: 900, height: 700))
        XCTAssertEqual(out.width, 900)
    }

    /// 高度**上限**不设：长答案要能拉满整屏（下限另有用例）
    func test高度上限不设() {
        let c = ChatWindowController.shared
        for h in [700.0, 1600.0, 4000.0] {
            XCTAssertEqual(c.windowWillResize(panel, to: NSSize(width: 800, height: h)).height, h)
        }
    }

    /// 上限得容得下「最宽正文列 + 侧栏」，否则侧栏一开正文就被压到不足宽
    func test上限容得下正文列加侧栏() {
        XCTAssertGreaterThanOrEqual(ChatWindowController.maxWindowWidth, 920 + 220)
    }

    /// 兜底闸的纯逻辑（大梁老师 2026-07-31「限制好像没了」后加）：
    /// 双击边缘智能放大等路径绕开 windowWillResize，落地由 windowDidResize 夹回
    func test兜底夹取覆盖双向越界() {
        XCTAssertEqual(ChatWindowController.clampedWidth(2560, minWidth: 620), 1180, "智能放大到全屏宽要收回")
        XCTAssertEqual(ChatWindowController.clampedWidth(300, minWidth: 620), 620, "窄于下限要抬回")
        XCTAssertEqual(ChatWindowController.clampedWidth(800, minWidth: 620), 800, "合法宽度原样放行")
    }

    /// 这条是反向锁：哪天有人以为 `maxSize` 够用而把 windowWillResize 删了，
    /// 这里会立刻红——它证明的是「光设 maxSize 不管用」这个事实本身
    func test光设maxSize夹不住尺寸() {
        let w = panel
        w.maxSize = NSSize(width: 1180, height: CGFloat.greatestFiniteMagnitude)
        w.setContentSize(NSSize(width: 1600, height: 700))
        XCTAssertEqual(w.frame.width, 1600, accuracy: 1,
                       "若某天 AppKit 改成真夹，这条会红——那时才可以考虑撤掉 windowWillResize")
    }
}
