import SwiftUI

/// 刘海示意图：一条屏幕带，中间是刘海，两侧槽位就是下拉——用户看到的就是刘海本身的样子，
/// 左边放什么右边放什么一目了然（替代此前两行各六格的槽位选择）
struct NotchDiagram: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            slotMenu($settings.leftSlot)
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                .fill(Color.black)
                .frame(width: 150, height: 30)
            slotMenu($settings.rightSlot)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.notchStrip))
    }

    private func slotMenu(_ slot: Binding<NotchSlot>) -> some View {
        Menu {
            ForEach(NotchSlot.available(agents: settings.enabledAgents), id: \.self) { s in
                Button(s.title) { slot.wrappedValue = s }
            }
        } label: {
            (Text(slot.wrappedValue.title) + Text("  ")
                + Text(Image(systemName: "chevron.down")).font(.system(size: 9))
                    .foregroundColor(SettingsTheme.textMuted))
                .font(.system(size: 12))
                .foregroundColor(slot.wrappedValue == .none ? SettingsTheme.textMuted : SettingsTheme.text)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.12)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
