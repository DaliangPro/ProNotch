import SwiftUI

/// 账号编辑弹层：名称、地址、Key、模型列表、测试、删除。
/// 账号只是可用的池子，这里不定「当前模型」——用哪个模型在 AI 模型配置页按功能选；
/// 「完成」即写入，没有草稿要另外保存
struct EndpointSheet: View {
    @Binding var name: String
    @Binding var baseURL: String
    @Binding var apiKey: String
    /// 可选的模型（服务端拉到的 + 手动加的）
    let models: [String]
    /// 手动加的模型可删；服务端拉的不删（下次获取还会回来）
    let customModels: Set<String>
    let fetching: Bool
    let statusText: String
    let statusColor: Color
    let canDelete: Bool
    let onFetch: () -> Void
    let onAddModel: (String) -> Void
    let onRemoveModel: (String) -> Void
    let onTest: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    @State private var newModel = ""

    private var canFetch: Bool {
        !fetching && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑账号").font(.system(size: 15, weight: .semibold)).foregroundColor(SettingsTheme.text)

            field("名称") { ThemedTextField(placeholder: "如 DeepSeek / 百炼", text: $name) }
            field("API 地址") { ThemedTextField(placeholder: "https://api.deepseek.com", text: $baseURL) }
            field("API Key") { ThemedTextField(placeholder: "sk-…", text: $apiKey, secure: true) }

            HStack {
                Text("模型列表").font(.system(size: 12)).foregroundColor(SettingsTheme.textSecondary)
                Spacer()
                if fetching {
                    ProgressView().controlSize(.small)
                } else {
                    TextButton(title: "获取模型", disabled: !canFetch, action: onFetch)
                }
            }
            VStack(spacing: 0) {
                ForEach(models, id: \.self) { m in
                    HStack(spacing: 8) {
                        Text(m).font(.system(size: 13)).foregroundColor(SettingsTheme.text).lineLimit(1)
                        Spacer()
                        if customModels.contains(m) {
                            Button { onRemoveModel(m) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                    .foregroundColor(SettingsTheme.textMuted)
                            }
                            .buttonStyle(.plain).help("从列表移除")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    CardDivider().padding(.leading, -2)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                    TextField("", text: $newModel,
                              prompt: Text("输入模型名，回车添加").foregroundColor(SettingsTheme.textMuted))
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(SettingsTheme.text)
                        .onSubmit(commitNewModel)
                    if !newModel.trimmingCharacters(in: .whitespaces).isEmpty {
                        TextButton(title: "添加", action: commitNewModel)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.bg))

            HStack {
                StatusLine(text: statusText, color: statusColor)
                Spacer()
                TextButton(title: "测试连接", disabled: !canFetch, action: onTest)
            }

            HStack(spacing: 16) {
                if canDelete { TextButton(title: "删除账号", destructive: true, action: onDelete) }
                Spacer()
                TextButton(title: "取消", action: onCancel)
                Button(action: onDone) {
                    Text("完成").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.accent))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20).frame(width: 460)
        .background(SettingsTheme.card)
        .preferredColorScheme(.dark)
    }

    private func commitNewModel() {
        let t = newModel.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onAddModel(t)
        newModel = ""
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundColor(SettingsTheme.textSecondary)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }
}

/// 编辑账号池里任意一个账号：字段是本地草稿，「完成」才写回 ChatStore，「取消」什么都不留。
/// 不经过 ChatStore 的「当前套」，所以编辑哪个账号都不会动闪问正在用的那套
struct AccountSheet: View {
    let providerID: UUID
    /// 新建的账号取消时若还是空壳就删掉，不留「新配置」幽灵
    var isNew = false

    @EnvironmentObject var chatStore: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var fetched: [String] = []
    @State private var custom: [String] = []
    @State private var loaded = false
    @State private var fetching = false
    @State private var status = "未测试"
    @State private var statusColor = SettingsTheme.textMuted

    private var models: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in custom + fetched where seen.insert(m).inserted { out.append(m) }
        return out
    }

    var body: some View {
        EndpointSheet(
            name: $name, baseURL: $baseURL, apiKey: $apiKey,
            models: models, customModels: Set(custom),
            fetching: fetching, statusText: status, statusColor: statusColor,
            canDelete: chatStore.providers.count > 1,
            onFetch: { run(populate: true) },
            onAddModel: { m in if !custom.contains(m), !fetched.contains(m) { custom.append(m) } },
            onRemoveModel: { m in custom.removeAll { $0 == m } },
            onTest: { run(populate: false) },
            onDelete: { chatStore.deleteProvider(providerID); dismiss() },
            onCancel: {
                if isNew, baseURL.trimmingCharacters(in: .whitespaces).isEmpty { chatStore.deleteProvider(providerID) }
                dismiss()
            },
            onDone: {
                chatStore.updateProvider(providerID, name: name, baseURL: baseURL, apiKey: apiKey,
                                         fetchedModels: fetched, customModels: custom)
                dismiss()
            })
        .onAppear(perform: load)
    }

    /// 打开时载入这套账号；Key 此刻才读钥匙串（用户点了编辑，弹授权框也说得通）
    private func load() {
        guard !loaded, let p = chatStore.providers.first(where: { $0.id == providerID }) else { return }
        loaded = true
        name = p.name
        baseURL = p.baseURL
        fetched = p.fetchedModels
        custom = p.customModels
        if !fetched.contains(p.model), !custom.contains(p.model), !p.model.isEmpty { custom.insert(p.model, at: 0) }
        apiKey = chatStore.env.readKey(p.keychainAccount)
    }

    private func run(populate: Bool) {
        guard !fetching else { return }
        fetching = true; status = "测试中…"; statusColor = .yellow
        let u = baseURL.trimmingCharacters(in: .whitespaces), k = apiKey.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let m = try await ChatStore.fetchAvailableModels(baseURL: u, apiKey: k)
                if populate { fetched = m }
                status = "连接正常 · \(m.count) 个模型"; statusColor = SettingsTheme.success
            } catch {
                status = "失败：\(error.localizedDescription)"; statusColor = SettingsTheme.danger
            }
            fetching = false
        }
    }
}

/// 翻译提示词弹层：可改、可恢复默认；{lang} 翻译时替换成目标语言
struct TranslatePromptSheet: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("翻译提示词").font(.system(size: 15, weight: .semibold)).foregroundColor(SettingsTheme.text)
            TextEditor(text: $settings.translatePrompt)
                .font(.system(size: 12)).foregroundColor(SettingsTheme.text)
                .scrollContentBackground(.hidden)
                .frame(height: 180).padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.bg))
            HStack {
                Text("{lang} 会自动替换成目标语言").font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                Spacer()
                TextButton(title: "恢复默认") { settings.translatePrompt = SettingsStore.defaultTranslatePrompt }
                Button { dismiss() } label: {
                    Text("完成").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.accent))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
        .background(SettingsTheme.card)
        .preferredColorScheme(.dark)
    }
}
