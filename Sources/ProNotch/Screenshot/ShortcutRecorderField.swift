import SwiftUI
import Carbon.HIToolbox

/// 快捷键录制控件：点一下进入录制态，按下「修饰键 + 按键」即记录；Esc 取消、× 清除。
/// 录制期间用本地事件监听捕获按键（设置窗口此时是 key window，能收到 keyDown）。
struct ShortcutRecorderField: View {
    @Binding var shortcut: ScreenshotShortcut?

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "按下快捷键…" : (shortcut?.display ?? "点击设置"))
                    .font(.system(size: 12, weight: (shortcut != nil && !recording) ? .semibold : .regular))
                    .foregroundColor(recording ? .cyan : .white.opacity(0.85))
                    .frame(minWidth: 92)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(recording ? 0.16 : 0.12))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(recording ? Color.cyan.opacity(0.7) : .clear, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)

            if shortcut != nil && !recording {
                Button { shortcut = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain).help("清除快捷键")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape { stop(); return nil }   // Esc 取消录制
            if let s = ScreenshotShortcut.from(event: event) {
                shortcut = s
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
