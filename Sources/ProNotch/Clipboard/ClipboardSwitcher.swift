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

    @Published var selectedIndex = 0            // 键盘焦点（← → 移动）
    @Published var selectedSet: Set<Int> = []   // 选中集合（单击=单选，⇧单击=多选）
    @Published var copiedFlash: Int?            // 正在闪「已复制 ✓」的卡片索引
    @Published var keyboardScrollTick = 0       // 仅键盘移动时滚动居中（鼠标点击不动卡片，避免落点错位）
    private var anchorIndex = 0                 // 连选锚点（最近一次非 ⇧ 点击的位置）

    private var store: ClipboardStore?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var previousApp: NSRunningApplication?

    private let panelSize = NSSize(width: 920, height: 404)

    /// 注入数据源（AppDelegate 启动时调用）
    func configure(store: ClipboardStore) { self.store = store }

    /// 快捷键入口：已显示则收起，否则唤出（toggle）
    func toggle() {
        if panel != nil { dismiss(copying: nil) } else { summon() }
    }

    // MARK: - 唤出 / 收起

    private func summon() {
        guard let store, !store.items.isEmpty else { return }
        previousApp = NSWorkspace.shared.frontmostApplication      // 记住原前台 App，用于回填焦点 + 粘贴
        selectedIndex = 0
        selectedSet = [0]
        anchorIndex = 0

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen.map { s -> NSRect in
            NSRect(x: s.frame.midX - panelSize.width / 2,
                   y: s.frame.midY - panelSize.height / 2,
                   width: panelSize.width, height: panelSize.height)
        } ?? NSRect(origin: .zero, size: panelSize)

        let p = ClipboardSwitcherPanel(contentRect: frame, styleMask: [.borderless],
                                       backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView:
            ClipboardSwitcherView(store: store, controller: self).environmentObject(store))
        panel = p

        NSApp.activate(ignoringOtherApps: true)
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
            if thenPaste, Self.ensureAccessibility() {             // 无辅助功能权限：仅复制，用户手动 ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.postCommandV() }
            }
        } else {
            previousApp?.activate()                                // 取消也把焦点还回去
        }
        previousApp = nil
    }

    // MARK: - 选择 / 复制

    private func move(_ delta: Int) {
        guard let count = store?.items.count, count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        selectedSet = [selectedIndex]                              // 键盘移动回到单选
        anchorIndex = selectedIndex
        keyboardScrollTick += 1                                    // 只有键盘移动才滚动居中
    }

    /// 标准图标选择语义（同 Finder）：单击=单选；⌘单击=逐个加选/减选；⇧单击=锚点到当前的整段连选
    func select(at idx: Int, command: Bool, shift: Bool) {
        guard store?.items.indices.contains(idx) == true else { return }
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

    /// 回车：当前选中（单条或多条合并）粘贴回原 App
    func confirm() {
        guard let action = makeCopyAction() else { dismiss(copying: nil); return }
        dismiss(copying: action, thenPaste: true)
    }

    /// ⌘C：当前选中（单条或多条合并）复制到剪贴板并收起，不自动粘贴
    func copySelection() {
        guard let action = makeCopyAction() else { return }
        dismiss(copying: action, thenPaste: false)
    }

    /// 卡片下的「复制」按钮：该卡在多选集合里则复制整个多选，否则只复制这一条。
    /// 先原地亮「已复制 ✓」再收起——不无声关面板，用户明确知道复制发生了
    func copyButtonTapped(at idx: Int) {
        guard let store, store.items.indices.contains(idx), copiedFlash == nil else { return }
        let action: (() -> Void)?
        if selectedSet.count >= 2, selectedSet.contains(idx) {
            action = makeCopyAction()
        } else {
            let item = store.items[idx]
            action = { [weak store] in store?.copyToPasteboard(item) }
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

    private static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }

    // MARK: - 监听

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            // 本地监听必在主线程触发；assumeIsolated 只回传 Bool（NSEvent 非 Sendable，不能跨隔离边界返回）
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                switch Int(event.keyCode) {
                case kVK_LeftArrow:  self.move(-1); return true
                case kVK_RightArrow: self.move(1);  return true
                case kVK_ANSI_C where event.modifierFlags.contains(.command):
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
    @ObservedObject var controller: ClipboardSwitcherController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clipboard")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                Text("剪贴板").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Text("单击 选中 · ⌘单击 多选 · ⇧单击 连选 · ↩ 粘贴 · ⌘C 复制 · esc 取消")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, item in
                            VStack(spacing: 6) {
                                ClipboardCard(item: item, selected: controller.selectedSet.contains(idx))
                                    .onTapGesture {
                                        // 标准图标选择：单击=单选；⌘单击=逐个多选；⇧单击=连选整段
                                        let mods = NSEvent.modifierFlags
                                        controller.select(at: idx,
                                                          command: mods.contains(.command),
                                                          shift: mods.contains(.shift))
                                    }
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
                    }
                    .padding(.horizontal, 18).padding(.bottom, 16)
                }
                .onChange(of: controller.keyboardScrollTick) { _, _ in
                    // 只有键盘 ← → 才滚动居中；鼠标点击不动卡片（点击后卡片位移会导致下一次点击落点错位）
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(controller.selectedIndex, anchor: .center) }
                }
            }
        }
        .frame(width: 920, height: 404)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.92)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
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
