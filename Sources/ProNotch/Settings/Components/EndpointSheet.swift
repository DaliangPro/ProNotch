import SwiftUI

/// 接口编辑弹层（闪问与翻译共用同一个）：名称、地址、Key、模型列表、测试、删除。
/// 页面上只列「一行一套」，细节全在这里；「完成」即生效，没有草稿要另外保存
struct EndpointSheet: View {
    @Binding var name: String
    @Binding var baseURL: String
    @Binding var apiKey: String
    /// 可选的模型（服务端拉到的 + 手动加的）与当前模型
    let models: [String]
    let currentModel: String
    /// 手动加的模型可删；服务端拉的不删（下次获取还会回来）
    let customModels: Set<String>
    let fetching: Bool
    let statusText: String
    let statusColor: Color
    let canDelete: Bool
    let onFetch: () -> Void
    let onSelectModel: (String) -> Void
    let onAddModel: (String) -> Void
    let onRemoveModel: (String) -> Void
    let onTest: () -> Void
    let onDelete: () -> Void
    /// nil = 没有「取消」（翻译那套字段即时生效，没什么可取消的）
    let onCancel: (() -> Void)?
    let onDone: () -> Void

    @State private var newModel = ""

    private var canFetch: Bool {
        !fetching && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑接口").font(.system(size: 15, weight: .semibold)).foregroundColor(SettingsTheme.text)

            field("名称") { ThemedTextField(placeholder: "如 DeepSeek / 本地模型", text: $name) }
            field("API 地址") { ThemedTextField(placeholder: "https://api.deepseek.com", text: $baseURL) }
            field("API Key") { ThemedTextField(placeholder: "sk-…", text: $apiKey, secure: true) }

            HStack {
                Text("模型列表 · 勾选即当前").font(.system(size: 12)).foregroundColor(SettingsTheme.textSecondary)
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
                        Button { onSelectModel(m) } label: {
                            HStack {
                                Text(m).font(.system(size: 13)).foregroundColor(SettingsTheme.text).lineLimit(1)
                                Spacer()
                                if m == currentModel {
                                    Image(systemName: "checkmark").font(.system(size: 11))
                                        .foregroundColor(SettingsTheme.textSecondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                if canDelete { TextButton(title: "删除这套接口", destructive: true, action: onDelete) }
                Spacer()
                if let onCancel { TextButton(title: "取消", action: onCancel) }
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

/// 闪问接口弹层：字段绑 ChatStore 草稿，「完成」提交、「取消」回退
struct ChatEndpointSheet: View {
    @EnvironmentObject var chatStore: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EndpointSheet(
            name: $chatStore.draftName,
            baseURL: $chatStore.draftBaseURL,
            apiKey: $chatStore.draftAPIKey,
            models: chatStore.switcherModels,
            currentModel: chatStore.draftModel,
            customModels: Set(chatStore.customModels),
            fetching: chatStore.fetchingModels,
            statusText: chatStore.fetchError ?? connectivityText,
            statusColor: chatStore.fetchError == nil ? connectivityColor : SettingsTheme.danger,
            canDelete: chatStore.providers.count > 1,
            onFetch: { chatStore.fetchModels() },
            onSelectModel: { chatStore.selectModel($0) },
            onAddModel: { chatStore.addModelToList($0); chatStore.selectModel($0) },
            onRemoveModel: { chatStore.removeCustomModel($0) },
            onTest: { chatStore.saveSettings() },   // 保存即用新地址/Key 重测连通
            onDelete: { chatStore.deleteProvider(chatStore.currentProviderID); dismiss() },
            onCancel: { chatStore.revertDrafts(); dismiss() },
            onDone: { chatStore.saveSettings(); dismiss() })
    }

    private var connectivityText: String {
        switch chatStore.connectivity {
        case .unknown: return "未检测"
        case .checking: return "检测中…"
        case .ok: return "连接正常"
        case .failed(let msg): return "失败：\(msg)"
        }
    }
    private var connectivityColor: Color {
        switch chatStore.connectivity {
        case .unknown: return SettingsTheme.textMuted
        case .checking: return .yellow
        case .ok: return SettingsTheme.success
        case .failed: return SettingsTheme.danger
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
