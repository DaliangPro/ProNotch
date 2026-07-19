import AppKit
import SwiftUI

struct Snippet: Identifiable, Codable, Equatable {
    let id: UUID
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

    /// 新增话术：入库并置顶
    func add(content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        snippets.insert(Snippet(id: UUID(), content: text, date: Date()), at: 0)
        save()
        print("[ProNotch] 已存入话术库（共 \(snippets.count) 条）")
    }

    /// 纯数据更新（切换器面板自管编辑态，不经内部 editor 状态）
    func update(id: UUID, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].content = text
        save()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
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
