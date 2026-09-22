import SwiftUI

/// 超级截图：快捷键 + 翻译。翻译接口收成一个下拉（同闪问 / 各套翻译专用 / 新建），
/// 页上不再平铺地址和 Key；提示词进弹层
struct ScreenshotPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var chatStore: ChatStore

    @State private var endpointSheet = false
    /// 从翻译页「编辑」进弹层时闪问原本的当前套：编辑要经过 ChatStore 的当前套，关了弹层切回去
    @State private var chatProviderToRestore: UUID?
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
                    WarningRow(text: "屏幕录制未授权，截图会失败", action: "去授权") {
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
                    SettingsRow(title: "语言包", subtitle: "选截图原文的语言，系统会弹出下载确认") {
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
                    // 与闪问共用一个接口池（2026-09-22 大梁老师定）：这里列的就是闪问页那些套
                    SettingsRow(title: "接口") {
                        HStack(spacing: 12) {
                            if !settings.translateUseChatAPI {
                                TextButton(title: "编辑") { editTranslateProvider() }
                            }
                            PopupMenu(label: endpointLabel) {
                                Button("同闪问 · \(chatProviderName)") { settings.translateUseChatAPI = true }
                                Divider()
                                ForEach(chatStore.providers) { p in
                                    Button(p.name.isEmpty ? "未命名" : p.name) {
                                        settings.translateUseChatAPI = false
                                        settings.translateProviderID = p.id
                                    }
                                }
                                Divider()
                                Button("新建…") {
                                    chatProviderToRestore = chatStore.currentProviderID
                                    chatStore.addProvider()
                                    settings.translateUseChatAPI = false
                                    settings.translateProviderID = chatStore.currentProviderID
                                    endpointSheet = true
                                }
                            }
                        }
                    }
                    CardDivider()
                    SettingsRow(title: "深度思考", subtitle: "翻译短句用不上，关掉更快更省") {
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
        .sheet(isPresented: $endpointSheet, onDismiss: restoreChatProvider) { ChatEndpointSheet() }
        .sheet(isPresented: $promptSheet) { TranslatePromptSheet() }
        .onAppear { screenGranted = PermissionStatus.granted(.screenRecording) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = PermissionStatus.granted(.screenRecording)
        }
    }

    private var chatProviderName: String {
        let name = chatStore.providers.first { $0.id == chatStore.currentProviderID }?.name ?? ""
        return name.isEmpty ? "未命名" : name
    }

    private var endpointLabel: String {
        if settings.translateUseChatAPI { return "同闪问 · \(chatProviderName)" }
        guard let p = chatStore.providers.first(where: { $0.id == settings.translateProviderID }) else {
            return "同闪问 · \(chatProviderName)"   // 指定的那套已被删：实际就是跟闪问
        }
        return p.name.isEmpty ? "未命名" : p.name
    }

    /// 编辑翻译选的那套：ChatStore 只能编辑当前套，先切过去、关了弹层再切回闪问原来那套
    private func editTranslateProvider() {
        guard let id = settings.translateProviderID,
              chatStore.providers.contains(where: { $0.id == id }) else { return }
        if id != chatStore.currentProviderID {
            chatProviderToRestore = chatStore.currentProviderID
            chatStore.activateProvider(id)
        }
        endpointSheet = true
    }

    private func restoreChatProvider() {
        guard let prev = chatProviderToRestore else { return }
        chatProviderToRestore = nil
        if chatStore.providers.contains(where: { $0.id == prev }) { chatStore.activateProvider(prev) }
    }
}
