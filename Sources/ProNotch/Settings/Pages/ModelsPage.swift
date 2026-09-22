import SwiftUI

/// AI 模型配置：只管账号（地址、Key、模型列表）。
/// 用户脑子里没有「接口」，只有账号和模型——账号在这里配一次，每个功能在自己页上选模型。
/// 这里不放任何功能的选项，免得同一件事拆在两页互相指路（大梁老师 2026-09-22 指出）
struct ModelsPage: View {
    @EnvironmentObject var chatStore: ChatStore

    private struct EditTarget: Identifiable {
        let id: UUID
        let isNew: Bool
    }
    @State private var editing: EditTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "AI 模型配置")

            SectionLabel(text: "账号")
            // 每行四块、手工换行（不用 LazyVGrid：离屏渲染不画惰性容器，核对图上会是空白）
            let rows = tileRows()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { slot in
                        if let id = slot {
                            if let p = chatStore.providers.first(where: { $0.id == id }) {
                                SettingsTile(title: p.name.isEmpty ? "未命名" : p.name, isOn: true,
                                             action: { editing = EditTarget(id: p.id, isNew: false) }) {
                                    badge(for: p)
                                }
                            }
                        } else {
                            SettingsTile(title: "新增", isOn: false,
                                         action: { editing = EditTarget(id: chatStore.createProvider(), isNew: true) }) {
                                Image(systemName: "plus").font(.system(size: 13)).foregroundColor(SettingsTheme.textMuted)
                                    .frame(width: 18)
                            }
                        }
                    }
                    // 末行不满四块时补空位，保证每块磁贴等宽
                    ForEach(0..<(4 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
            SettingsNote(text: "点账号编辑地址、Key 与模型列表；用哪个模型在各功能页上选")
        }
        .sheet(item: $editing) { AccountSheet(providerID: $0.id, isNew: $0.isNew) }
    }

    /// 账号 id 加一个 nil 代表「新增」磁贴，按每行四块切开
    private func tileRows() -> [[UUID?]] {
        let slots: [UUID?] = chatStore.providers.map { $0.id } + [nil]
        return stride(from: 0, to: slots.count, by: 4).map { Array(slots[$0..<min($0 + 4, slots.count)]) }
    }

    private func badge(for p: APIProvider) -> some View {
        let letter = String((p.name.isEmpty ? "?" : p.name).prefix(1)).uppercased()
        return Text(letter).font(.system(size: 10, weight: .bold)).foregroundColor(SettingsTheme.text)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.white.opacity(0.12)))
    }
}
