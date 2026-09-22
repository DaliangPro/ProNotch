import SwiftUI

/// 剪贴板与话术：剪贴板四行，话术一行一条
struct ClipboardPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var snippets: SnippetStore

    @State private var confirmingClear = false   // 清空两步确认（3 秒不点自动还原）
    @State private var editorShown = false
    @State private var editingID: UUID?          // nil=新增，非 nil=编辑既有话术
    @State private var draftTitle = ""
    @State private var draftContent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "剪贴板与话术")

            SettingsCard {
                // 关 = 停 0.5 秒轮询（真停机）；历史保留，清空是下面那行的独立职责
                SettingsRow(title: "记录剪贴板", subtitle: "关闭后停止记录，历史保留") {
                    ThemedSwitch(isOn: $settings.clipboardEnabled)
                }
                CardDivider()
                SettingsRow(title: "保留条数") {
                    PopupMenu(label: "\(settings.clipboardLimit) 条") {
                        ForEach(SettingsStore.clipboardLimitOptions, id: \.self) { n in
                            Button("\(n) 条") { settings.clipboardLimit = n }
                        }
                    }
                }
                CardDivider()
                SettingsRow(title: "快捷键") {
                    ShortcutRecorderField(shortcut: $settings.clipboardShortcut,
                                          others: [("超级截图", settings.screenshotShortcut),
                                                   ("AI 闪问", settings.chatShortcut)])
                }
                CardDivider()
                // 连图片文件一起删、不可恢复：两步确认防误点；通过通知触发（设置窗不持有 ClipboardStore）
                SettingsRow(title: "历史记录") {
                    TextButton(title: confirmingClear ? "确认清空" : "清空…", destructive: true) {
                        if confirmingClear {
                            NotificationCenter.default.post(name: .proNotchClipboardClearRequested, object: nil)
                            confirmingClear = false
                        } else {
                            confirmingClear = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmingClear = false }
                        }
                    }
                }
            }

            SettingsSectionHeader(text: "常用话术") {
                TextButton(title: "新增") { beginAdd() }
            }
            if snippets.snippets.isEmpty {
                SettingsNote(text: "新增后在剪贴板面板按 Tab 切到话术，双击粘贴")
            } else {
                SettingsCard {
                    ForEach(Array(snippets.snippets.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { CardDivider() }
                        let preview = s.content.replacingOccurrences(of: "\n", with: " ")
                        SettingsRow(title: s.title?.isEmpty == false ? s.title! : preview,
                                    subtitle: s.title?.isEmpty == false ? preview : nil,
                                    subtitleLines: 1) {
                            HStack(spacing: 12) {
                                Button { beginEdit(s) } label: {
                                    Image(systemName: "pencil").font(.system(size: 12))
                                        .foregroundColor(SettingsTheme.textMuted)
                                }
                                .buttonStyle(.plain).help("编辑")
                                Button { snippets.delete(s) } label: {
                                    Image(systemName: "trash").font(.system(size: 12))
                                        .foregroundColor(SettingsTheme.textMuted)
                                }
                                .buttonStyle(.plain).help("删除")
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $editorShown) { editorSheet }
    }

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingID == nil ? "新增话术" : "编辑话术")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(SettingsTheme.text)
            ThemedTextField(placeholder: "标题（可选）", text: $draftTitle)
            TextEditor(text: $draftContent)
                .font(.system(size: 13)).foregroundColor(SettingsTheme.text)
                .scrollContentBackground(.hidden).padding(8).frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.bg))
            HStack(spacing: 16) {
                Spacer()
                TextButton(title: "取消") { editorShown = false }
                Button { commit() } label: {
                    Text("完成").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.accent))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .disabled(draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .background(SettingsTheme.card)
        .preferredColorScheme(.dark)
    }

    private func beginAdd() {
        editingID = nil; draftTitle = ""; draftContent = ""; editorShown = true
    }

    private func beginEdit(_ s: Snippet) {
        editingID = s.id; draftTitle = s.title ?? ""; draftContent = s.content; editorShown = true
    }

    private func commit() {
        let content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        if let id = editingID { snippets.update(id: id, title: draftTitle, content: content) }
        else { snippets.add(title: draftTitle, content: content) }
        editorShown = false
    }
}
