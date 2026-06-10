import SwiftUI

private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .short
    return formatter
}()

/// 剪贴板历史：点击条目复制回剪贴板并收起，右键删除
struct ClipboardView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: ClipboardStore

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "剪贴板历史（\(store.items.count)）")
                Spacer()
                if !store.items.isEmpty {
                    Button("清空") { store.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, edgeInset)

            if store.items.isEmpty {
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
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: ClipboardStore
    let item: ClipboardItem

    @State private var hovering = false

    var body: some View {
        Button {
            store.copyToPasteboard(item)
            vm.collapseNow()
        } label: {
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("删除") { store.delete(item) }
        }
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
