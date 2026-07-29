import XCTest
@testable import ProNotch

/// 什么时候该挡住刘海的自动收起。
///
/// 由来（2026-07-28 大梁老师反馈）：刘海有时收不回去，几次都在 AI 闪问页。
/// 根因是判据写成了「输入框有焦点」——而闪问的输入框发完消息还保持聚焦（方便追问），
/// 焦点一拿到就再没放开，于是这把锁永久挂着，鼠标移开也不收，只能按 ESC。
/// 更要命的是它是个死结：`collapse()` 里本有复位，但收起本身就被这把锁挡死了，永远执行不到。
@MainActor
final class NotchHoldTests: XCTestCase {

    private func hold(focused: Bool, draft: String = "", streaming: Bool = false) -> Bool {
        ChatStore.shouldHoldNotch(inputFocused: focused, draft: draft, streaming: streaming)
    }

    /// 核心回归：光标在输入框里但没写东西——这正是发完消息后的常态，必须能收起
    func test光标在输入框但没写东西时不挡() {
        XCTAssertFalse(hold(focused: true), "空输入框不该把刘海钉死")
    }

    /// 写了一半鼠标滑出去，不该把话弄丢
    func test有未发出的草稿时挡住() {
        XCTAssertTrue(hold(focused: true, draft: "帮我看看这段代码"))
    }

    /// 已经失焦说明人去干别的了。草稿留在 store 里不会丢，收起无妨
    func test失焦后即使有草稿也不挡() {
        XCTAssertFalse(hold(focused: false, draft: "写了一半的问题"))
    }

    /// AI 正在吐字：把正在生成的回答收走是明显的坏体验，此时连焦点都不要求
    func test流式输出中一律挡住() {
        XCTAssertTrue(hold(focused: false, draft: "", streaming: true))
        XCTAssertTrue(hold(focused: true, draft: "", streaming: true))
    }

    /// 回答完毕、草稿已清空 → 回到可收起状态。这一条串起整个使用流程：
    /// 呼出 → 打字（挡）→ 发送（流式，挡）→ 读完（不挡，鼠标移开就收）
    func test回答结束且草稿清空后恢复可收起() {
        XCTAssertTrue(hold(focused: true, draft: "问题"))          // 打字中
        XCTAssertTrue(hold(focused: true, draft: "", streaming: true))  // 发送后
        XCTAssertFalse(hold(focused: true, draft: "", streaming: false)) // 读完
    }

    /// 全空白不算数：敲个空格就把刘海钉死，跟原来的病没两样
    func test纯空白草稿不算有活没干完() {
        XCTAssertFalse(hold(focused: true, draft: "   "))
        XCTAssertFalse(hold(focused: true, draft: "\n\n"))
        XCTAssertFalse(hold(focused: true, draft: " \t "))
    }

    /// 一个字符也算：判据是「有没有」，不是「够不够长」
    func test一个字也算有草稿() {
        XCTAssertTrue(hold(focused: true, draft: "a"))
    }
}
