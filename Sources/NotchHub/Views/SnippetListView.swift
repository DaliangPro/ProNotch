import SwiftUI

/// 话术库列表：编辑区（新增/修改共用）+ 话术行（复制不收起、绿色反馈）
struct SnippetListView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var snippetStore: SnippetStore

    @FocusState private var editorFocused: Bool

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snippetStore.editorVisible {
                editor
            }
            if snippetStore.snippets.isEmpty && !snippetStore.editorVisible {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.25))
                    Text("点右上「新增」录入常用话术\n或在历史条目上右键「存入话术库」")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(snippetStore.snippets) { snippet in
                            SnippetRow(snippet: snippet)
                        }
                    }
                    .padding(.horizontal, edgeInset)
                    .padding(.bottom, 14)
                }
            }
        }
        .onDisappear {
            vm.keyboardHold = false
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $snippetStore.editorText)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .frame(height: 64)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08)))
            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    snippetStore.cancelEditor()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                Button {
                    snippetStore.commitEditor()
                } label: {
                    Text(snippetStore.editingID == nil ? "保存" : "保存修改")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .disabled(snippetStore.editorText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, edgeInset)
        .onAppear { editorFocused = true }
        .onChange(of: editorFocused) { vm.keyboardHold = $0 }
    }
}

private struct SnippetRow: View {
    @EnvironmentObject var snippetStore: SnippetStore
    @EnvironmentObject var clipboardStore: ClipboardStore
    let snippet: Snippet

    @State private var hovering = false
    @State private var justCopied = false
    @State private var copyHovering = false
    @State private var deleteHovering = false

    private var preview: String {
        snippet.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 40)
            Text(preview)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            copyButton
            deleteButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(justCopied
                    ? Color.green.opacity(0.18)
                    : Color.white.opacity(hovering ? 0.12 : 0.05)))
        .onHover { hovering = $0 }
        .help(snippet.content)
        .contextMenu {
            Button("编辑") { snippetStore.beginEdit(snippet) }
            Button("删除") { snippetStore.delete(snippet) }
        }
    }

    private var copyButton: some View {
        Button {
            clipboardStore.copyExternal(text: snippet.content)
            withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.3)) { justCopied = false }
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "square.on.square")
                .font(.system(size: 11))
                .foregroundColor((justCopied || copyHovering) ? .green : .white.opacity(0.5))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { copyHovering = $0 }
        .help("复制")
    }

    private var deleteButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { snippetStore.delete(snippet) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(deleteHovering ? .red : .white.opacity(0.5))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { deleteHovering = $0 }
        .help("删除")
    }
}
