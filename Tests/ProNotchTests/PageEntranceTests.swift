import XCTest
import SwiftUI
import AppKit
@testable import ProNotch

/// PageEntrance 的时序语义（闪问切页即现的机制锁）。
///
/// 由来（大梁老师 2026-07-31 第四轮「切进闪问卡顿」）：出场编排每次切页挂载都重播——
/// 整页先透明 0.10s 再逐条发牌。修法是 replayOnRemount: false（挂载即现）。
/// 像素级 A/B 在真机被换页交叉淡出污染（新旧页亮度混在一帧里分不开），
/// 这里直接锁**时序本身**：挂载后 played 何时翻 true，确定性可测
@MainActor
final class PageEntranceTests: XCTestCase {

    private final class Flag {
        var value = false
    }

    /// 挂一个带 pageEntrance 的最小视图，返回读值口
    private func mount(replayOnRemount: Bool) -> (flag: Flag, panel: NSPanel) {
        let flag = Flag()
        let binding = Binding(get: { flag.value }, set: { flag.value = $0 })
        let host = NSHostingView(rootView: Color.clear
            .frame(width: 10, height: 10)
            .pageEntrance(binding, active: true, replayOnRemount: replayOnRemount)
            .environmentObject(NotchViewModel(notchRect: .zero)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        panel.orderFront(nil as Any?)
        return (flag, panel)
    }

    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// 修复语义：不重播的页，挂载后立刻亮齐——0.10s 的透明窗口不存在
    func test挂载即现不等一拍() {
        let (flag, panel) = mount(replayOnRemount: false)
        defer { panel.orderOut(nil as Any?) }
        spin(0.05)   // 只给 .task 一个起跑的机会，远小于旧行为的 0.10s 延迟
        XCTAssertTrue(flag.value, "replayOnRemount=false 挂载后应立即 played=true（内容即现）")
    }

    /// 旧语义仍保留给其他页：挂载后先透明（0.05s 时还没翻），0.10s 延迟后才播
    func test重播页先透明后起播() {
        let (flag, panel) = mount(replayOnRemount: true)
        defer { panel.orderOut(nil as Any?) }
        spin(0.05)
        XCTAssertFalse(flag.value, "重播页在 0.10s 延迟内应仍是透明起点")
        spin(0.25)
        XCTAssertTrue(flag.value, "延迟过后应翻 true 起播出场")
    }
}
