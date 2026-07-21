import AppKit
import SwiftUI

struct Snippet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String?     // 可选标题，便于识别；旧数据无此字段，解码为 nil
    var content: String
    var date: Date
}

/// 常用话术库：手动维护的固定文案，本地 JSON 持久化，新增在前、顺序稳定
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    /// 话术库读写异常（损坏保全、写盘失败），文案可直接展示
    @Published private(set) var storageError: String?

    /// 存档路径。生产固定在 App Support；测试注入临时文件，不碰真实话术库
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProNotch/snippets.json")
    }

    init(fileURL: URL = SnippetStore.defaultFileURL) {
        self.fileURL = fileURL
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
        let result = AtomicFileStore.load([Snippet].self, from: fileURL)
        if let error = result.error {
            storageError = error
            print("[ProNotch] \(error)")
        }
        guard let decoded = result.value else { return }
        snippets = decoded
        print("[ProNotch] 加载话术库 \(snippets.count) 条")
    }

    /// 拖拽重排会连着触发多次保存，全走 AtomicFileStore：写入串行，
    /// 且落后的快照会被 revision 判为过期丢弃，最终顺序一定是用户最后拖成的那个
    private func save() {
        let snapshot = snippets
        let url = fileURL
        let revision = PersistRevision.next()
        saveTask = Task { [weak self] in
            do {
                try await AtomicFileStore.shared.write(snapshot, to: url, revision: revision)
                self?.storageError = nil
            } catch {
                self?.storageError = "话术库落盘失败：\(error.localizedDescription)"
                print("[ProNotch] 话术库落盘失败: \(error.localizedDescription)")
            }
        }
    }

    /// 等待在途落盘完成（测试用）
    func waitForSave() async {
        await saveTask?.value
    }
}
