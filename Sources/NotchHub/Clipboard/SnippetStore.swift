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

    // 编辑器状态（新增与编辑共用一块输入区）
    @Published var editorVisible = false
    @Published var editorText = ""
    private(set) var editingID: UUID?

    private let fileURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("NotchHub/snippets.json")
    }()

    init() {
        load()
    }

    func beginNew() {
        editingID = nil
        editorText = ""
        editorVisible = true
    }

    func beginEdit(_ snippet: Snippet) {
        editingID = snippet.id
        editorText = snippet.content
        editorVisible = true
    }

    func cancelEditor() {
        editorVisible = false
        editorText = ""
        editingID = nil
    }

    func commitEditor() {
        let text = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = editingID,
           let index = snippets.firstIndex(where: { $0.id == id }) {
            snippets[index].content = text
        } else {
            snippets.insert(Snippet(id: UUID(), content: text, date: Date()), at: 0)
        }
        save()
        cancelEditor()
        print("[NotchHub] 话术已保存（共 \(snippets.count) 条）")
    }

    /// 从剪贴板历史等外部来源直接入库
    func add(content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        snippets.insert(Snippet(id: UUID(), content: text, date: Date()), at: 0)
        save()
        print("[NotchHub] 已存入话术库（共 \(snippets.count) 条）")
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
        print("[NotchHub] 加载话术库 \(snippets.count) 条")
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: fileURL)
        }
    }
}
