import SwiftUI

/// AI 模型配置：账号只在这里管（磁贴一排，点开编辑），每个功能各选各的模型。
/// 大梁老师 2026-09-22 定：用户脑子里没有「接口」，只有账号和模型——账号配一次，功能只选模型
struct ModelsPage: View {
    @EnvironmentObject var settings: SettingsStore
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
            SettingsNote(text: "点账号编辑地址、Key 与模型列表")

            SectionLabel(text: "用哪个模型")
            SettingsCard {
                SettingsRow(title: "AI 闪问") { chatModelMenu }
                CardDivider()
                SettingsRow(title: "截图翻译") { translateModelMenu }
            }
        }
        .sheet(item: $editing) { AccountSheet(providerID: $0.id, isNew: $0.isNew) }
    }

    // MARK: - 账号磁贴

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

    // MARK: - 用哪个模型

    private func providerName(_ id: UUID?) -> String {
        let name = chatStore.providers.first { $0.id == id }?.name ?? ""
        return name.isEmpty ? "未命名" : name
    }

    private var chatSummary: String {
        chatStore.model.isEmpty ? "未选" : "\(providerName(chatStore.currentProviderID)) · \(chatStore.model)"
    }

    private var hasAnyModel: Bool {
        chatStore.providers.contains { !ChatStore.models(of: $0).isEmpty }
    }

    /// 按账号分组的模型菜单；每个功能只是动作不同
    @ViewBuilder private func groupedModels(_ pick: @escaping (APIProvider, String) -> Void) -> some View {
        if hasAnyModel {
            ForEach(chatStore.providers) { p in
                let ms = ChatStore.models(of: p)
                if !ms.isEmpty {
                    Section(p.name.isEmpty ? "未命名" : p.name) {
                        ForEach(ms, id: \.self) { m in Button(m) { pick(p, m) } }
                    }
                }
            }
        } else {
            Text("先在账号里获取模型")
        }
    }

    private var chatModelMenu: some View {
        PopupMenu(label: chatSummary) {
            groupedModels { p, m in chatStore.useModel(providerID: p.id, model: m) }
        }
    }

    private var translateSummary: String {
        guard !settings.translateUseChatAPI,
              let p = chatStore.providers.first(where: { $0.id == settings.translateProviderID }) else {
            return "跟随闪问"
        }
        let model = settings.translateModel.isEmpty ? p.model : settings.translateModel
        return model.isEmpty ? providerName(p.id) : "\(providerName(p.id)) · \(model)"
    }

    private var translateModelMenu: some View {
        PopupMenu(label: translateSummary) {
            Button("跟随闪问") { settings.translateUseChatAPI = true }
            Divider()
            groupedModels { p, m in
                settings.translateUseChatAPI = false
                settings.translateProviderID = p.id
                settings.translateModel = m
            }
        }
    }
}
