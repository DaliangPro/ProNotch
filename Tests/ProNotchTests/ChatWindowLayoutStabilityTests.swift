import XCTest
import SwiftUI
import AppKit
@testable import ProNotch

/// 闪问窗口的布局稳定性：反复改尺寸不许把主线程拖垮。
///
/// 由来（大梁老师 2026-07-31）：拖动窗口、拉宽窄、来回滚动，「有几次它就会卡死」。
/// SwiftUI 里这类卡死几乎都是**布局回环**——GeometryReader 量出尺寸写进 @State，
/// @State 又反过来影响布局，布局再触发 GeometryReader。
/// 光看代码判不出来，得压着改尺寸测耗时
@MainActor
final class ChatWindowLayoutStabilityTests: XCTestCase {

    func test反复改尺寸不卡死() throws {
        _ = NSApplication.shared
        let store = try makeStore()
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
        defer { panel.orderOut(nil as Any?) }
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        // 模拟拖拽改尺寸：连续给一串宽高，每次只留一帧的时间收敛。
        // 有回环的话这里会越跑越慢直到超时
        let start = Date()
        for step in 0..<40 {
            let w = 640 + CGFloat(step % 20) * 24
            let h = 420 + CGFloat(step % 12) * 18
            panel.setContentSize(NSSize(width: w, height: h))
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let elapsed = Date().timeIntervalSince(start)
        print("【实测】40 次改尺寸耗时 \(String(format: "%.2f", elapsed)) 秒")
        // 每次留了 0.01 秒，40 次的理论下限是 0.4 秒。放宽到 6 秒——
        // 真有回环时单次就要几百毫秒，这个阈值足以区分
        XCTAssertLessThan(elapsed, 6, "改尺寸太慢，多半是布局回环（量出的尺寸又反过来影响布局）")
    }

    private func makeStore() throws -> ChatStore {
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
        store.messages = (0..<12).map { i in
            i.isMultiple(of: 2)
            ? ChatMessage(role: .user, content: "第 \(i) 问，内容长一点好触发重排")
            : ChatMessage(role: .assistant, content: """
                ### 小标题 \(i)

                这一段要够长才会随宽度变化重新断行，**加粗**、列表、引用都来一点。

                - 第一条
                - 第二条

                > 引用一句。
                """)
        }
        return store
    }
}
