import XCTest
import SwiftUI
import AppKit
@testable import ProNotch

/// 右键删除之后，开着的那个面板必须当场刷新干净。
///
/// 由来（大梁老师 2026-07-31）：删完没有任何反馈，那条还在，重开才消失。
/// 数据层和视图绑定看着都对（items 是 @Published，视图是 @ObservedObject），
/// 光读代码看不出来——病在卡片用 `.id(idx)` 把身份盖成了下标，删掉一条后
/// 每格都复用了旧内容。只有把真视图装进离屏窗口、删一条、前后比像素才抓得到。
///
/// 两条断言缺一不可：只比「前后不同」会被「末尾少一张」这种假刷新骗过去，
/// 还得跟同数据的全新渲染逐像素对齐才算刷新彻底
@MainActor
final class ClipboardDeleteRefreshTests: XCTestCase {

    func test删除后面板当场刷新且与全新渲染一致() throws {
        _ = NSApplication.shared
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = ClipboardStore(directory: tmp)
        let snippets = SnippetStore(fileURL: tmp.appendingPathComponent("snippets.json"))
        let controller = ClipboardSwitcherController.shared
        controller.configure(store: store, snippets: snippets)

        store.loadDemoItems()
        let before = store.items.count
        XCTAssertGreaterThan(before, 2, "先得有几条才谈得上删")

        let view = ClipboardSwitcherView(store: store, snippets: snippets, controller: controller)
            .environmentObject(store)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 368)

        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.clear
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        win.orderFront(nil as Any?)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        defer { win.orderOut(nil as Any?) }

        func shoot() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }

        let shotBefore = try shoot()

        // 走真实路径：右键菜单按的就是 controller.delete(at:)
        controller.delete(at: 0)
        XCTAssertEqual(store.items.count, before - 1, "数据层必须真的少一条")

        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let shotAfter = try shoot()

        // 再拿同一份数据全新渲一张：活着的那个视图若与它不一致，就是刷新得不彻底
        let fresh = NSHostingView(rootView: ClipboardSwitcherView(
            store: store, snippets: snippets, controller: controller).environmentObject(store))
        fresh.appearance = NSAppearance(named: .darkAqua)
        fresh.frame = host.frame
        let freshWin = NSWindow(contentRect: fresh.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        freshWin.isOpaque = false
        freshWin.backgroundColor = NSColor.clear
        freshWin.appearance = NSAppearance(named: .darkAqua)
        freshWin.contentView = fresh
        freshWin.setFrameOrigin(NSPoint(x: -6000, y: -3000))
        freshWin.orderFront(nil as Any?)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        fresh.layoutSubtreeIfNeeded()
        let freshRep = try XCTUnwrap(fresh.bitmapImageRepForCachingDisplay(in: fresh.bounds))
        fresh.cacheDisplay(in: fresh.bounds, to: freshRep)
        let shotFresh = try XCTUnwrap(freshRep.representation(using: .png, properties: [:]))
        freshWin.orderOut(nil as Any?)

        XCTAssertNotEqual(shotBefore, shotAfter, "删了一条，画面必须跟着变")
        XCTAssertEqual(shotAfter, shotFresh, "活着的视图必须和同数据全新渲染一模一样，不能留着旧格子")
    }
}
