import XCTest
import SwiftUI
@testable import ProNotch

/// 回车换行的判据。
///
/// 由来（大梁老师 2026-08-08）：输入框在代码里有两份实现（刘海 `inputBar`、
/// 独立窗 `windowComposer`），「⌘回车与 ⇧回车都换行」这条 2026-07-31 定下的规则
/// 只落到了独立窗一处，刘海里按 ⇧回车不换行、直接把没写完的话发出去了。
/// 现在判据收成一份，这组用例把它钉住
final class ChatNewlineShortcutTests: XCTestCase {

    func test按住Command回车换行() {
        XCTAssertTrue(ChatView.isNewlineShortcut(.command))
    }

    /// 就是漏掉的那一半
    func test按住Shift回车也换行() {
        XCTAssertTrue(ChatView.isNewlineShortcut(.shift))
    }

    func test光秃秃的回车是发送不是换行() {
        XCTAssertFalse(ChatView.isNewlineShortcut([]),
                       "不带修饰键的回车必须落给 onSubmit 发送，认成换行就发不出消息了")
    }

    /// ⌥回车由 AppKit 字段编辑器原生处理，不该被这层拦下来自己插换行
    func test按住Option回车不归这层管() {
        XCTAssertFalse(ChatView.isNewlineShortcut(.option))
    }

    /// 组合键里只要带上 ⌘ 或 ⇧ 就算换行——用户按 ⇧⌘回车不该反而发出去
    func test组合修饰键仍按换行处理() {
        XCTAssertTrue(ChatView.isNewlineShortcut([.command, .shift]))
        XCTAssertTrue(ChatView.isNewlineShortcut([.shift, .option]))
        XCTAssertTrue(ChatView.isNewlineShortcut([.command, .control]))
    }

    func test只按control不算换行() {
        XCTAssertFalse(ChatView.isNewlineShortcut(.control))
    }
}
