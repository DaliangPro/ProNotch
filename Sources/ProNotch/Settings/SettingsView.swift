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

/// 设置窗口：左侧栏分类 + 右侧内容，深色半透明风格
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var chatStore: ChatStore
    @EnvironmentObject var glow: GlowController
    @EnvironmentObject var updates: UpdateChecker

    enum Section: String, CaseIterable, Identifiable {
        case general = "通用"
        case glow = "Agent 提醒"
        case chat = "AI 闪问"
        case about = "关于"
        var id: String { rawValue }
    }

    @State private var selected: Section = .general
    @State private var claudeConnected = false
    @State private var codexConnected = false
    @State private var justSaved = false

    private var canSave: Bool {
        !chatStore.draftBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !chatStore.draftAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !chatStore.draftModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            Color.black.opacity(0.38).ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                ScrollView {
                    selectedContent
                        .padding(.horizontal, 22)
                        .padding(.top, 26)
                        .padding(.bottom, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .ignoresSafeArea()   // 忽略标题栏自动安全区，留白只由下面的 26pt 决定，避免双重叠加
        }
        .frame(width: 660, height: 540)
        .preferredColorScheme(.dark)
        .onAppear {
            claudeConnected = GlowHookInstaller.isInstalled(.claude)
            codexConnected = GlowHookInstaller.isInstalled(.codex)
        }
    }

    @ViewBuilder private var selectedContent: some View {
        switch selected {
        case .general: generalContent
        case .glow:    glowContent
        case .chat:    chatContent
        case .about:   aboutContent
        }
    }

    // MARK: - 左侧栏
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Section.allCases) { sec in
                Button { selected = sec } label: {
                    HStack {
                        Text(sec.rawValue).font(.system(size: 13))
                            .foregroundColor(selected == sec ? .white : .white.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected == sec ? Color.white.opacity(0.13) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(width: 168)
        .padding(.horizontal, 10)
        .padding(.top, 40)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.025))
        .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1), alignment: .trailing)
    }

    // MARK: - 通用
    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("通用")
            SettingsCard {
                toggleRow("开机自动启动", isOn: $settings.launchAtLogin)
                CardDivider()
                toggleRow("全屏时隐藏刘海", isOn: $settings.hideNotchInFullscreen)
                CardDivider()
                clipboardLimitRow
                CardDivider()
                inboxRow
            }
            if let hint = settings.loginItemHint {
                noteText(hint, color: .orange)
            }
        }
    }

    private var clipboardLimitRow: some View {
        HStack {
            Text("剪贴板历史上限").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            Menu {
                ForEach(SettingsStore.clipboardLimitOptions, id: \.self) { option in
                    Button("\(option) 条") { settings.clipboardLimit = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(settings.clipboardLimit) 条").font(.system(size: 12))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var inboxRow: some View {
        fieldRow("妙记收件箱") {
            themedField("~/path/to/收件箱.md", text: $settings.captureInboxPath)
            Button("选择…") { chooseInboxFile() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
                .help("选择 .md 文件；选择文件夹则在其中使用 妙记.md")
        }
    }

    // MARK: - 光晕提醒
    private var glowContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("Agent 提醒",
                      subtitle: "Claude Code / Codex 完成任务时，屏幕四周亮起呼吸光晕提醒你。")

            sectionLabel("提醒来源")
            SettingsCard {
                sourceRow("Claude Code", isOn: $claudeConnected, source: .claude)
                CardDivider()
                sourceRow("Codex", isOn: $codexConnected, source: .codex)
            }
            Text("Codex 通过系统 notify 接入；若被其他工具（如 computer-use）覆盖而失效，重开上面的开关即可恢复。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            sectionLabel("外观")
            SettingsCard {
                colorRow("Claude Code 颜色", binding: claudeColorBinding, source: .claude)
                CardDivider()
                colorRow("Codex 颜色", binding: codexColorBinding, source: .codex)
                CardDivider()
                glowSliderRow("呼吸周期", value: $settings.glowBreathPeriod, range: 1.5...6,
                              display: String(format: "%.1f 秒", settings.glowBreathPeriod))
                CardDivider()
                glowSliderRow("光晕强度", value: $settings.glowIntensity, range: 0.3...1,
                              display: "\(Int(settings.glowIntensity * 100))%")
                CardDivider()
                glowSliderRow("光晕厚度", value: $settings.glowThickness, range: 40...180,
                              display: "\(Int(settings.glowThickness)) pt")
            }
        }
    }

    /// 提醒来源开关：打开 = 接入该 App 的完成钩子，关闭 = 移出
    private func sourceRow(_ title: String, isOn: Binding<Bool>, source: GlowSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                Text("完成任务时亮起光晕").font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            ThemedSwitch(isOn: Binding(
                get: { isOn.wrappedValue },
                set: { newValue in
                    // 接入/卸载失败（如未安装该 App）则回滚开关，不误导成「已接入」
                    isOn.wrappedValue = GlowHookInstaller.setInstalled(source, newValue)
                        ? newValue : !newValue
                }))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    /// 颜色行：取色器 + 文字「预览」按钮（点亮该色边调边看，再点熄灭）
    private func colorRow(_ title: String, binding: Binding<Color>, source: GlowSource) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            ColorPicker("", selection: binding, supportsOpacity: false).labelsHidden().fixedSize()
            previewButton(source)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func previewButton(_ source: GlowSource) -> some View {
        let on = glow.previewingSource == source
        return Button { glow.togglePreview(source) } label: {
            Text(on ? "停止" : "预览")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(on ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - AI 闪问（独立页：对话模型 + 联网搜索，各带测试）
    private var chatContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("AI 闪问")

            sectionLabel("对话模型")
            SettingsCard {
                fieldRow("API 地址") {
                    themedField("https://api.deepseek.com", text: $chatStore.draftBaseURL)
                }
                CardDivider()
                fieldRow("API Key") {
                    MaskedSecureField(placeholder: "sk-…", text: $chatStore.draftAPIKey)
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
                                .font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.6))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Button { chatStore.fetchModels() } label: {
                        Group {
                            if chatStore.fetchingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("获取模型").font(.system(size: 12))
                            }
                        }
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(chatStore.draftBaseURL.isEmpty || chatStore.draftAPIKey.isEmpty || chatStore.fetchingModels)
                }
                CardDivider()
                modelStatusRow
            }
            if let error = chatStore.fetchError {
                noteText(error, color: .red.opacity(0.9))
            }

            sectionLabel("联网搜索")
            SettingsCard {
                searchEngineRow
                CardDivider()
                searchKeyRow
                CardDivider()
                searchStatusRow
            }

            saveRow

            Text("对话模型兼容 OpenAI /v1/chat/completions；联网搜索在对话输入框左侧地球图标开关。改完点「保存」生效。")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 2)
        }
    }

    private var searchEngineRow: some View {
        HStack(spacing: 10) {
            Text("搜索引擎").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                .frame(width: 84, alignment: .leading)
            Menu {
                ForEach(SearchEngine.allCases, id: \.self) { eng in
                    Button(eng.displayName) { chatStore.draftSearchEngine = eng.rawValue }
                }
            } label: {
                HStack(spacing: 4) {
                    Text((SearchEngine(rawValue: chatStore.draftSearchEngine) ?? .duckduckgo).displayName)
                        .font(.system(size: 12))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var searchKeyRow: some View {
        switch SearchEngine(rawValue: chatStore.draftSearchEngine) ?? .duckduckgo {
        case .tavily:
            fieldRow("Tavily Key") {
                MaskedSecureField(placeholder: "免费注册即可获取（tavily.com）", text: $chatStore.draftTavilyKey)
            }
        case .brave:
            fieldRow("Brave Key") {
                MaskedSecureField(placeholder: "免费注册即可获取（brave.com/search/api）", text: $chatStore.draftBraveKey)
            }
        case .duckduckgo:
            fieldRow("搜索 Key") {
                Text("DuckDuckGo 免费，无需 Key")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // 对话模型卡底部：连接状态 + 检测
    private var modelStatusRow: some View {
        HStack(spacing: 10) {
            Circle().fill(connectivityColor).frame(width: 8, height: 8)
            Text(connectivityText).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
            Spacer()
            Button { chatStore.checkConnectivity(force: true) } label: {
                Text("检测").font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain).disabled(!chatStore.isConfigured)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // 联网搜索卡底部：搜索测试状态 + 测试
    private var searchStatusRow: some View {
        HStack(spacing: 10) {
            Circle().fill(searchTestColor).frame(width: 8, height: 8)
            Text(searchTestText).font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Button { chatStore.testSearch() } label: {
                Group {
                    if case .testing = chatStore.searchTest {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("测试").font(.system(size: 12))
                    }
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var searchTestColor: Color {
        switch chatStore.searchTest {
        case .unknown: return .white.opacity(0.3)
        case .testing: return .yellow
        case .ok:      return .green
        case .failed:  return .red
        }
    }
    private var searchTestText: String {
        switch chatStore.searchTest {
        case .unknown:         return "未测试"
        case .testing:         return "测试中…"
        case .ok(let n):       return "搜到 \(n) 条"
        case .failed(let msg): return "失败：\(msg)"
        }
    }

    // 底部统一保存
    private var saveRow: some View {
        HStack(spacing: 10) {
            Spacer()
            if justSaved {
                Label("已保存", systemImage: "checkmark")
                    .font(.system(size: 12)).foregroundColor(.green).transition(.opacity)
            }
            Button {
                chatStore.saveSettings()
                withAnimation(.easeOut(duration: 0.15)) { justSaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeIn(duration: 0.3)) { justSaved = false }
                }
            } label: {
                Text("保存").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(canSave ? .black : .white.opacity(0.4))
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(canSave ? 0.92 : 0.15)))
            }
            .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!canSave)
        }
        .padding(.top, 2)
    }

    // MARK: - 关于
    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("关于")
            SettingsCard {
                HStack {
                    Text("ProNotch").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Text("版本 \(updates.currentVersion)").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                CardDivider()
                updateRow
                CardDivider()
                HStack {
                    Text("项目主页").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Link("github.com/DaliangPro/ProNotch",
                         destination: URL(string: "https://github.com/DaliangPro/ProNotch")!)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
            Text("把 MacBook 的刘海变成你的效率中心。")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.35)).padding(.leading, 2)
        }
    }

    private var updateRow: some View {
        HStack(spacing: 10) {
            Text("软件更新").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            if updates.checking {
                Text("检查中…").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
            } else if let release = updates.available {
                Link("发现 \(release.version)，前往下载", destination: release.url).font(.system(size: 12))
            } else if updates.checkedUpToDate {
                Text("已是最新").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
            } else if updates.lastError != nil {
                Text("检查失败").font(.system(size: 12)).foregroundColor(.red.opacity(0.8))
            }
            Button { updates.check() } label: {
                Text("检查更新").font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain).disabled(updates.checking)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
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
        if isDirectory.boolValue { path += "/妙记.md" }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        settings.captureInboxPath = path
    }

    // MARK: - 组件

    private func pageTitle(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.5)).padding(.leading, 2)
    }

    private func noteText(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(color).lineLimit(2).padding(.leading, 2)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            ThemedSwitch(isOn: isOn)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func fieldRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                .frame(width: 84, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 9).clipped()
    }

    private func themedField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.28)))
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
            .frame(maxWidth: .infinity)
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

    private var claudeColorBinding: Binding<Color> {
        Binding(get: { Color(hex: settings.glowClaudeColorHex) },
                set: { settings.glowClaudeColorHex = $0.toHex() })
    }
    private var codexColorBinding: Binding<Color> {
        Binding(get: { Color(hex: settings.glowCodexColorHex) },
                set: { settings.glowCodexColorHex = $0.toHex() })
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

    /// 密钥字段：未编辑时显示固定 16 个圆点，点击切回真实输入框编辑
    private struct MaskedSecureField: View {
        let placeholder: String
        @Binding var text: String
        @FocusState private var focused: Bool
        @State private var editing = false

        var body: some View {
            if editing || text.isEmpty {
                SecureField("", text: $text,
                            prompt: Text(placeholder).foregroundColor(.white.opacity(0.28)))
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .focused($focused)
                    .onChange(of: focused) { _, newValue in if !newValue { editing = false } }
            } else {
                Button {
                    editing = true
                    DispatchQueue.main.async { focused = true }
                } label: {
                    Text(String(repeating: "•", count: 16))
                        .font(.system(size: 13)).foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("点击修改")
            }
        }
    }
}

/// 自绘开关：轨道恒定 38×22，开/关只变颜色与滑块位置
private struct ThemedSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.accentColor : Color.white.opacity(0.18))
                    .frame(width: 38, height: 22)
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 深色卡片：白色低透明度填充 + 细描边
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 14)
    }
}
