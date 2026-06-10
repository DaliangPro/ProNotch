import SwiftUI

/// 毛玻璃背景（深色半透明，与刘海面板气质一致）
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 设置窗口：深色半透明风格，统一 84pt 标签列 / 13pt 字号 / 卡片分组
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
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            // 毛玻璃上压一层深色，保留通透感的同时保证文字对比度
            Color.black.opacity(0.38).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                sectionTitle("通用")
                SettingsCard {
                    toggleRow("开机自动启动", isOn: $settings.launchAtLogin)
                    CardDivider()
                    toggleRow("全屏应用时隐藏刘海", isOn: $settings.hideNotchInFullscreen)
                    CardDivider()
                    HStack {
                        Text("剪贴板历史上限")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.9))
                        Spacer()
                        Menu {
                            ForEach(SettingsStore.clipboardLimitOptions, id: \.self) { option in
                                Button("\(option) 条") { settings.clipboardLimit = option }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(settings.clipboardLimit) 条")
                                    .font(.system(size: 12))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.12)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    CardDivider()
                    fieldRow("速记收件箱") {
                        themedField("~/path/to/收件箱.md",
                                    text: $settings.captureInboxPath)
                    }
                }
                if let hint = settings.loginItemHint {
                    noteText(hint, color: .orange)
                }

                sectionTitle("AI 对话")
                SettingsCard {
                    fieldRow("API 地址") {
                        themedField("https://api.deepseek.com", text: $chatStore.draftBaseURL)
                    }
                    CardDivider()
                    fieldRow("API Key") {
                        themedSecureField("sk-…", text: $chatStore.draftAPIKey)
                    }
                    CardDivider()
                    fieldRow("模型") {
                        themedField("deepseek-chat", text: $chatStore.draftModel)
                        if !chatStore.availableModels.isEmpty {
                            Menu {
                                ForEach(chatStore.availableModels, id: \.self) { name in
                                    Button(name) { chatStore.draftModel = name }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                        Button {
                            chatStore.fetchModels()
                        } label: {
                            Group {
                                if chatStore.fetchingModels {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("获取模型").font(.system(size: 12))
                                }
                            }
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .disabled(chatStore.draftBaseURL.isEmpty
                                  || chatStore.draftAPIKey.isEmpty
                                  || chatStore.fetchingModels)
                    }
                    CardDivider()
                    fieldRow("搜索 Key") {
                        themedSecureField("选填：Tavily Key，不填用内置免费搜索",
                                          text: $chatStore.draftTavilyKey)
                    }
                }
                if let error = chatStore.fetchError {
                    noteText(error, color: .red.opacity(0.9))
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(connectivityColor)
                        .frame(width: 8, height: 8)
                    Text(connectivityText)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                    Button {
                        chatStore.checkConnectivity(force: true)
                    } label: {
                        Text("检测")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!chatStore.isConfigured)

                    Spacer()

                    if justSaved {
                        Label("已保存", systemImage: "checkmark")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                    Button {
                        chatStore.saveSettings()
                        withAnimation(.easeOut(duration: 0.15)) { justSaved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeIn(duration: 0.3)) { justSaved = false }
                        }
                    } label: {
                        Text("保存")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(canSave ? .black : .white.opacity(0.4))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(canSave ? 0.92 : 0.15)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }

                Text("兼容 OpenAI /v1/chat/completions 格式；API 地址填到域名或 /v1 即可。联网搜索在对话输入框左侧地球图标开关。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 22)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 500, height: 478)
        .preferredColorScheme(.dark)
    }

    // MARK: - 组件

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
    }

    private func noteText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(color)
            .lineLimit(2)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func fieldRow(_ label: String,
                          @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 84, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func themedField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text,
                  prompt: Text(placeholder).foregroundColor(.white.opacity(0.28)))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
    }

    private func themedSecureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField("", text: text,
                    prompt: Text(placeholder).foregroundColor(.white.opacity(0.28)))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
    }

    private var connectivityColor: Color {
        switch chatStore.connectivity {
        case .unknown: return .white.opacity(0.3)
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

/// 深色卡片：白色低透明度填充 + 细描边，与面板组件同语言
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}
