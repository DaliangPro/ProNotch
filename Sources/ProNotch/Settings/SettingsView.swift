import SwiftUI

/// 设置窗壳：侧栏 + 当前分区的页面。六页各自独立（Pages/），
/// 共用的设计语言组件在 Components/，配色在 SettingsTheme
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var selected: SettingsSection

    /// 离屏核查（-snapshotSettings）用：固定窗高逐页渲染；nil = 跟随真实窗口，可缩放
    private let snapshotHeight: CGFloat?

    init(initialSection: SettingsSection = .general, windowHeight: CGFloat? = nil) {
        _selected = State(initialValue: initialSection)
        snapshotHeight = windowHeight
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                selectedContent
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 26)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SettingsTheme.bg)
        .ignoresSafeArea()   // 标题栏透明：留白只由上面的 26pt 决定，避免双重叠加
        .modifier(SizeModifier(snapshotHeight: snapshotHeight))
        .preferredColorScheme(.dark)
        .onAppear(perform: applyPendingSection)
        .onChange(of: settings.pendingSection) { _, _ in applyPendingSection() }
    }

    /// 消费 SettingsStore.pendingSection：刘海等外部入口要求定位到某分区时切页并清空
    private func applyPendingSection() {
        guard let raw = settings.pendingSection, let sec = SettingsSection(rawValue: raw) else { return }
        selected = sec
        settings.pendingSection = nil
    }

    @ViewBuilder private var selectedContent: some View {
        switch selected {
        case .general:    GeneralPage()
        case .notch:      NotchPage()
        case .screenshot: ScreenshotPage()
        case .clipboard:  ClipboardPage()
        case .chat:       ChatPage()
        case .agent:      AgentPage()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsSection.allCases) { sec in
                let on = selected == sec
                Button { selected = sec } label: {
                    HStack(spacing: 9) {
                        Image(systemName: sec.icon).font(.system(size: 13)).frame(width: 16)
                        Text(sec.rawValue).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                    }
                    .foregroundColor(on ? SettingsTheme.text : SettingsTheme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? SettingsTheme.sidebarSelected : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)   // 给透明标题栏上的红黄绿按钮让位
        .padding(.bottom, 14)
        .frame(width: 176)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.sidebar)
        .overlay(Rectangle().fill(SettingsTheme.divider).frame(width: 1), alignment: .trailing)
    }

    /// 真实窗口：给最小与理想尺寸，窗口可缩放；离屏快照：固定尺寸
    private struct SizeModifier: ViewModifier {
        let snapshotHeight: CGFloat?
        func body(content: Content) -> some View {
            if let h = snapshotHeight {
                content.frame(width: 700, height: h)
            } else {
                content.frame(minWidth: 660, idealWidth: 700, maxWidth: .infinity,
                              minHeight: 540, idealHeight: 620, maxHeight: .infinity)
            }
        }
    }
}
