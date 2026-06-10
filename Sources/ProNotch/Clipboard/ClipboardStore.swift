import AppKit
import SwiftUI

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    var text: String?
    var imageFileName: String?
    var date: Date
}

/// 剪贴板历史数据源：轮询捕获、隐私过滤、本地持久化、回填剪贴板
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    /// 剪贴板页子视图：false=历史，true=话术库
    @Published var showingSnippets = false

    /// 保留条数上限（设置项 clipboardLimit，默认 200）
    private var maxItems: Int {
        let value = UserDefaults.standard.integer(forKey: "clipboardLimit")
        return value > 0 ? value : 200
    }

    private var limitObserver: Any?
    /// 单张图片超过此大小不入历史，避免磁盘膨胀
    private let maxImageBytes = 5 * 1024 * 1024
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProNotch/Clipboard", isDirectory: true)
    }()

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// 密码管理器等会给敏感/临时内容打这些标记，跳过不记录
    private static let skippedTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
    ]

    func startMonitoring() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        loadIndex()
        timer?.invalidate()
        // 系统没有剪贴板变更通知，只能轮询 changeCount（整数比较，零负担）
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 设置里调小上限时立即裁剪
        limitObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchClipboardLimitChanged"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.trimAndSave() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer = limitObserver {
            NotificationCenter.default.removeObserver(observer)
            limitObserver = nil
        }
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let name = item.imageFileName,
               let image = NSImage(contentsOf: directory.appendingPathComponent(name)) {
                pb.writeObjects([image])
            }
        }
        // 同步 changeCount，避免把自己的写入再捕获一遍；
        // 面板保持展开时不调整列表顺序，避免条目在用户眼前跳动
        lastChangeCount = pb.changeCount
        print("[ProNotch] 已复制回剪贴板: \(item.kind == .text ? "文本" : "图片")")
    }

    /// 把任意文本写入剪贴板（话术库等外部来源用），同步 changeCount 不触发自捕获
    func copyExternal(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        print("[ProNotch] 话术已复制到剪贴板")
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        removeImageFile(of: item)
        saveIndex()
    }

    func clear() {
        for item in items { removeImageFile(of: item) }
        items.removeAll()
        saveIndex()
    }

    func image(for item: ClipboardItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        return ThumbnailCache.image(at: directory.appendingPathComponent(name))
    }

    // MARK: - 捕获

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let types = pb.types ?? []
        guard !Self.skippedTypes.contains(where: types.contains) else {
            print("[ProNotch] 跳过敏感/临时剪贴板内容")
            return
        }

        if let urls = pb.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            // 复制文件时记录路径
            capture(text: urls.map(\.path).joined(separator: "\n"))
        } else if types.contains(.png) || types.contains(.tiff) {
            captureImage(from: pb)
        } else if let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            capture(text: text)
        }
    }

    private func capture(text: String) {
        // 相同文本已存在则移到顶部，不重复记录
        if let index = items.firstIndex(where: { $0.kind == .text && $0.text == text }) {
            var item = items.remove(at: index)
            item.date = Date()
            items.insert(item, at: 0)
        } else {
            items.insert(ClipboardItem(id: UUID(), kind: .text, text: text,
                                       imageFileName: nil, date: Date()), at: 0)
        }
        trimAndSave()
        print("[ProNotch] 捕获文本（\(text.count) 字符）")
    }

    private func captureImage(from pb: NSPasteboard) {
        guard let data = pb.data(forType: .png) ?? tiffAsPNG(pb.data(forType: .tiff)) else {
            return
        }
        guard data.count <= maxImageBytes else {
            print("[ProNotch] 图片超过 5MB，不入历史")
            return
        }
        let name = UUID().uuidString + ".png"
        do {
            try data.write(to: directory.appendingPathComponent(name))
        } catch {
            print("[ProNotch] 图片保存失败: \(error)")
            return
        }
        items.insert(ClipboardItem(id: UUID(), kind: .image, text: nil,
                                   imageFileName: name, date: Date()), at: 0)
        trimAndSave()
        print("[ProNotch] 捕获图片（\(data.count / 1024) KB）")
    }

    private func tiffAsPNG(_ tiff: Data?) -> Data? {
        guard let tiff, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 维护

    private func trimAndSave() {
        while items.count > maxItems {
            removeImageFile(of: items.removeLast())
        }
        saveIndex()
    }

    /// 历史满额淘汰时清理应用自身缓存的图片文件
    private func removeImageFile(of item: ClipboardItem) {
        guard let name = item.imageFileName else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return
        }
        let fm = FileManager.default
        items = decoded.filter { item in
            guard let name = item.imageFileName else { return true }
            return fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        print("[ProNotch] 加载剪贴板历史 \(items.count) 条")
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL)
    }
}

/// 剪贴板图片缩略图缓存（按文件路径）
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
