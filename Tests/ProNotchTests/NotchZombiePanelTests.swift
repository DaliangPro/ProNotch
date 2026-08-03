import XCTest
import AppKit
@testable import ProNotch

/// 刘海窗「复活」防护（大梁老师 2026-08-01：「屏幕上莫名其妙多出一个刘海」）。
///
/// 实况：单进程名下三扇刘海窗，孤儿(#31603)比现役两扇老一代、悬在 (320,323)。
/// 链条：全屏隐藏的切空间监听里有个 0.6s 延迟补查——stop() 摘监听拦不住已排队的
/// 那一发；它迟到执行撞上「全屏刚结束」，orderFrontRegardless 把已 close 的旧窗
/// 拉回屏幕；显示器变动时系统又挪过它的坐标，于是复活在屏幕中间。
/// 这组用例锁 stop() 的墓碑语义：之后任何迟到闭包都无窗可碰
@MainActor
final class NotchZombiePanelTests: XCTestCase {

    func testStop后切断窗口引用() {
        let vm = NotchViewModel(notchRect: NSRect(x: 0, y: 0, width: 200, height: 32))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        vm.panel = panel
        vm.shouldHideForFullscreen = { false }

        vm.stop()

        XCTAssertTrue(vm.stopped, "stop() 必须立墓碑")
        XCTAssertNil(vm.panel, "窗口引用必须切断——迟到闭包手里不能有窗")
        XCTAssertNil(vm.shouldHideForFullscreen, "全屏回调一并切断")
    }

    /// 墓碑之后 expandProgrammatically（快捷键呼出路径）也不得碰窗
    func testStop后快捷键路径不复活() {
        let vm = NotchViewModel(notchRect: NSRect(x: 0, y: 0, width: 200, height: 32))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        vm.panel = panel
        vm.stop()
        vm.expandProgrammatically(switchingTo: .chat)
        XCTAssertFalse(vm.isExpanded, "stop() 之后展开请求应被墓碑挡下")
        XCTAssertFalse(panel.isVisible, "旧窗不许因此上屏")
    }
}
