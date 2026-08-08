import XCTest
import SwiftUI
import AppKit
@testable import ProNotch

/// 「截图问 AI」挂上来的附件，在**独立窗口**的输入区里看不看得见。
///
/// 由来（大梁老师 2026-08-08）：「点击后会自动弹出 AI 闪问的窗口，这一步没问题，
/// 但为什么它不会把截图自动放进对话的输入框里呢？」
///
/// 根因：输入区有两份实现。刘海那份 `inputBar` 有附件缩略图，独立窗口那份
/// `windowComposer` 漏了整段——而截图问 AI 打开的正是独立窗口，等于必然踩空。
/// 图其实挂上了、也会随下一条消息发出去，但输入区一点提示都没有。
///
/// 这组用例靠**像素**判，不靠视图树：SwiftUI 的 Image 不落地成 NSImageView，
/// 走 layer 直接绘制，数 NSView 数不出来（头一版就这么栽了，数出 0 个）。
/// 所以截图故意填品红——整套 UI 配色里不存在这个颜色，出现即证明图真画出来了
@MainActor
final class ChatAttachmentProbeTests: XCTestCase {

    /// 品红像素判定：JPEG 压缩后会有偏移，给足容差
    private func magentaPixels(in rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let spp = rep.samplesPerPixel, rowBytes = rep.bytesPerRow
        var count = 0
        for y in 0..<rep.pixelsHigh {
            let row = data.advanced(by: y * rowBytes)
            for x in 0..<rep.pixelsWide {
                let p = row.advanced(by: x * spp)
                if p[0] > 190, p[1] < 90, p[2] > 190 { count += 1 }
            }
        }
        return count
    }

    func test挂上截图后独立窗口输入区画出缩略图() throws {
        _ = NSApplication.shared
        let withShot = try renderWindow(attachScreenshot: true)
        let without = try renderWindow(attachScreenshot: false)
        print("【实测】挂附件 \(withShot.magenta) 个品红像素，不挂 \(without.magenta) 个")
        XCTAssertEqual(without.magenta, 0, "没挂附件却出现品红，说明判据被 UI 自身颜色污染了")
        XCTAssertGreaterThan(withShot.magenta, 500,
                             "挂了截图但窗口里一个品红像素都没有——输入区没画缩略图（就是本文件顶部那个 bug）")
    }

    /// 附件条要把输入区顶高：光有像素不够，还得确认它是真占了一块地方、
    /// 而不是被压到别的元素底下
    func test附件条让输入区变高() throws {
        _ = NSApplication.shared
        let withShot = try renderWindow(attachScreenshot: true)
        let without = try renderWindow(attachScreenshot: false)
        print("【实测】输入区顶边 y：挂附件 \(withShot.composerTop)，不挂 \(without.composerTop)")
        XCTAssertLessThan(withShot.composerTop, without.composerTop - 20,
                          "挂了附件输入区却没变高，说明附件条没真正占位")
    }

    // MARK: - 渲染

    private struct Rendered {
        let magenta: Int
        /// 输入区顶边的 y（从窗口顶算，pt）——靠「最底部那块连续亮于背景的区域」找
        let composerTop: CGFloat
    }

    private func renderWindow(attachScreenshot: Bool) throws -> Rendered {
        let store = try makeStore()
        store.newConversation()
        store.messages = [
            ChatMessage(role: .user, content: "这张图里说的是什么意思"),
            ChatMessage(role: .assistant, content: "这是一段回答，写长一点让消息区有内容。"),
        ]
        if attachScreenshot {
            let size = NSSize(width: 600, height: 400)
            let shot = NSImage(size: size)
            shot.lockFocus()
            NSColor.magenta.setFill()
            NSRect(origin: .zero, size: size).fill()
            shot.unlockFocus()
            store.attachScreenshot(shot)
            XCTAssertNotNil(store.draftAttachment, "附件压缩这一环就该成——不成后面都不用看")
        }

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
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw XCTSkip("拿不到位图，跳过")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let name = attachScreenshot ? "attach-on" : "attach-off"
            try png.write(to: URL(fileURLWithPath: "/tmp/pronotch-\(name).png"))
        }
        let result = Rendered(magenta: magentaPixels(in: rep),
                              composerTop: composerTopEdge(rep, viewHeight: hosting.bounds.height))
        panel.orderOut(nil as Any?)
        return result
    }

    /// 从下往上扫，找输入区那块「亮于窗口底色」的连续区域的顶边。
    /// 判据取整行的平均亮度：输入框铺满整宽，比逐点判稳
    private func composerTopEdge(_ rep: NSBitmapImageRep, viewHeight: CGFloat) -> CGFloat {
        guard let data = rep.bitmapData else { return viewHeight }
        let spp = rep.samplesPerPixel, rowBytes = rep.bytesPerRow
        let scale = CGFloat(rep.pixelsHigh) / viewHeight
        // 窗口底色 white 0.118 ≈ 30；输入区 surface1 ≈ 44。取 36 当门槛
        var top = rep.pixelsHigh
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            let row = data.advanced(by: y * rowBytes)
            var sum = 0
            let step = max(1, rep.pixelsWide / 200)
            var samples = 0
            for x in stride(from: rep.pixelsWide / 4, to: rep.pixelsWide * 3 / 4, by: step) {
                let p = row.advanced(by: x * spp)
                sum += Int(p[0]); samples += 1
            }
            guard samples > 0 else { break }
            if sum / samples >= 36 { top = y } else if top < rep.pixelsHigh { break }
        }
        return CGFloat(top) / scale
    }

    private func makeStore() throws -> ChatStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "attach.\(UUID().uuidString)")!
        defaults.set("https://api.example.com/v1", forKey: PrefKey.chatBaseURL)
        defaults.set("deepseek-v4-pro", forKey: PrefKey.chatModel)
        defaults.set("sk-test", forKey: "chatAPIKey")
        return ChatStore(env: ChatEnvironment(
            defaults: defaults, keychain: ProbeKeychain(), keychainService: "attach.test",
            transport: URLSessionTransport(),
            conversationsURL: tmp.appendingPathComponent("c.json"), plaintextDomain: nil))
    }

    private final class ProbeKeychain: KeychainAccessing, @unchecked Sendable {
        func read(_ account: String, service: String) -> Result<String?, KeychainError> { .success("sk-test") }
        func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
        func delete(_ account: String, service: String) -> Result<Void, KeychainError> { .success(()) }
    }
}
