import XCTest
@testable import ProNotch

/// 切换器的选择必须锚在条目 ID 上，不能锚在下标上。
///
/// 病灶：面板开着的时候剪贴板还在轮询。用户刚点中第 2 张卡，一条新内容进来插到
/// items[0]，后面全体下标平移一位——屏幕上高亮的还是原来那张，回车粘出来的却是隔壁那条。
/// 删除、话术拖拽重排是同一个病：位置会变，身份不会。
@MainActor
final class ClipboardSwitcherSelectionTests: XCTestCase {

    private var tempDir: URL!
    private var store: ClipboardStore!
    private var snippets: SnippetStore!
    private var controller: ClipboardSwitcherController!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProNotchSwitcher-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ClipboardStore(directory: tempDir.appendingPathComponent("Clipboard"))
        snippets = SnippetStore(fileURL: tempDir.appendingPathComponent("snippets.json"))
        controller = ClipboardSwitcherController()
        controller.configure(store: store, snippets: snippets)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// 列表变更触发的重算是推迟一轮做的（@Published 在赋值前发信号），测试要等它落地
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
            if !controller.selectedIDs.isEmpty || store.items.isEmpty { return }
        }
    }

    /// 造三条历史，屏幕顺序为 丙 乙 甲（items[0] 最新）
    private func seedHistory() async {
        store.capture(text: "甲")
        store.capture(text: "乙")
        store.capture(text: "丙")
        await settle()
        XCTAssertEqual(store.items.map { $0.text }, ["丙", "乙", "甲"])
    }

    // MARK: - 历史态

    func test面板开着时来了新内容_选中的仍是原来那一条() async {
        await seedHistory()
        controller.handleTap(at: 1, command: false, shift: false)   // 选中「乙」
        XCTAssertEqual(controller.selectedHistoryItems.map { $0.text }, ["乙"])

        store.capture(text: "刚复制的新内容")                        // 插到 items[0]，下标全体平移
        await settle()

        XCTAssertEqual(controller.selectedIndex, 2, "「乙」现在排在第 3 位，高亮要跟过去")
        XCTAssertEqual(controller.selectedSet, [2])
        XCTAssertEqual(controller.selectedHistoryItems.map { $0.text }, ["乙"],
                       "回车粘出来的必须还是用户当初点的那条")
    }

    func test多选后来了新内容_合并复制的仍是原来那几条() async {
        await seedHistory()
        controller.handleTap(at: 0, command: false, shift: false)   // 丙
        controller.handleTap(at: 2, command: true, shift: false)    // ⌘ 加选 甲

        store.capture(text: "新内容")
        await settle()

        // 合并复制按剪贴板时间旧→新
        XCTAssertEqual(controller.selectedHistoryItems.map { $0.text }, ["甲", "丙"])
        XCTAssertEqual(controller.selectedSet, [1, 3], "两条各自平移一位")
    }

    func test连选区间按当前顺序取_锚点也认ID() async {
        await seedHistory()
        controller.handleTap(at: 0, command: false, shift: false)   // 锚点 = 丙
        store.capture(text: "新内容")                                // 丙 平移到下标 1
        await settle()

        controller.select(at: 3, command: false, shift: true)       // ⇧ 选到 甲（现在的末条）
        XCTAssertEqual(controller.selectedHistoryItems.map { $0.text }, ["甲", "乙", "丙"],
                       "区间要从平移后的锚点算起，不能还按老下标")
    }

    func test删除一条后_焦点落到原位置那一条() async {
        await seedHistory()
        controller.handleTap(at: 1, command: false, shift: false)   // 乙
        controller.delete(at: 1)                                     // 删掉乙
        await settle()

        XCTAssertEqual(store.items.map { $0.text }, ["丙", "甲"])
        XCTAssertEqual(controller.selectedIndex, 1)
        XCTAssertEqual(controller.selectedHistoryItems.map { $0.text }, ["甲"])
    }

    func test删除末条后_焦点退一格不越界() async {
        await seedHistory()
        controller.handleTap(at: 2, command: false, shift: false)   // 甲（末条）
        controller.delete(at: 2)
        await settle()

        XCTAssertEqual(controller.selectedIndex, 1)
        XCTAssertEqual(controller.selectedHistoryItems.map { $0.text }, ["乙"])
    }

    func test被删掉的条目从选择集合里剔除() async {
        await seedHistory()
        controller.handleTap(at: 0, command: false, shift: false)
        controller.handleTap(at: 1, command: true, shift: false)    // 选中 丙 + 乙
        XCTAssertEqual(controller.selectedIDs.count, 2)

        store.delete(store.items[1])                                 // 从别处（面板外）删掉乙
        await settle()

        XCTAssertEqual(controller.selectedHistoryItems.map { $0.text }, ["丙"],
                       "消失的条目要剔除，还在的要留住")
        XCTAssertFalse(controller.selectedIDs.isEmpty, "不能把选择清空成什么都没选")
    }

    // MARK: - 话术态

    func test话术拖拽重排_选中跟着那条话术走() async {
        snippets.add(title: nil, content: "丙")
        snippets.add(title: nil, content: "乙")
        snippets.add(title: nil, content: "甲")   // 屏幕顺序 甲 乙 丙
        controller.setMode(.snippet)

        controller.handleTap(at: 0, command: false, shift: false)   // 选中「甲」
        controller.moveSnippet(from: 0, to: 2)                      // 拖到末尾 → 乙 丙 甲

        XCTAssertEqual(snippets.snippets.map(\.content), ["乙", "丙", "甲"])
        XCTAssertEqual(controller.selectedIndex, 2, "高亮跟着被拖的那条走")
        XCTAssertEqual(controller.selectedIDs, [.snippet(snippets.snippets[2].id)])
    }

    func test模式切换_选择明确复位到第一条() async {
        await seedHistory()
        snippets.add(title: nil, content: "话术一")
        snippets.add(title: nil, content: "话术二")
        controller.handleTap(at: 2, command: false, shift: false)   // 历史态选到末条

        controller.setMode(.snippet)
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(controller.selectedIDs, [.snippet(snippets.snippets[0].id)],
                       "两态内容完全不同，切过去就该从头开始，不做跨态记忆")

        controller.setMode(.history)
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(controller.selectedIDs, [.history(store.items[0].id)])
    }

    func test两态ID互不混淆() {
        let shared = UUID()
        XCTAssertNotEqual(SwitcherItemID.history(shared), SwitcherItemID.snippet(shared),
                          "历史与话术是两套独立 UUID，撞号也不能当成同一条")
    }
}
