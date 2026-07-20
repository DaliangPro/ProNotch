import AppKit
import SwiftUI

struct Snippet: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String?     // 可选标题，便于识别；旧数据无此字段，解码为 nil
    var content: String
    var date: Date
}

/// 常用话术库：手动维护的固定文案，本地 JSON 持久化，新增在前、顺序稳定
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProNotch/snippets.json")
    }()

    init() {
        load()
    }

    /// 标题归一：去空白，空串存 nil（列表判空口径统一）
    private static func normalize(_ title: String?) -> String? {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// 新增话术：入库并置顶
    func add(title: String?, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        snippets.insert(Snippet(id: UUID(), title: Self.normalize(title), content: text, date: Date()), at: 0)
        save()
        print("[ProNotch] 已存入话术库（共 \(snippets.count) 条）")
    }

    /// 纯数据更新（切换器面板自管编辑态，不经内部 editor 状态）
    func update(id: UUID, title: String?, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].title = Self.normalize(title)
        snippets[index].content = text
        save()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    /// 拖拽重排：把 from 处的话术移到 to 处。顺序即用户手排的优先级，立即落盘
    func move(from: Int, to: Int) {
        guard snippets.indices.contains(from), snippets.indices.contains(to), from != to else { return }
        let item = snippets.remove(at: from)
        snippets.insert(item, at: to)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return
        }
        snippets = decoded
        print("[ProNotch] 加载话术库 \(snippets.count) 条")
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: fileURL)
        }
    }
}
