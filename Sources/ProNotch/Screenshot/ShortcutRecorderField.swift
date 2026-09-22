import SwiftUI
import Carbon.HIToolbox

/// 快捷键录制控件：点一下进入录制态，按下「修饰键 + 按键」即记录；Esc 取消、× 清除。
/// 录制期间用本地事件监听捕获按键（设置窗口此时是 key window，能收到 keyDown）。
///
/// 冲突检测：三个快捷键分在三页，此前同一组合能被两处录下、谁先注册谁生效，
/// 另一处静默失灵。现在录到与 `others` 里相同的组合就拒绝并在框下提示「已被 XX 使用」
struct ShortcutRecorderField: View {
    @Binding var shortcut: ScreenshotShortcut?
    /// 其他功能已占用的快捷键（功能名，快捷键）
    var others: [(name: String, shortcut: ScreenshotShortcut?)] = []

    @State private var recording = false
    @State private var monitor: Any?
    @State private var conflict: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "按下快捷键…" : (shortcut?.display ?? "点击设置"))
                        .font(.system(size: 12, weight: (shortcut != nil && !recording) ? .semibold : .regular))
                        .foregroundColor(recording ? SettingsTheme.accent : SettingsTheme.text)
                        .frame(minWidth: 92)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(recording ? SettingsTheme.accent.opacity(0.8) : Color.white.opacity(0.2),
                                              lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if shortcut != nil && !recording {
                    Button { shortcut = nil; conflict = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13)).foregroundColor(SettingsTheme.textMuted)
                    }
                    .buttonStyle(.plain).help("清除快捷键")
                }
            }
            if let conflict {
                Text("已被\(conflict)使用").font(.system(size: 11)).foregroundColor(SettingsTheme.danger)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        conflict = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape { stop(); return nil }   // Esc 取消录制
            if let s = ScreenshotShortcut.from(event: event) {
                if let taken = others.first(where: { $0.shortcut == s })?.name {
                    conflict = taken   // 不写入：保持原快捷键，让用户换一个
                } else {
                    shortcut = s
                }
                stop()
            }
            return nil   // 录制期间一律消费，避免组合键触发设置窗口里的其他响应
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
