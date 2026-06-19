import SwiftUI
import UniformTypeIdentifiers

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
    @EnvironmentObject var glow: GlowController

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

            ScrollView {
              VStack(alignment: .leading, spacing: 18) {
                sectionTitle("通用")
                SettingsCard {
                    toggleRow("开机自动启动", isOn: $settings.launchAtLogin)
                    CardDivider()
                    toggleRow("全屏时隐藏刘海", isOn: $settings.hideNotchInFullscreen)
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
                    fieldRow("妙记收件箱") {
                        themedField("~/path/to/收件箱.md",
                                    text: $settings.captureInboxPath)
                        Button("选择…") { chooseInboxFile() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.12)))
                            .help("选择 .md 文件；选择文件夹则在其中使用 妙记.md")
                    }
                }
                if let hint = settings.loginItemHint {
                    noteText(hint, color: .orange)
                }

                sectionTitle("光晕提醒")
                SettingsCard {
                    toggleRow("启用光晕提醒", isOn: $settings.glowEnabled)
                    CardDivider()
                    glowColorRow("Claude Code 颜色", binding: claudeColorBinding)
                    CardDivider()
                    glowColorRow("Codex 颜色", binding: codexColorBinding)
                    CardDivider()
                    glowSliderRow("呼吸周期", value: $settings.glowBreathPeriod, range: 1.5...6,
                                  display: String(format: "%.1f 秒", settings.glowBreathPeriod))
                    CardDivider()
                    glowSliderRow("光晕强度", value: $settings.glowIntensity, range: 0.3...1,
                                  display: "\(Int(settings.glowIntensity * 100))%")
                    CardDivider()
                    glowSliderRow("光晕厚度", value: $settings.glowThickness, range: 40...180,
                                  display: "\(Int(settings.glowThickness)) pt")
                    CardDivider()
                    glowButtonsRow
                }
                noteText("任务完成时屏幕四周亮起呼吸光晕；切回 Claude / Codex 窗口即熄灭。",
                         color: .white.opacity(0.35))

                sectionTitle("AI 闪问")
                SettingsCard {
                    fieldRow("API 地址") {
                        themedField("https://api.deepseek.com", text: $chatStore.draftBaseURL)
                    }
                    CardDivider()
                    fieldRow("API Key") {
                        MaskedSecureField(placeholder: "sk-…",
                                          text: $chatStore.draftAPIKey)
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
                        MaskedSecureField(placeholder: "选填：Tavily Key，不填用内置免费搜索",
                                          text: $chatStore.draftTavilyKey)
                    }
                    CardDivider()
                    // 连通状态与检测/保存属于 AI 配置，收进卡片内消除归属歧义
                    HStack(spacing: 10) {
                        Circle()
                            .fill(connectivityColor)
                            .frame(width: 8, height: 8)
                        Text(connectivityText)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.9))
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
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(canSave ? 0.92 : 0.15)))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                if let error = chatStore.fetchError {
                    noteText(error, color: .red.opacity(0.9))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("兼容 OpenAI /v1/chat/completions 格式；API 地址填到域名或 /v1 即可。")
                    Text("联网搜索在对话输入框左侧地球图标开关。")
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
                // 与卡片内行文字左对齐
                .padding(.leading, 14)
            }
              .padding(.horizontal, 24)
              // 顶部留白只需让出标题栏红绿灯的高度
              .padding(.top, 28)
              .padding(.bottom, 18)
            }
        }
        .frame(width: 500, height: 600)
        .preferredColorScheme(.dark)
    }

    /// 系统文件选择器：选 .md 文件直接采用；选文件夹则在其中使用 妙记.md
    private func chooseInboxFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown, .plainText]
        }
        panel.prompt = "选择"
        panel.message = "选择妙记收件箱文件（.md），或选择一个文件夹（将在其中使用 妙记.md）"
        let expanded = (settings.captureInboxPath as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: (expanded as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var path = url.path
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            path += "/妙记.md"
        }
        // 家目录前缀还原为 ~，路径更易读
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }
        settings.captureInboxPath = path
    }

    // MARK: - 组件

    // 标题与说明文字统一缩进 14pt，与卡片内行文字左对齐
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .padding(.leading, 14)
    }

    private func noteText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(color)
            .lineLimit(2)
            .padding(.leading, 14)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            ThemedSwitch(isOn: isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func fieldRow(_ label: String,
                          @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 84, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // 行级兜底裁剪：任何控件都不允许画出行边界
        .clipped()
    }

    private func themedField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text,
                  prompt: Text(placeholder).foregroundColor(.white.opacity(0.28)))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
            // 朴素样式输入框内容超长时会撑爆行宽，显式约束在可用宽度内
            .frame(maxWidth: .infinity)
    }

    /// 密钥字段：未编辑时显示固定 16 个圆点（右缘整齐、不泄露密钥长度），
    /// 点击切回真实输入框编辑
    private struct MaskedSecureField: View {
        let placeholder: String
        @Binding var text: String

        @FocusState private var focused: Bool
        @State private var editing = false

        var body: some View {
            if editing || text.isEmpty {
                SecureField("", text: $text,
                            prompt: Text(placeholder).foregroundColor(.white.opacity(0.28)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    // 长密钥的圆点串会撑爆行宽越过右边界，约束在可用宽度内
                    .frame(maxWidth: .infinity)
                    .focused($focused)
                    .onChange(of: focused) { if !$0 { editing = false } }
            } else {
                Button {
                    editing = true
                    DispatchQueue.main.async { focused = true }
                } label: {
                    Text(String(repeating: "•", count: 16))
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击修改")
            }
        }
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

    // MARK: - 光晕提醒组件

    private var claudeColorBinding: Binding<Color> {
        Binding(get: { Color(hex: settings.glowClaudeColorHex) },
                set: { settings.glowClaudeColorHex = $0.toHex() })
    }
    private var codexColorBinding: Binding<Color> {
        Binding(get: { Color(hex: settings.glowCodexColorHex) },
                set: { settings.glowCodexColorHex = $0.toHex() })
    }

    private func glowColorRow(_ title: String, binding: Binding<Color>) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func glowSliderRow(_ title: String, value: Binding<Double>,
                               range: ClosedRange<Double>, display: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                .frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small)
            Text(display).font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var glowButtonsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预览（调参用，常亮；切前台不灭）")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
            HStack(spacing: 10) {
                glowActionButton(glow.previewingSource == .claude ? "停止预览" : "预览 Claude",
                                 hex: settings.glowClaudeColorHex) { glow.togglePreview(.claude) }
                glowActionButton(glow.previewingSource == .codex ? "停止预览" : "预览 Codex",
                                 hex: settings.glowCodexColorHex) { glow.togglePreview(.codex) }
            }
            Text("测试真实提醒（模拟完成；切回对应窗口即灭）")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                .padding(.top, 2)
            HStack(spacing: 10) {
                glowActionButton(glow.testingSource == .claude ? "熄灭" : "测试 Claude 完成",
                                 hex: settings.glowClaudeColorHex) { glow.toggleTest(.claude) }
                glowActionButton(glow.testingSource == .codex ? "熄灭" : "测试 Codex 完成",
                                 hex: settings.glowCodexColorHex) { glow.toggleTest(.codex) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func glowActionButton(_ title: String, hex: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(hex: hex).opacity(settings.glowEnabled ? 0.85 : 0.3)))
        }
        .buttonStyle(.plain)
        .disabled(!settings.glowEnabled)
    }
}

/// 自绘开关：轨道恒定 38×22，开/关只变颜色与滑块位置，不变形
private struct ThemedSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor : Color.white.opacity(0.18))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
