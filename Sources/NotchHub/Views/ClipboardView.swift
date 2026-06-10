import SwiftUI

private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .short
    return formatter
}()

/// 剪贴板历史：每条带复制/删除按钮，操作后面板保持展开
struct ClipboardView: View {
    @EnvironmentObject var store: ClipboardStore

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.showingSnippets {
                SnippetListView()
            } else if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.25))
                    Text("复制的文本和图片会出现在这里")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(store.items) { item in
                            ClipboardRow(item: item)
                        }
                    }
                    .padding(.horizontal, edgeInset)
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    @EnvironmentObject var store: ClipboardStore
    @EnvironmentObject var snippetStore: SnippetStore
    let item: ClipboardItem

    @State private var hovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 8) {
            preview
            Text(previewText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(relativeFormatter.localizedString(for: item.date, relativeTo: Date()))
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.3))
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
        .contextMenu {
            if item.kind == .text, let text = item.text {
                Button("存入话术库") { snippetStore.add(content: text) }
            }
            Button("删除") { store.delete(item) }
        }
    }

    private var copyButton: some View {
        Button {
            store.copyToPasteboard(item)
            withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.3)) { justCopied = false }
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(justCopied ? .green : .white.opacity(0.6))
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .help("复制")
    }

    private var deleteButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { store.delete(item) }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .help("删除")
    }

    @ViewBuilder
    private var preview: some View {
        if item.kind == .image, let image = store.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: item.kind == .image ? "photo" : "doc.text")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 40)
        }
    }

    private var previewText: String {
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            return text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        case .image:
            if let image = store.image(for: item) {
                return "图片 \(Int(image.size.width))×\(Int(image.size.height))"
            }
            return "图片"
        }
    }
}
