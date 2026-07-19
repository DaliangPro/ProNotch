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
    @EnvironmentObject var weather: WeatherStore

    enum Section: String, CaseIterable, Identifiable {
        case general = "通用"
        case screenshot = "超级截图"
        case glow = "Agent 提醒"
        case chat = "AI 闪问"
        case about = "关于"
        var id: String { rawValue }
    }

    @State private var selected: Section = .general
    @State private var claudeConnected = false
    @State private var codexConnected = false
    @State private var justSaved = false
    @State private var translateKey = ""   // 翻译独立接口的 API key 草稿（惰性从钥匙串载入）
    @State private var packRequest: [String]?          // [源语言码, 目标语言码]：置值触发系统语言包下载确认

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
            applyPendingSection()
        }
        .onChange(of: settings.pendingSection) { _, _ in applyPendingSection() }
    }

    /// 消费 SettingsStore.pendingSection：刘海等外部入口要求定位到某分区时切页并清空，
    /// 让「API 设置…」能直接落到「AI 闪问」页
    private func applyPendingSection() {
        guard let raw = settings.pendingSection, let sec = Section(rawValue: raw) else { return }
        selected = sec
        settings.pendingSection = nil
    }

    @ViewBuilder private var selectedContent: some View {
        switch selected {
        case .general:    generalContent
        case .screenshot: screenshotContent
        case .glow:       glowContent
        case .chat:       chatContent
        case .about:      aboutContent
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
                clipboardShortcutRow
            }
            if let hint = settings.loginItemHint {
                noteText(hint, color: .orange)
            }

            Text("刘海两侧功能区").font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85)).padding(.top, 4)
            SettingsCard {
                slotRow("左侧显示", selection: $settings.leftSlot)
                CardDivider()
                slotRow("右侧显示", selection: $settings.rightSlot)
            }
            Text("收起状态的刘海两侧常驻显示所选内容；两侧都关闭时，刘海恢复原始宽度。天气需要定位权限（系统设置 → 隐私与安全性 → 定位服务）。")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)

            Text("恶劣天气预警").font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85)).padding(.top, 4)
            SettingsCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text("未来 3 小时预警").font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                    Text("出现大雨、大雪、冻雨、雷暴或 6 级以上大风时，刘海弹出预警大卡，点击可看详情")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                CardDivider()
                HStack {
                    Text("预览提醒效果").font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    // 五种恶劣天气逐个可预览（大梁老师要求），走真实弹出链路；
                    // 「停止」立即收卡并还原天气标，方便反复触发看动画
                    HStack(spacing: 6) {
                        ForEach(WeatherStore.previewAlerts, id: \.label) { item in
                            Button {
                                weather.preview(item.alert)
                            } label: {
                                Text(item.label).font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.85))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            weather.dismissAlert()
                        } label: {
                            Text("停止").font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    /// 功能区内容选择行（左/右侧共用）：菜单列出全部可选组件
    private func slotRow(_ label: String, selection: Binding<NotchSlot>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            Menu {
                ForEach(NotchSlot.allCases, id: \.self) { slot in
                    Button(slot.title) { selection.wrappedValue = slot }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.title).font(.system(size: 12))
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

    private var clipboardShortcutRow: some View {
        HStack {
            Text("剪贴板快捷键").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            ShortcutRecorderField(shortcut: $settings.clipboardShortcut)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - 超级截图
    private var screenshotContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("超级截图")
            SettingsCard {
                shortcutRow
            }

            Text("翻译").font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85)).padding(.top, 4)
            SettingsCard {
                translateEngineRow
                CardDivider()
                translateLangRow
            }
            // 按引擎条件显示：系统翻译只引导下载语言包；AI 模型才展开接口配置
            if settings.translateEngine == "system" {
                SettingsCard {
                    HStack {
                        Text("语言包").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                        Spacer()
                        Menu {
                            // 列出各原文语言：点击即弹系统官方下载确认框（是否已装由系统判断，
                            // 不再预查——LanguageAvailability().status 会无限挂起，同翻译卡死根因）
                            ForEach(SettingsStore.translateLangs.filter { $0 != settings.translateTargetLang }, id: \.self) { lang in
                                Button(lang) {
                                    packRequest = [SystemTranslator.languageCode(for: lang),
                                                   SystemTranslator.languageCode(for: settings.translateTargetLang)]
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("下载语言包").font(.system(size: 12))
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
                .background(LanguagePackDownloader(request: $packRequest))
                Text("本机离线翻译，毫秒级出结果。选择截图原文的语言下载语言包（免费、一次性），系统会弹出下载确认。")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            } else {
                Text("AI 接口").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85)).padding(.top, 4)
                SettingsCard {
                    toggleRow("并行加速（长文分块同时翻译，更快）", isOn: $settings.translateParallel)
                    CardDivider()
                    toggleRow("与 AI 闪问 使用相同的 API 接口", isOn: $settings.translateUseChatAPI)
                }
                if !settings.translateUseChatAPI {
                    APIEndpointEditor(baseURL: $settings.translateBaseURL, apiKey: $translateKey,
                                      model: $settings.translateModel,
                                      urlPlaceholder: "https://api.xxx.com", modelPlaceholder: "gpt-4o-mini")
                        .onChange(of: translateKey) { _, v in settings.setTranslateAPIKey(v) }
                }

                Text("翻译提示词").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85)).padding(.top, 4)
                translatePromptEditor
            }
        }
        .onAppear { translateKey = settings.translateAPIKey() }
    }

    /// 翻译提示词编辑器：可改、可一键恢复默认；{lang} 翻译时替换成目标语言
    private var translatePromptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $settings.translatePrompt)
                .font(.system(size: 12)).foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .frame(height: 120).padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            HStack {
                Text("提示词里的 {lang} 会自动替换成上面选的目标语言。")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Button("恢复默认") { settings.translatePrompt = SettingsStore.defaultTranslatePrompt }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.cyan)
            }
        }
    }

    private var translateEngineRow: some View {
        HStack {
            Text("翻译引擎").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            Menu {
                if SystemTranslator.isSupported {
                    Button("系统翻译（快 · 本机离线）") { settings.translateEngine = "system" }
                }
                Button("AI 模型") { settings.translateEngine = "ai" }
            } label: {
                HStack(spacing: 4) {
                    Text(settings.translateEngine == "system" ? "系统翻译" : "AI 模型").font(.system(size: 12))
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

    private var translateLangRow: some View {
        HStack {
            Text("翻译成").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            Menu {
                ForEach(SettingsStore.translateLangs, id: \.self) { lang in
                    Button(lang) { settings.translateTargetLang = lang }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(settings.translateTargetLang).font(.system(size: 12))
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

    private var shortcutRow: some View {
        HStack {
            Text("截图快捷键").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            Spacer()
            ShortcutRecorderField(shortcut: $settings.screenshotShortcut)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - 光晕提醒
    private var glowContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("Agent 提醒",
                      subtitle: "Claude Code / Codex 完成任务时，屏幕四周亮起呼吸光晕提醒你。")

            // 总开关：与刘海面板的「Agent 提醒」按钮联动（同一个 glowEnabled）
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Agent 提醒")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                        Text("总开关，与刘海面板上的按钮联动")
                            .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    ThemedSwitch(isOn: $settings.glowEnabled)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }

            // 完成时提醒：勾选哪些 Agent（并排）；总开关关闭时整块禁用、灰显
            sectionLabel("完成时提醒")
            SettingsCard {
                HStack(spacing: 0) {
                    sourceRow("Claude Code", isOn: $claudeConnected, source: .claude)
                    sourceRow("Codex", isOn: $codexConnected, source: .codex)
                }
            }
            .disabled(!settings.glowEnabled)
            .opacity(settings.glowEnabled ? 1 : 0.4)

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
        // 总开关变化后（含面板联动触发）刷新勾选，反映 didSet 里的接入/移除结果
        .onChange(of: settings.glowEnabled) { _, _ in
            claudeConnected = GlowHookInstaller.isInstalled(.claude)
            codexConnected = GlowHookInstaller.isInstalled(.codex)
        }
    }

    /// 提醒来源勾选（并排、无副文字）：勾上 = 接入完成钩子，取消 = 移出；
    /// 取消后两个都没勾，总开关自动关。
    private func sourceRow(_ title: String, isOn: Binding<Bool>, source: GlowSource) -> some View {
        Button {
            let target = !isOn.wrappedValue
            // 接入/卸载失败（如未安装该 App）则回滚，不误导成「已接入」
            isOn.wrappedValue = GlowHookInstaller.setInstalled(source, target) ? target : !target
            // 勾选变化后总开关跟随「还有没有勾选」：两个都没勾就自动关
            settings.glowEnabled = claudeConnected || codexConnected
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(isOn.wrappedValue ? 0.9 : 0.35))
                Text(title).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
        .buttonStyle(.plain)
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

    // MARK: - AI 闪问（独立页：多套配置 + 每套多模型 + 联网搜索）
    private var chatContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("AI 闪问")

            SettingsCard {
                HStack {
                    Text("呼出快捷键").font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                    Spacer()
                    ShortcutRecorderField(shortcut: $settings.chatShortcut)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Text("设定后，在任意位置按下即从刘海弹出这个对话页并聚焦输入框；已停在闪问页时再按收起。")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 2)

            sectionLabel("配置（可保存多套，如 DeepSeek / Claude，点胶囊切换）")
            chatProviderBar

            SettingsCard {
                fieldRow("名称") { themedField("给这套起个名，如 DeepSeek / Claude", text: $chatStore.draftName) }
                CardDivider()
                fieldRow("API 地址") { themedField("https://api.deepseek.com", text: $chatStore.draftBaseURL) }
                CardDivider()
                fieldRow("API Key") {
                    SecureField("sk-…", text: $chatStore.draftAPIKey)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity)
                }
                CardDivider()
                fieldRow("模型") {
                    TextField("", text: $chatStore.draftModel,
                              prompt: Text(chatStore.availableModels.isEmpty ? "如 deepseek-chat，或点「获取模型」" : "选择或输入模型名")
                                  .foregroundColor(.white.opacity(0.28)))
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity)
                    if !chatStore.switcherModels.isEmpty {
                        Menu {
                            ForEach(chatStore.switcherModels, id: \.self) { m in Button(m) { chatStore.draftModel = m } }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.6))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Button { chatStore.fetchModels() } label: {
                        Group {
                            if chatStore.fetchingModels { ProgressView().controlSize(.small) }
                            else { Text("获取模型").font(.system(size: 12)) }
                        }
                        .foregroundColor(canFetchChatModels ? .white.opacity(0.85) : .white.opacity(0.35))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(canFetchChatModels ? 0.12 : 0.05)))
                    }
                    .buttonStyle(.plain).disabled(!canFetchChatModels).fixedSize()
                }
                CardDivider()
                modelStatusRow
            }
            if let fetchError = chatStore.fetchError {
                noteText(fetchError, color: .red.opacity(0.85))
            }

            sectionLabel("模型列表（右上角切换器在这些之间切换）")
            chatModelListCard

            if chatStore.providers.count > 1 {
                HStack {
                    Button { chatStore.deleteProvider(chatStore.currentProviderID) } label: {
                        Label("删除这套配置", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.red.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.leading, 2)
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

            Text("每套配置各自保存地址、Key 与多个模型；兼容 OpenAI /v1/chat/completions。联网搜索在对话输入框左侧地球图标开关。改完点「保存」生效。")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 2)
        }
    }

    /// 顶部配置切换条：各套一枚胶囊 + 末尾「＋」新增（点胶囊载入该套 URL/Key/模型）
    private var chatProviderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chatStore.providers) { p in
                    let selected = p.id == chatStore.currentProviderID
                    Button { chatStore.activateProvider(p.id) } label: {
                        Text(p.name.isEmpty ? "未命名" : p.name)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? .white : .white.opacity(0.6))
                            .lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(selected ? 0.16 : 0.06)))
                    }
                    .buttonStyle(.plain)
                }
                Button { chatStore.addProvider() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain).help("新增一套 API 配置（如 Claude）")
            }
            .padding(.vertical, 1)
        }
    }

    private var canFetchChatModels: Bool {
        !chatStore.draftBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !chatStore.draftAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !chatStore.fetchingModels
    }

    /// 这套配置的模型清单：点选设为当前模型（草稿，保存生效），手动加的可删，底部现填现加
    private var chatModelListCard: some View {
        let models = chatStore.switcherModels
        return SettingsCard {
            if models.isEmpty {
                HStack {
                    Text("还没有模型，下方可添加，或在上方点「获取模型」自动拉取")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                CardDivider()
            } else {
                ForEach(models, id: \.self) { name in
                    chatModelManageRow(name)
                    CardDivider()
                }
            }
            ChatModelAddRow { name in
                chatStore.addModelToList(name)
                chatStore.draftModel = name   // 加完顺手选为当前（草稿，保存后生效）
            }
        }
    }

    private func chatModelManageRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Button { chatStore.draftModel = name } label: {
                HStack {
                    Text(name).font(.system(size: 13)).foregroundColor(.white.opacity(0.9)).lineLimit(1)
                    Spacer()
                    if name == chatStore.draftModel {
                        Image(systemName: "checkmark").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 手动加的模型可删；从服务端拉的不删（下次「获取模型」还会回来）
            if chatStore.customModels.contains(name) {
                Button { chatStore.removeCustomModel(name) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain).help("从列表移除")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    /// 「＋ 添加模型」常显输入行：回车或点「添加」加进当前套的模型列表
    private struct ChatModelAddRow: View {
        let onAdd: (String) -> Void
        @State private var text = ""

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                TextField("", text: $text,
                          prompt: Text("输入模型名，回车添加").foregroundColor(.white.opacity(0.28)))
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .onSubmit(commit)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("添加", action: commit)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }

        private func commit() {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            onAdd(t)
            text = ""
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
/// 共享 API 接口配置编辑器（闪问 / 翻译 共用一套逻辑）：地址 + Key + 模型(下拉/获取) + 测试。
/// 网络全部走 ChatStore.fetchAvailableModels，不重复实现。
private struct APIEndpointEditor: View {
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var model: String
    var urlPlaceholder = "https://api.deepseek.com"
    var modelPlaceholder = "deepseek-chat"

    @State private var models: [String] = []
    @State private var busy = false
    @State private var status = ""
    @State private var ok: Bool?

    var body: some View {
        SettingsCard {
            row("API 地址") { field(urlPlaceholder, $baseURL) }
            CardDivider()
            row("API Key") {
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity)
            }
            CardDivider()
            row("模型") {
                field(modelPlaceholder, $model)
                if !models.isEmpty {
                    Menu { ForEach(models, id: \.self) { m in Button(m) { model = m } } } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.6))
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                pill("获取模型") { run(populate: true) }
            }
            CardDivider()
            HStack(spacing: 10) {
                Circle().fill(ok == nil ? Color.white.opacity(0.3) : (ok! ? .green : .red)).frame(width: 8, height: 8)
                Text(status.isEmpty ? "未测试" : status)
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                Spacer()
                pill("测试") { run(populate: false) }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private func run(populate: Bool) {
        guard !busy, !baseURL.isEmpty, !apiKey.isEmpty else { return }
        busy = true; status = "测试中…"; ok = nil
        let u = baseURL, k = apiKey
        Task {
            do {
                let m = try await ChatStore.fetchAvailableModels(baseURL: u, apiKey: k)
                if populate { models = m; if model.isEmpty, let f = m.first { model = f } }
                status = "连接正常 · \(m.count) 个模型"; ok = true
            } catch {
                status = "失败：\(error.localizedDescription)"; ok = false
            }
            busy = false
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13)).foregroundColor(.white.opacity(0.9)).frame(width: 76, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
    private func field(_ ph: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(ph).foregroundColor(.white.opacity(0.28)))
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity)
    }
    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small) } else { Text(title).font(.system(size: 12)) }
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain).disabled(busy || baseURL.isEmpty || apiKey.isEmpty)
    }
}

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
