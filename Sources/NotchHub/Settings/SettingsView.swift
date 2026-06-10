import SwiftUI

/// 设置窗口内容：macOS 原生分组表单风格（自动适配深浅色与系统排版）
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var chatStore: ChatStore

    @State private var justSaved = false

    private var canSave: Bool {
        !chatStore.draftBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !chatStore.draftAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !chatStore.draftModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
                if let hint = settings.loginItemHint {
                    Label(hint, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Toggle("全屏应用时隐藏刘海", isOn: $settings.hideNotchInFullscreen)
            }

            Section {
                TextField("API 地址", text: $chatStore.draftBaseURL,
                          prompt: Text("https://api.deepseek.com"))
                SecureField("API Key", text: $chatStore.draftAPIKey,
                            prompt: Text("sk-…"))
                HStack(spacing: 8) {
                    TextField("模型", text: $chatStore.draftModel,
                              prompt: Text("deepseek-chat"))
                    if !chatStore.availableModels.isEmpty {
                        // 设置窗口是标准窗口，系统菜单定位正常，可放心用原生 Menu
                        Menu {
                            ForEach(chatStore.availableModels, id: \.self) { name in
                                Button(name) { chatStore.draftModel = name }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("从已获取的 \(chatStore.availableModels.count) 个模型中选择")
                    }
                    Button {
                        chatStore.fetchModels()
                    } label: {
                        if chatStore.fetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("获取模型")
                        }
                    }
                    .disabled(chatStore.draftBaseURL.isEmpty
                              || chatStore.draftAPIKey.isEmpty
                              || chatStore.fetchingModels)
                }
                SecureField("搜索 Key（选填）", text: $chatStore.draftTavilyKey,
                            prompt: Text("Tavily Key，不填则用内置免费搜索"))

                if let error = chatStore.fetchError {
                    Label(error, systemImage: "xmark.octagon")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                HStack {
                    connectivityStatus
                    Spacer()
                    if justSaved {
                        Label("已保存", systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Button("保存") {
                        chatStore.saveSettings()
                        withAnimation { justSaved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { justSaved = false }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            } header: {
                Text("AI 对话")
            } footer: {
                Text("兼容 OpenAI /v1/chat/completions 格式；API 地址填到域名或 /v1 即可。联网搜索可在对话输入框左侧地球图标开关。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }

    /// 连通状态行：彩色圆点 + 文案 + 重测按钮
    private var connectivityStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectivityColor)
                .frame(width: 8, height: 8)
            Text(connectivityText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("检测") { chatStore.checkConnectivity(force: true) }
                .controlSize(.small)
                .disabled(!chatStore.isConfigured)
        }
    }

    private var connectivityColor: Color {
        switch chatStore.connectivity {
        case .unknown: return .gray
        case .checking: return .yellow
        case .ok: return .green
        case .failed: return .red
        }
    }

    private var connectivityText: String {
        switch chatStore.connectivity {
        case .unknown: return "未检测"
        case .checking: return "检测中…"
        case .ok: return "连接正常"
        case .failed: return "连接失败"
        }
    }
}
