import SwiftUI

/// 超级截图：快捷键 + 翻译。翻译接口收成一个下拉（同闪问 / 各套翻译专用 / 新建），
/// 页上不再平铺地址和 Key；提示词进弹层
struct ScreenshotPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var chatStore: ChatStore

    @State private var promptSheet = false
    @State private var packRequest: [String]?          // [源语言码, 目标语言码]：置值触发系统语言包下载确认
    @State private var screenGranted = true

    private var engines: [String] { SystemTranslator.isSupported ? ["system", "ai"] : ["ai"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "超级截图")

            SettingsCard {
                SettingsRow(title: "快捷键") {
                    ShortcutRecorderField(shortcut: $settings.screenshotShortcut,
                                          others: [("剪贴板", settings.clipboardShortcut),
                                                   ("AI 闪问", settings.chatShortcut)])
                }
                if !screenGranted {
                    CardDivider()
                    WarningRow(text: "屏幕录制未授权，无法截图", action: "去授权") {
                        PermissionStatus.openSystemSettings(.screenRecording)
                    }
                }
            }

            SectionLabel(text: "翻译")
            SettingsCard {
                SettingsRow(title: "引擎") {
                    SegmentedPicker(options: engines,
                                    title: { $0 == "system" ? "系统翻译" : "AI 模型" },
                                    selection: $settings.translateEngine)
                }
                CardDivider()
                SettingsRow(title: "翻译成") {
                    PopupMenu(label: settings.translateTargetLang) {
                        ForEach(SettingsStore.translateLangs, id: \.self) { lang in
                            Button(lang) { settings.translateTargetLang = lang }
                        }
                    }
                }
                CardDivider()
                if settings.translateEngine == "system" {
                    // 本机离线翻译：按原文语言下载语言包（免费、一次性），是否已装由系统判断——
                    // 不预查，LanguageAvailability().status 会无限挂起
                    SettingsRow(title: "语言包", subtitle: "选原文语言，由系统弹窗下载") {
                        PopupMenu(label: "下载") {
                            ForEach(SettingsStore.translateLangs.filter { $0 != settings.translateTargetLang }, id: \.self) { lang in
                                Button(lang) {
                                    packRequest = [SystemTranslator.languageCode(for: lang),
                                                   SystemTranslator.languageCode(for: settings.translateTargetLang)]
                                }
                            }
                        }
                        .background(LanguagePackDownloader(request: $packRequest))
                    }
                } else {
                    // 就在这里选，按服务商分组，顶上多一项「跟随闪问」；服务商本身在「AI 模型配置」页管
                    SettingsRow(title: "模型") {
                        ModelPicker(label: modelSummary, followChat: { settings.translateUseChatAPI = true }) { p, m in
                            settings.translateUseChatAPI = false
                            settings.translateProviderID = p.id
                            settings.translateModel = m
                        }
                    }
                    CardDivider()
                    SettingsRow(title: "深度思考", subtitle: "翻译用不上，关掉更快") {
                        ThemedSwitch(isOn: $settings.translateThinking)
                    }
                    CardDivider()
                    SettingsRow(title: "并行加速") { ThemedSwitch(isOn: $settings.translateParallel) }
                    CardDivider()
                    SettingsRow(title: "提示词") {
                        HStack(spacing: 12) {
                            Text(settings.translatePrompt == SettingsStore.defaultTranslatePrompt ? "默认" : "已修改")
                                .font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                            TextButton(title: "编辑") { promptSheet = true }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $promptSheet) { TranslatePromptSheet() }
        .onAppear { screenGranted = PermissionStatus.granted(.screenRecording) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = PermissionStatus.granted(.screenRecording)
        }
    }

    private func providerName(_ id: UUID?) -> String {
        let name = chatStore.providers.first { $0.id == id }?.name ?? ""
        return name.isEmpty ? "未命名" : name
    }

    private var modelSummary: String {
        guard !settings.translateUseChatAPI,
              let p = chatStore.providers.first(where: { $0.id == settings.translateProviderID }) else {
            return "跟随闪问"
        }
        let model = settings.translateModel.isEmpty ? p.model : settings.translateModel
        return model.isEmpty ? providerName(p.id) : "\(providerName(p.id)) · \(model)"
    }
}
