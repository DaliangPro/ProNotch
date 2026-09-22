import SwiftUI

/// AI 闪问：接口列成一行一套（圆点定当前、「编辑」开弹层），对话卡只剩模型与深度思考，
/// 联网搜索引擎分段选 + Key 行。页上没有「保存」按钮：点选即生效、Key 失焦即存
struct ChatPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var chatStore: ChatStore

    private var engine: SearchEngine { SearchEngine(rawValue: chatStore.draftSearchEngine) ?? .duckduckgo }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "AI 闪问")

            SettingsCard {
                SettingsRow(title: "快捷键") {
                    ShortcutRecorderField(shortcut: $settings.chatShortcut,
                                          others: [("超级截图", settings.screenshotShortcut),
                                                   ("剪贴板", settings.clipboardShortcut)])
                }
            }

            ProviderListSection(mode: .chat)

            SectionLabel(text: "对话")
            SettingsCard {
                SettingsRow(title: "模型") {
                    let models = chatStore.switcherModels
                    if models.isEmpty {
                        Text("先在接口里获取模型").font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                    } else {
                        PopupMenu(label: chatStore.draftModel.isEmpty ? "未选" : chatStore.draftModel) {
                            ForEach(models, id: \.self) { m in Button(m) { chatStore.selectModel(m) } }
                        }
                    }
                }
                CardDivider()
                SettingsRow(title: "深度思考") { ThemedSwitch(isOn: $chatStore.thinkingEnabled) }
            }

            SectionLabel(text: "联网搜索")
            SettingsCard {
                SettingsRow(title: "引擎") {
                    SegmentedPicker(options: SearchEngine.allCases, title: { shortName($0) },
                                    selection: Binding(get: { engine },
                                                       set: { chatStore.draftSearchEngine = $0.rawValue
                                                              chatStore.saveSearchSettings() }))
                }
                if engine != .duckduckgo {
                    CardDivider()
                    SettingsRow(title: "Key", subtitle: keyHint) {
                        HStack(spacing: 12) {
                            MaskedSecureField(placeholder: "粘贴 Key", text: keyBinding) {
                                chatStore.saveSearchSettings()
                            }
                            .frame(maxWidth: 220)
                            searchTestStatus
                            TextButton(title: "测试") { chatStore.saveSearchSettings(); chatStore.testSearch() }
                        }
                    }
                }
            }
        }
    }

    /// 分段控件用短名；displayName 带的「（免费）（中文强）」说明放不下一行
    private func shortName(_ e: SearchEngine) -> String {
        switch e {
        case .duckduckgo: return "DuckDuckGo"
        case .tavily: return "Tavily"
        case .brave: return "Brave"
        case .bocha: return "博查"
        }
    }

    private var keyHint: String? {
        switch engine {
        case .tavily: return "tavily.com 免费注册"
        case .brave: return "brave.com/search/api 免费注册"
        case .bocha: return "open.bochaai.com 注册领免费额度"
        case .duckduckgo: return nil
        }
    }

    private var keyBinding: Binding<String> {
        switch engine {
        case .tavily: return $chatStore.draftTavilyKey
        case .brave: return $chatStore.draftBraveKey
        case .bocha: return $chatStore.draftBochaKey
        case .duckduckgo: return .constant("")
        }
    }

    @ViewBuilder private var searchTestStatus: some View {
        switch chatStore.searchTest {
        case .unknown: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok(let n): Text("搜到 \(n) 条").font(.system(size: 12)).foregroundColor(SettingsTheme.success)
        case .failed: Text("失败").font(.system(size: 12)).foregroundColor(SettingsTheme.danger)
        }
    }
}
