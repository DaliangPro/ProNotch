import SwiftUI

/// AI 模型配置：只管服务商（地址、Key、模型列表），一行一家，点「编辑」进弹层。
/// 这里不放任何功能的选项——用哪个模型在各功能页上选，免得同一件事拆在两页互相指路
///（大梁老师 2026-09-22 指出）。也不做磁贴：磁贴是「点亮即在用」的开关，服务商没有开关态，
/// 摆成一排大方块还配首字母徽记，只是占地方（同日第二次点验否掉）
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

            SettingsSectionHeader(text: "服务商") {
                TextButton(title: "新增") { editing = EditTarget(id: chatStore.createProvider(), isNew: true) }
            }
            if chatStore.providers.isEmpty {
                SettingsNote(text: "还没有服务商。新增后填地址与 Key，AI 闪问和截图翻译就能选模型")
            } else {
                SettingsCard {
                    ForEach(Array(chatStore.providers.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { CardDivider() }
                        SettingsRow(title: p.name.isEmpty ? "未命名" : p.name, subtitle: summary(of: p), subtitleLines: 1) {
                            TextButton(title: "编辑") { editing = EditTarget(id: p.id, isNew: false) }
                        }
                    }
                }
                SettingsNote(text: "用哪个模型在各功能页上选")
            }
        }
        .sheet(item: $editing) { AccountSheet(providerID: $0.id, isNew: $0.isNew) }
    }

    /// 「api.deepseek.com · 3 个模型」：一眼看出这家填没填地址、拉没拉模型
    private func summary(of p: APIProvider) -> String {
        let host = URL(string: p.baseURL)?.host ?? p.baseURL
        let count = ChatStore.models(of: p).count
        let models = count == 0 ? "还没有模型" : "\(count) 个模型"
        return host.isEmpty ? "未填地址" : "\(host) · \(models)"
    }
}
