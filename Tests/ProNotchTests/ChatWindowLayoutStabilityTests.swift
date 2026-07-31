import XCTest
import SwiftUI
import AppKit
@testable import ProNotch

/// 闪问窗口的布局稳定性：反复改尺寸不许把主线程拖垮。
///
/// 由来（大梁老师 2026-07-31）：拖动窗口、拉宽窄、来回滚动，「有几次它就会卡死」。
/// 头一版这条用例只放了 12 条短消息，跑 0.56 秒，**没能复现**——阈值形同虚设。
/// 后来在他机器上卡住时抓到了采样（`sample`，间隔十几秒的两次都停在同一个布局事务里），
/// 循环形状是：
///
///   SelectionOverlay.updateNSView（`.textSelection(.enabled)` 装的那层 AppKit 视图）
///     → FallbackAlignmentProvider 量基线 → -[NSControl setFont:]
///     → -[NSTextField invalidateIntrinsicContentSize]
///     → AppKitPlatformViewHost.enqueueLayoutInvalidation()
///
/// 也就是**在布局过程中又把布局标脏**，于是 `GraphHost.flushTransactions()` 永远收敛不了。
/// 触发它要「足够多的可选中 Text」+「反复改尺寸」，所以这一版把消息量和块数都加上去
@MainActor
final class ChatWindowLayoutStabilityTests: XCTestCase {

    /// 单次改尺寸的上限。真卡住时一次就是几秒到无限，正常几十毫秒——中间空得很，不怕误报
    private let perResizeBudget: TimeInterval = 1.0

    func test反复改尺寸不卡死() throws {
        _ = NSApplication.shared
        let store = try makeStore(messageCount: 30)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                            styleMask: [.titled, .resizable, .fullSizeContentView,
                                        .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: ChatWindowChrome()
            .environmentObject(store)
            .environmentObject(SettingsStore())
            .environmentObject(QuickActionsStore())
            .environmentObject(NotchViewModel(notchRect: .zero)))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        panel.orderFront(nil as Any?)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        // 模拟拖拽改尺寸。逐次计时——总耗时会被「一次特别慢」稀释掉，单次不会
        var worst: TimeInterval = 0
        var worstStep = -1
        for step in 0..<40 {
            let t = Date()
            panel.setContentSize(NSSize(width: 640 + CGFloat(step % 20) * 24,
                                        height: 420 + CGFloat(step % 12) * 18))
            hosting.layoutSubtreeIfNeeded()
            let cost = Date().timeIntervalSince(t)
            if cost > worst { worst = cost; worstStep = step }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        print("【实测】40 次改尺寸，最慢一次 \(String(format: "%.3f", worst)) 秒（第 \(worstStep) 次）")
        XCTAssertLessThan(worst, perResizeBudget,
                          "单次改尺寸超过 \(perResizeBudget) 秒，多半是布局在自我标脏（见本文件顶部注释）")
        panel.orderOut(nil as Any?)
    }

    /// 滚动会让 LazyVStack 不断建/拆行，每建一行就多一套 AppKit 覆盖视图。
    /// 这条用「换可视高度」逼它反复建拆，比直接注入滚轮事件稳
    func test反复建拆消息行不卡死() throws {
        _ = NSApplication.shared
        let store = try makeStore(messageCount: 30)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                            styleMask: [.titled, .resizable, .fullSizeContentView,
                                        .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: ChatWindowChrome()
            .environmentObject(store)
            .environmentObject(SettingsStore())
            .environmentObject(QuickActionsStore())
            .environmentObject(NotchViewModel(notchRect: .zero)))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        panel.orderFront(nil as Any?)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        var worst: TimeInterval = 0
        for step in 0..<24 {
            let t = Date()
            panel.setContentSize(NSSize(width: 820, height: step.isMultiple(of: 2) ? 400 : 900))
            hosting.layoutSubtreeIfNeeded()
            worst = max(worst, Date().timeIntervalSince(t))
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        print("【实测】24 次改可视高度，最慢一次 \(String(format: "%.3f", worst)) 秒")
        XCTAssertLessThan(worst, perResizeBudget)
        panel.orderOut(nil as Any?)
    }

    private func makeStore(messageCount: Int) throws -> ChatStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "layout.\(UUID().uuidString)")!
        let provider = APIProvider(name: "T", baseURL: "https://example.com/v1",
                                   model: "deepseek-v4-pro", keychainAccount: "acc")
        defaults.set(try JSONEncoder().encode([provider]), forKey: "chatProviders")
        defaults.set(provider.id.uuidString, forKey: "chatCurrentProviderID")
        let store = ChatStore(env: ChatEnvironment(
            defaults: defaults, keychain: SystemKeychain(), keychainService: "layout.test",
            transport: URLSessionTransport(),
            conversationsURL: tmp.appendingPathComponent("c.json"), plaintextDomain: nil))
        store.newConversation()
        // 每条回答都塞满各类块：标题、正文、列表、任务、引用、表格、代码。
        // 块越多、可选中的 Text 越多，越接近他实际用出来的那个规模
        store.messages = (0..<messageCount).map { i in
            i.isMultiple(of: 2)
            ? ChatMessage(role: .user, content: "第 \(i) 问，写长一点好让它换行重排")
            : ChatMessage(role: .assistant, content: """
                ### 小标题 \(i)

                这一段要够长才会随宽度变化重新断行，**加粗**、`行内代码`、列表、引用都来一点，
                再多写几句凑够两三行，窄窗口下它就得重新断行。

                - 第一条要点，也写长一些
                - 第二条要点，同样写长一些
                - 第三条要点

                1. 有序第一
                2. 有序第二

                - [ ] 没做的事
                - [x] 做完的事

                > 引用一句，也让它长到需要换行的程度。

                | 名称 | 说明 |
                |---|---|
                | 甲 | 第一 |
                | 乙 | 第二 |

                ```swift
                let x = 1
                ```
                """)
        }
        return store
    }
}
