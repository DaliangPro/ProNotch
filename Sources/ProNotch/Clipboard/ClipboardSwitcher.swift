import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices

/// 可成为 key 的无边框面板（无边框 NSPanel 默认不能接收键盘，覆写打开）
private final class ClipboardSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 剪贴板切换器：全局快捷键唤出的独立大面板，横向卡片浏览历史。
/// ← → 选择、回车粘贴回原 App、Esc 取消；鼠标点击卡片即粘贴；点面板外或再按快捷键收起。
@MainActor
final class ClipboardSwitcherController: NSObject, ObservableObject {
    static let shared = ClipboardSwitcherController()

    /// 面板两态：剪贴板历史 / 常用话术
    enum Mode { case history, snippet }
    @Published var mode: Mode = .history

    @Published var selectedIndex = 0            // 键盘焦点（← → 移动）
    @Published var selectedSet: Set<Int> = []   // 选中集合（单击=单选，⇧单击=多选）
    @Published var copiedFlash: Int?            // 正在闪「已复制 ✓」的卡片索引
    @Published var keyboardScrollTick = 0       // 仅键盘移动时滚动居中（鼠标点击不动卡片，避免落点错位）

    // 话术编辑器（面板自管编辑态：无边框面板键盘被全局拦，编辑时放行键入）
    @Published var editorVisible = false
    @Published var editorText = ""
    @Published var editorTitle = ""                       // 编辑态标题草稿（可选）
    @Published private(set) var editingExisting = false   // true=改已有，false=新增（决定标题/按钮文案）
    private var editingSnippetID: UUID?

    private var anchorIndex = 0                 // 连选锚点（最近一次非 ⇧ 点击的位置）
    private var lastTapIndex: Int?              // 上次单击的卡片索引（手动检测双击用）
    private var lastTapAt = Date.distantPast    // 上次单击时间

    private var store: ClipboardStore?
    private var snippets: SnippetStore?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var previousApp: NSRunningApplication?

    private let panelSize = NSSize(width: 980, height: 368)

    /// 注入数据源（AppDelegate 启动时调用）
    func configure(store: ClipboardStore, snippets: SnippetStore) {
        self.store = store
        self.snippets = snippets
    }

    /// 当前态条目数（键盘导航 / 索引钳制统一走它）
    private var count: Int {
        switch mode {
        case .history: return store?.items.count ?? 0
        case .snippet: return snippets?.snippets.count ?? 0
        }
    }

    /// 快捷键入口：已显示则收起，否则唤出（toggle）
    func toggle() {
        if panel != nil { dismiss(copying: nil) } else { summon() }
    }

    // MARK: - 唤出 / 收起

    private func summon() {
        guard let store, let snippets else { return }
        let hasHistory = !store.items.isEmpty
        let hasSnippet = !snippets.snippets.isEmpty
        guard hasHistory || hasSnippet else { return }            // 两者皆空才不唤，避免空面板
        previousApp = NSWorkspace.shared.frontmostApplication      // 记住原前台 App，用于回填焦点 + 粘贴
        mode = hasHistory ? .history : .snippet                    // 历史空但话术非空则直接进话术态
        cancelEditor()
        selectedIndex = 0
        selectedSet = count > 0 ? [0] : []
        anchorIndex = 0

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen.map { s -> NSRect in
            NSRect(x: s.frame.midX - panelSize.width / 2,
                   y: s.frame.midY - panelSize.height / 2,
                   width: panelSize.width, height: panelSize.height)
        } ?? NSRect(origin: .zero, size: panelSize)

        // nonactivating：面板成为键盘焦点但不激活 ProNotch——呼出免跨进程激活等待
        // （原前台 App 忙时激活会排队，正是偶发「不跟手」的来源），收起也免还焦点
        let p = ClipboardSwitcherPanel(contentRect: frame,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView:
            ClipboardSwitcherView(store: store, snippets: snippets, controller: self)
                .environmentObject(store))
        panel = p

        p.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    private func dismiss(copying action: (() -> Void)? = nil, thenPaste: Bool = false) {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        if let action {
            action()                                               // 先收起再写剪贴板，避免自捕获面板内容
            previousApp?.activate()
            if thenPaste, AXPermission.ensure() {             // 无辅助功能权限：仅复制，用户手动 ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.postCommandV() }
            }
        } else {
            previousApp?.activate()                                // 取消也把焦点还回去
        }
        previousApp = nil
    }

    // MARK: - 选择 / 复制

    private func move(_ delta: Int) {
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        selectedSet = [selectedIndex]                              // 键盘移动回到单选
        anchorIndex = selectedIndex
        keyboardScrollTick += 1                                    // 只有键盘移动才滚动居中
    }

    /// 切换历史/话术态：清编辑器、复位选中与滚动
    func setMode(_ m: Mode) {
        guard m != mode else { return }
        cancelEditor()
        mode = m
        selectedIndex = 0
        selectedSet = count > 0 ? [0] : []
        anchorIndex = 0
        keyboardScrollTick += 1
    }

    func toggleMode() { setMode(mode == .history ? .snippet : .history) }

    /// 标准图标选择语义（同 Finder）：单击=单选；⌘单击=逐个加选/减选；⇧单击=锚点到当前的整段连选。
    /// 话术态是独立文案，不做多选合并，恒定单选
    func select(at idx: Int, command: Bool, shift: Bool) {
        guard idx >= 0, idx < count else { return }
        if mode == .snippet {
            selectedSet = [idx]; anchorIndex = idx; selectedIndex = idx; return
        }
        if shift {
            selectedSet = Set(min(anchorIndex, idx)...max(anchorIndex, idx))   // 连选：锚点不动
        } else if command {
            if selectedSet.contains(idx) { selectedSet.remove(idx) } else { selectedSet.insert(idx) }
            if selectedSet.isEmpty { selectedSet = [idx] }         // 至少保留一个选中
            anchorIndex = idx
        } else {
            selectedSet = [idx]
            anchorIndex = idx
        }
        selectedIndex = idx
    }

    /// 回车：当前选中粘贴回原 App（历史=单条或多条合并；话术=单条文案）
    func confirm() {
        let action = (mode == .snippet) ? snippetCopyAction() : makeCopyAction()
        guard let action else { dismiss(copying: nil); return }
        dismiss(copying: action, thenPaste: true)
    }

    /// 双击卡片：选中该卡并立即粘贴回原 App
    func activate(at idx: Int) {
        select(at: idx, command: false, shift: false)
        confirm()
    }

    /// 单击/双击分发：单击即时选中（不再用 count:2 手势，消除单击等双击判定的 0.25s 延迟）；
    /// 0.35s 内二次点击同一卡片（无修饰键）视为双击 → 粘贴回原 App
    func handleTap(at idx: Int, command: Bool, shift: Bool) {
        if !command, !shift, idx == lastTapIndex, Date().timeIntervalSince(lastTapAt) < 0.35 {
            lastTapIndex = nil
            lastTapAt = .distantPast
            activate(at: idx)
            return
        }
        lastTapIndex = idx
        lastTapAt = Date()
        select(at: idx, command: command, shift: shift)
    }

    /// 右键删除该卡；删除后修正选中索引。当前态删空则切到另一态，两态皆空才收起面板
    func delete(at idx: Int) {
        switch mode {
        case .history:
            guard let store, store.items.indices.contains(idx) else { return }
            store.delete(store.items[idx])
        case .snippet:
            guard let snippets, snippets.snippets.indices.contains(idx) else { return }
            snippets.delete(snippets.snippets[idx])
        }
        if count == 0 {                                            // 当前态空了
            mode = (mode == .history) ? .snippet : .history
            selectedIndex = 0
            if count == 0 { dismiss(copying: nil); return }        // 另一态也空 → 收起
            selectedSet = [0]
            anchorIndex = 0
            keyboardScrollTick += 1
            return
        }
        selectedIndex = min(selectedIndex, count - 1)
        selectedSet = [selectedIndex]
        anchorIndex = selectedIndex
    }

    /// 话术拖拽重排：把 from 处的话术移到 to 处，选中跟到新位置。
    /// 刻意不动 keyboardScrollTick——拖动中滚动居中会让卡片在手底下乱跑（同「鼠标操作不滚动」的原则）
    func moveSnippet(from: Int, to: Int) {
        guard mode == .snippet, let snippets else { return }
        snippets.move(from: from, to: to)
        guard count > 0 else { return }
        selectedIndex = min(max(to, 0), count - 1)
        selectedSet = [selectedIndex]
        anchorIndex = selectedIndex
    }

    /// ⌘C：当前选中复制到剪贴板并收起，不自动粘贴（历史=单条或多条合并；话术=单条）
    func copySelection() {
        let action = (mode == .snippet) ? snippetCopyAction() : makeCopyAction()
        guard let action else { return }
        dismiss(copying: action, thenPaste: false)
    }

    /// 卡片下的「复制」按钮：历史态多选则复制整个多选，否则复制这一条；话术态复制该条文案。
    /// 先原地亮「已复制 ✓」再收起——不无声关面板，用户明确知道复制发生了
    func copyButtonTapped(at idx: Int) {
        guard idx >= 0, idx < count, copiedFlash == nil else { return }
        let action: (() -> Void)?
        switch mode {
        case .history:
            guard let store, store.items.indices.contains(idx) else { return }
            if selectedSet.count >= 2, selectedSet.contains(idx) {
                action = makeCopyAction()
            } else {
                let item = store.items[idx]
                action = { [weak store] in store?.copyToPasteboard(item) }
            }
        case .snippet:
            guard let snippets, snippets.snippets.indices.contains(idx) else { return }
            let text = snippets.snippets[idx].content
            action = { [weak store] in store?.copyExternal(text: text) }
        }
        guard let action else { return }
        action()                                   // copyToPasteboard/copyExternal 会同步 changeCount，不会自捕获
        copiedFlash = idx
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.panel != nil else { return }
            self.copiedFlash = nil
            self.dismiss(copying: nil)             // 已复制完，纯收起
        }
    }

    /// 选中集合 → 复制动作：选了什么就复制什么。单条原样复制；多条按剪贴板时间顺序（旧→新）
    /// 全部进剪贴板——文本合并为一段，图片作为独立对象一并写入
    private func makeCopyAction() -> (() -> Void)? {
        guard let store else { return nil }
        let valid = (selectedSet.isEmpty ? [selectedIndex] : Array(selectedSet))
            .filter { store.items.indices.contains($0) }
        guard !valid.isEmpty else { return nil }
        if valid.count == 1, let i = valid.first {
            let item = store.items[i]
            return { [weak store] in store?.copyToPasteboard(item) }
        }
        let ordered = valid.sorted(by: >).map { store.items[$0] } // items[0] 最新 → 索引降序 = 时间旧→新
        return { [weak store] in store?.copyMerged(ordered) }
    }

    /// 话术态：当前选中话术 → 写剪贴板动作（回车/⌘C/复制按钮共用），文案走剪贴板
    private func snippetCopyAction() -> (() -> Void)? {
        guard let snippets, snippets.snippets.indices.contains(selectedIndex) else { return nil }
        let text = snippets.snippets[selectedIndex].content
        return { [weak store] in store?.copyExternal(text: text) }
    }

    // MARK: - 话术编辑（面板内浮层）

    /// 新增话术：切到话术态并弹空编辑框
    func beginNewSnippet() {
        if mode != .snippet { setMode(.snippet) }
        editingSnippetID = nil
        editingExisting = false
        editorTitle = ""
        editorText = ""
        editorVisible = true
    }

    /// 编辑已有话术：预填内容
    func beginEditSnippet(at idx: Int) {
        guard let snippets, snippets.snippets.indices.contains(idx) else { return }
        let snippet = snippets.snippets[idx]
        editingSnippetID = snippet.id
        editingExisting = true
        editorTitle = snippet.title ?? ""
        editorText = snippet.content
        editorVisible = true
    }

    /// 取消编辑：回到话术浏览态（不关面板）
    func cancelEditor() {
        editorVisible = false
        editorTitle = ""
        editorText = ""
        editingSnippetID = nil
        editingExisting = false
    }

    /// 保存编辑：空白丢弃；保存后聚焦到最前一条
    func commitEditor() {
        guard let snippets else { return }
        let text = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelEditor(); return }
        let title = editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingSnippetID {
            snippets.update(id: id, title: title, content: text)
        } else {
            snippets.add(title: title, content: text)             // 新增插到最前
        }
        cancelEditor()
        selectedIndex = 0
        selectedSet = count > 0 ? [0] : []
        anchorIndex = 0
        keyboardScrollTick += 1
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = UInt16(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - 监听

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            // 本地监听必在主线程触发；assumeIsolated 只回传 Bool（NSEvent 非 Sendable，不能跨隔离边界返回）
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let cmd = event.modifierFlags.contains(.command)
                // 话术编辑态：键盘让给 TextEditor，仅拦 Esc 取消 / ⌘↩ 保存
                if self.editorVisible {
                    switch Int(event.keyCode) {
                    case kVK_Escape: self.cancelEditor(); return true
                    case kVK_Return where cmd, kVK_ANSI_KeypadEnter where cmd:
                        self.commitEditor(); return true
                    default: return false                          // 放行：打字 / 换行 / 光标移动
                    }
                }
                switch Int(event.keyCode) {
                case kVK_LeftArrow:  self.move(-1); return true
                case kVK_RightArrow: self.move(1);  return true
                case kVK_Tab:        self.toggleMode(); return true // Tab：历史 ↔ 话术
                case kVK_ANSI_N where cmd:
                    self.beginNewSnippet(); return true            // ⌘N：新增话术（自动切话术态）
                case kVK_ANSI_C where cmd:
                    self.copySelection(); return true              // ⌘C：复制选中（多选=合并）
                case kVK_Return, kVK_ANSI_KeypadEnter: self.confirm(); return true
                case kVK_Escape:     self.dismiss(copying: nil); return true
                default: return false
                }
            }
            return handled ? nil : event
        }
        // 点面板之外 → 收起（全局监听其他 App 的点击；本面板内点击由卡片自身处理）
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 防御：点在面板范围内不算「点外面」（任何路由边界情形都不误关）
                if let f = self.panel?.frame, f.contains(NSEvent.mouseLocation) { return }
                self.dismiss(copying: nil)
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

// MARK: - 视图

/// 选中强调色：固定粉色（不跟随系统强调色变化）
private let switcherAccent = Color(red: 0.97, green: 0.31, blue: 0.62)

private let switcherTimeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateTimeStyle = .named
    f.unitsStyle = .short
    return f
}()

struct ClipboardSwitcherView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var controller: ClipboardSwitcherController

    // 话术拖动重排态（手势自绘，见 SnippetDragContainer）
    @State private var draggingSnippetID: UUID?
    @State private var snippetDragOffset: CGSize = .zero

    private var isSnippet: Bool { controller.mode == .snippet }

    var body: some View {
        VStack(spacing: 0) {
            header
            cardStrip
        }
        .frame(width: 980, height: 368)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.92)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .overlay { if controller.editorVisible { editorOverlay } }
    }

    // MARK: 顶行：左=历史/话术切换，中=操作提示，右=话术态「+ 新增」

    private var header: some View {
        HStack(spacing: 10) {
            modeSwitch
            Spacer(minLength: 8)
            Text(isSnippet
                 ? "单击选中 · 双击粘贴 · 右键编辑/删除 · Tab切剪切板 · ⌘N新增"
                 : "单击选中 · 双击粘贴 · 右键删除 · Tab切话术 · ⌘/⇧多选 · ↩粘贴")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 8)
            Group {
                if isSnippet {
                    Button { controller.beginNewSnippet() } label: {
                        Text("+ 新增")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.95))
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Capsule().fill(switcherAccent.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .help("新增话术（⌘N）")
                }
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            segment("剪切板", active: !isSnippet) { controller.setMode(.history) }
            segment("话术", active: isSnippet) { controller.setMode(.snippet) }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func segment(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .black : .white.opacity(0.6))
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(Capsule().fill(active ? Color.white.opacity(0.92) : Color.clear))
                .contentShape(Capsule())   // 非选中段背景透明，不加这行就只有文字可点
        }
        .buttonStyle(.plain)
    }

    // MARK: 横向卡片流（历史 / 话术共用外壳）

    private var cardStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy：只构建可视区卡片。普通 HStack 会在呼出瞬间全量构建
                // 全部历史（上限 200 条，图片卡同步读盘），条目多时首帧明显卡
                LazyHStack(spacing: 12) {
                    if isSnippet {
                        ForEach(Array(snippets.snippets.enumerated()), id: \.element.id) { idx, snippet in
                            SnippetDragContainer(id: snippet.id,
                                                 controller: controller,
                                                 snippets: snippets,
                                                 dragging: $draggingSnippetID,
                                                 dragOffset: $snippetDragOffset) {
                                cardCell(idx: idx) {
                                    SnippetCard(title: snippet.title,
                                                content: snippet.content,
                                                selected: controller.selectedSet.contains(idx))
                                } menu: {
                                    Button { controller.beginEditSnippet(at: idx) } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) { controller.delete(at: idx) } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, item in
                            cardCell(idx: idx) {
                                ClipboardCard(item: item, selected: controller.selectedSet.contains(idx))
                            } menu: {
                                Button(role: .destructive) { controller.delete(at: idx) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                // 懒容器按锚点 id 缓存单元格，而两态卡片共用 0..n 当滚动锚点——
                // 不重建的话切态会命中旧缓存，话术态仍显示剪切板卡片
                .id(isSnippet)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .mask(
                // 左右两端纯黑渐隐（边缘彻底透明→露纯黑底）。与「面板宽 980 + 卡片首尾 20pt 留白」耦合：
                // 渐隐带压在约 2%（≈20pt）内、正好卡在留白边，卡片从 20pt 起紧接着出现，故默认不被遮挡；
                // 滚动时卡片进留白才淡出。曲度用 ease（靠外快、靠内缓），过渡自然不生硬。改宽度/留白需同步调这里
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.25), location: 0.006),
                    .init(color: .black.opacity(0.65), location: 0.012),
                    .init(color: .black.opacity(0.9), location: 0.016),
                    .init(color: .black, location: 0.02),
                    .init(color: .black, location: 0.98),
                    .init(color: .black.opacity(0.9), location: 0.984),
                    .init(color: .black.opacity(0.65), location: 0.988),
                    .init(color: .black.opacity(0.25), location: 0.994),
                    .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            )
            .onChange(of: controller.keyboardScrollTick) { _, _ in
                // 只有键盘 ← → 才滚动居中；鼠标点击不动卡片（点击后卡片位移会导致下一次点击落点错位）
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(controller.selectedIndex, anchor: .center) }
            }
        }
    }

    /// 卡片 + 下方「复制」按钮：卡片体与右键菜单由参数注入，交互（单击选中/双击粘贴/复制）历史话术共用
    private func cardCell<Card: View, Menu: View>(
        idx: Int,
        @ViewBuilder card: () -> Card,
        @ViewBuilder menu: () -> Menu
    ) -> some View {
        VStack(spacing: 6) {
            card()
                .onTapGesture {
                    // 单击即时选中（不用 count:2 手势，避免单击等双击判定的延迟）；
                    // 双击由 handleTap 内部按「快速二次点击同卡」检测 → 粘贴
                    guard draggingSnippetID == nil else { return }   // 刚拖完的松手不当点击
                    let mods = NSEvent.modifierFlags
                    controller.handleTap(at: idx,
                                         command: mods.contains(.command),
                                         shift: mods.contains(.shift))
                }
                .contextMenu { menu() }
            Button {
                controller.copyButtonTapped(at: idx)
            } label: {
                Text(controller.copiedFlash == idx ? "已复制 ✓" : "复制")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .padding(.horizontal, 18).padding(.vertical, 4)
                    .background(Capsule().fill(
                        controller.copiedFlash == idx ? Color.green.opacity(0.75)
                            : controller.selectedSet.contains(idx)
                                ? switcherAccent.opacity(0.55) : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .id(idx)
    }

    // MARK: 话术编辑浮层

    private var editorOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { }                               // 吞掉点击，避免穿透到底层卡片
            VStack(alignment: .leading, spacing: 12) {
                Text(controller.editingExisting ? "编辑话术" : "新增话术")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                SnippetTitleField(text: $controller.editorTitle)
                SnippetEditor(text: $controller.editorText)
                    .frame(height: 130)
                HStack(spacing: 10) {
                    Text("⌘↩ 保存 · esc 取消")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Button("取消") { controller.cancelEditor() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                    Button { controller.commitEditor() } label: {
                        Text("保存")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 16).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.editorText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

private struct ClipboardCard: View {
    @EnvironmentObject var store: ClipboardStore
    let item: ClipboardItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .clipped()                                         // 兜底裁切，任何内容都不越出卡片
            HStack(spacing: 5) {
                Image(systemName: item.kind == .image ? "photo" : "doc.text")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                Text(item.kind == .image ? "图片" : "文本")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                Spacer()
                Text(switcherTimeFormatter.localizedString(for: item.date, relativeTo: Date()))
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.3))
            }
            .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 200, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.16 : 0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? switcherAccent : Color.white.opacity(0.08),
                              lineWidth: selected ? 2 : 0.5))
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)               // 整图按比例缩进卡片：不裁切、不溢出，再宽再高都规整
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.system(size: 28)).foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .text:
            Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(11)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 话术卡拖动重排：与刘海启动器的置顶图标同一套模型——手势自绘，卡片跟手移动、
/// 其它卡实时让位（弹簧动画）、松手弹簧归位。不用系统拖放：那个只有半透明预览 +
/// 落点才生效，既不跟手也不让位，手感对不上（大梁老师点名要与图标拖动一致）。
private struct SnippetDragContainer<Content: View>: View {
    let id: UUID
    @ObservedObject var controller: ClipboardSwitcherController
    @ObservedObject var snippets: SnippetStore
    @Binding var dragging: UUID?
    @Binding var dragOffset: CGSize
    @ViewBuilder var content: Content

    @State private var startIndex = 0

    /// 相邻卡片中心间距 = 卡宽 200 + LazyHStack 间距 12（改卡片尺寸要同步这里）
    private let stride: CGFloat = 212
    private var isDragging: Bool { dragging == id }

    var body: some View {
        content
            .offset(isDragging ? dragOffset : .zero)
            .zIndex(isDragging ? 1 : 0)
            .simultaneousGesture(   // 叠在卡片既有点击/右键之上：移动超 6px 才算拖动
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        guard let current = snippets.snippets.firstIndex(where: { $0.id == id }) else { return }
                        if dragging == nil {
                            dragging = id
                            startIndex = current
                        }
                        // 目标位 = 起始位 + 累计位移格数（基于起点算，不逐帧漂移）
                        let target = min(max(startIndex + Int((value.translation.width / stride).rounded()), 0),
                                         snippets.snippets.count - 1)
                        if target != current {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                controller.moveSnippet(from: current, to: target)
                            }
                        }
                        // 视觉偏移每帧重算 = 跟手位移 − 已让位的布局位移（卡片始终贴着鼠标）
                        let nowIndex = snippets.snippets.firstIndex(where: { $0.id == id }) ?? target
                        dragOffset = CGSize(
                            width: value.translation.width - CGFloat(nowIndex - startIndex) * stride,
                            height: value.translation.height)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { dragOffset = .zero }
                        // 延后清拖动态：覆盖松手瞬间的 tap 窗口，避免拖完被当成单击
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if dragging == id { dragging = nil }
                        }
                    }
            )
    }
}

/// 话术卡片：纯文本卡，与剪贴板文本卡同款尺寸/选中态，右下角标「话术」
private struct SnippetCard: View {
    let title: String?
    let content: String
    let selected: Bool

    var body: some View {
        let hasTitle = !(title ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if hasTitle {
                Text(title ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
            }
            Text(content.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(hasTitle ? 9 : 11)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 5) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                Text("话术")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 200, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.16 : 0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? switcherAccent : Color.white.opacity(0.08),
                              lineWidth: selected ? 2 : 0.5))
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// 话术标题输入：单行、可选填。不自动聚焦（内容框保持默认焦点），点击即可编辑
private struct SnippetTitleField: View {
    @Binding var text: String

    var body: some View {
        TextField("标题（可选，便于识别）", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08)))
    }
}

/// 话术编辑输入框：出现即自动聚焦（面板已是 key window，键入由 keyMonitor 放行）
private struct SnippetEditor: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08)))
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
