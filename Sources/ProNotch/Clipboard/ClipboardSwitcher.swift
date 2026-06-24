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

    @Published var selectedIndex = 0

    private var store: ClipboardStore?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var previousApp: NSRunningApplication?

    private let panelSize = NSSize(width: 920, height: 360)

    /// 注入数据源（AppDelegate 启动时调用）
    func configure(store: ClipboardStore) { self.store = store }

    /// 快捷键入口：已显示则收起，否则唤出（toggle）
    func toggle() {
        if panel != nil { dismiss(paste: nil) } else { summon() }
    }

    // MARK: - 唤出 / 收起

    private func summon() {
        guard let store, !store.items.isEmpty else { return }
        previousApp = NSWorkspace.shared.frontmostApplication      // 记住原前台 App，用于回填焦点 + 粘贴
        selectedIndex = 0

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

    private func dismiss(paste item: ClipboardItem?) {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        if let item { performPaste(item) }                         // 先收起再粘贴，避免粘到本面板
        else { previousApp?.activate() }                           // 取消也把焦点还回去
        previousApp = nil
    }

    // MARK: - 操作

    private func move(_ delta: Int) {
        guard let count = store?.items.count, count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    /// 确认（键盘回车用当前选中；鼠标点击传入对应 index）
    func confirm(at index: Int? = nil) {
        guard let store else { return }
        let idx = index ?? selectedIndex
        guard store.items.indices.contains(idx) else { dismiss(paste: nil); return }
        dismiss(paste: store.items[idx])
    }

    // MARK: - 自动粘贴回原 App

    private func performPaste(_ item: ClipboardItem) {
        store?.copyToPasteboard(item)                              // 无论能否自动粘贴，先放进剪贴板
        previousApp?.activate()
        guard Self.ensureAccessibility() else { return }           // 无辅助功能权限：仅复制，用户手动 ⌘V
        // 等原 App 重新成为前台，再合成 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.postCommandV() }
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
            MainActor.assumeIsolated {                              // 本地监听必在主线程触发，同步处理并返回
                guard let self else { return event }
                switch Int(event.keyCode) {
                case kVK_LeftArrow:  self.move(-1); return nil
                case kVK_RightArrow: self.move(1);  return nil
                case kVK_Return, kVK_ANSI_KeypadEnter: self.confirm(); return nil
                case kVK_Escape:     self.dismiss(paste: nil); return nil
                default: return event
                }
            }
        }
        // 点面板之外 → 收起（全局监听其他 App 的点击；本面板内点击由卡片自身处理）
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss(paste: nil) }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

// MARK: - 视图

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
                Text("← → 选择   ↩ 粘贴   esc 取消")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, item in
                            ClipboardCard(item: item, selected: idx == controller.selectedIndex)
                                .id(idx)
                                .onTapGesture { controller.confirm(at: idx) }
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 18)
                }
                .onChange(of: controller.selectedIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(width: 920, height: 360)
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
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.08),
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
