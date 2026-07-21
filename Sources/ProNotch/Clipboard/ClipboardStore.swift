import AppKit
import SwiftUI
import CryptoKit

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    var text: String?
    var imageFileName: String?
    var imageHash: String?      // 图片内容指纹（去重用）；文本/旧数据为 nil
    var date: Date
}

/// 剪贴板历史数据源：轮询捕获、隐私过滤、本地持久化、回填剪贴板
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    /// 索引读写异常（损坏保全、写盘失败），文案可直接展示
    @Published private(set) var storageError: String?

    /// 索引写成功之前不能删的图片文件名。
    /// 顺序反过来的话——先删文件、索引写失败——重启后索引里还指着已被删掉的图，
    /// 那些条目就成了点不开的空壳。所以淘汰的文件先记在这里，索引落盘成功才真删；
    /// 中途失败也不丢：留到下一次成功写入时一并清理
    private var pendingImageDeletions: [String] = []
    private var indexTask: Task<Void, Never>?

    /// 保留条数上限（设置项 clipboardLimit，默认 200）
    private var maxItems: Int {
        let value = UserDefaults.standard.integer(forKey: PrefKey.clipboardLimit)
        return value > 0 ? value : 200
    }

    private var limitObserver: Any?
    private var clearObserver: Any?
    /// 单张图片超过此大小不入历史，避免磁盘膨胀
    private let maxImageBytes = 5 * 1024 * 1024
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    /// 历史目录。生产用 App Support 下的固定路径；测试注入临时目录，
    /// 免得跑一遍测试就把大梁老师真实的剪贴板历史改了
    private let directory: URL

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProNotch/Clipboard", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// 密码管理器等会给敏感/临时内容打这些标记，跳过不记录
    private static let skippedTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
    ]

    init(directory: URL = ClipboardStore.defaultDirectory) {
        self.directory = directory
        // 设置页「清空历史」走通知触发（设置窗口不持有本 store，沿用全局通知风格）；
        // 与记录开关独立：关着也能清
        clearObserver = NotificationCenter.default.addObserver(
            forName: .proNotchClipboardClearRequested,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.clear() }
        }
    }

    /// 只加载历史、不开轮询（记录开关关闭时的启动路径）：历史仍可查看、粘贴
    func loadHistoryOnly() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        loadIndex()
    }

    func startMonitoring() {
        loadHistoryOnly()
        timer?.invalidate()
        // 从「现在」起记：启动或中途重开时，开关关闭期间落在剪贴板里的内容不补录
        lastChangeCount = NSPasteboard.general.changeCount
        // 系统没有剪贴板变更通知，只能轮询 changeCount（整数比较，零负担）
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 设置里调小上限时立即裁剪
        if limitObserver == nil {
            limitObserver = NotificationCenter.default.addObserver(
                forName: .proNotchClipboardLimitChanged,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.trimAndSave() }
            }
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
        AppLog.clipboard.info("已复制回剪贴板: \(item.kind == .text ? "文本" : "图片", privacy: .public)")
    }

    /// 多选合并复制（切换器用）：选了什么就复制什么，按时间顺序全部进剪贴板。
    /// 混合内容编成「一条 RTFD 富文本（图片=内嵌附件）+ 纯文本备选」——剪贴板的多个独立对象
    /// 语义是"备选表示"，富内容 App 只挑一个（往往是图，文字被丢）；单条 RTFD 才是
    /// 混排内容的标准载体：富文本 App 粘出文字+图原顺序交错，纯文本框自动取合并文字。
    /// 全图片选择则写多图对象（图片类 App 才认）。同步 changeCount 不触发自捕获
    func copyMerged(_ selection: [ClipboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let texts = selection.compactMap { $0.kind == .text ? $0.text : nil }

        if texts.isEmpty {
            // 全是图片：多图对象写入
            let images = selection.compactMap { item -> NSImage? in
                guard let name = item.imageFileName else { return nil }
                return NSImage(contentsOf: directory.appendingPathComponent(name))
            }
            guard !images.isEmpty else { return }
            pb.writeObjects(images)
            lastChangeCount = pb.changeCount
            AppLog.clipboard.info("多选合并复制：图片 \(images.count) 张")
            return
        }

        // 文字（或文字+图片）：按时间顺序交错编入一条富文本
        let rich = NSMutableAttributedString()
        var imageCount = 0
        for (i, item) in selection.enumerated() {
            switch item.kind {
            case .text:
                rich.append(NSAttributedString(string: item.text ?? ""))
            case .image:
                guard let name = item.imageFileName,
                      let wrapper = try? FileWrapper(url: directory.appendingPathComponent(name)) else { continue }
                rich.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
                imageCount += 1
            }
            if i < selection.count - 1 { rich.append(NSAttributedString(string: "\n")) }
        }
        let item = NSPasteboardItem()
        if imageCount > 0,
           let rtfd = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            item.setData(rtfd, forType: .rtfd)   // 富文本表示：文字+图片原顺序
        }
        item.setString(texts.joined(separator: "\n"), forType: .string)   // 纯文本备选
        pb.writeObjects([item])
        lastChangeCount = pb.changeCount
        AppLog.clipboard.info("多选合并复制：文本 \(texts.count) 条 + 图片 \(imageCount) 张（RTFD）")
    }

    /// 把任意文本写入剪贴板（话术库等外部来源用），同步 changeCount 不触发自捕获
    func copyExternal(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        AppLog.clipboard.info("话术已复制到剪贴板")
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        enqueueImageDeletion(of: item)
        saveIndex()
    }

    func clear() {
        for item in items { enqueueImageDeletion(of: item) }
        items.removeAll()
        saveIndex()
    }

    #if DEBUG
    /// 仅用于生成 README 配图：载入一组演示条目，不读取也不写入真实历史
    func loadDemoItems() {
        func t(_ s: String, _ ago: TimeInterval) -> ClipboardItem {
            ClipboardItem(id: UUID(), kind: .text, text: s, imageFileName: nil,
                          date: Date().addingTimeInterval(-ago))
        }
        items = [
            t("https://github.com/DaliangPro/ProNotch", 60),
            t("struct NotchView: View {\n    var body: some View {\n        Text(\"ProNotch\")\n    }\n}", 300),
            t("把 MacBook 的刘海变成你的效率中心。", 900),
            t("Stay hungry, stay foolish.", 1800),
            t("会议纪要：下周一上线新版，重点打磨剪贴板切换器与超级截图，记得同步设计与测试。", 3600),
        ]
    }
    #endif

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
            AppLog.clipboard.info("跳过敏感/临时剪贴板内容")
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

    /// 记录一条文本（轮询捕获用）。非 private 是为了让测试能构造
    /// 「切换器面板开着时来了新剪贴板内容」这个真实场景
    func capture(text: String) {
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
        AppLog.clipboard.info("捕获文本（\(text.count) 字符）")
    }

    private func captureImage(from pb: NSPasteboard) {
        guard let data = pb.data(forType: .png) ?? tiffAsPNG(pb.data(forType: .tiff)) else {
            return
        }
        guard data.count <= maxImageBytes else {
            AppLog.clipboard.error("图片超过 5MB，不入历史")
            return
        }
        // 相同图片已存在则移到顶部，不重复记录——否则某些 App 周期性回写同一张图会堆满历史
        let hash = Self.imageHash(data)
        if let index = items.firstIndex(where: { $0.kind == .image && $0.imageHash == hash }) {
            var item = items.remove(at: index)
            item.date = Date()
            items.insert(item, at: 0)
            trimAndSave()
            return
        }
        let name = UUID().uuidString + ".png"
        do {
            try data.write(to: directory.appendingPathComponent(name))
        } catch {
            AppLog.clipboard.error("图片保存失败: \(LogRedaction.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return
        }
        items.insert(ClipboardItem(id: UUID(), kind: .image, text: nil,
                                   imageFileName: name, imageHash: hash, date: Date()), at: 0)
        trimAndSave()
        AppLog.clipboard.info("捕获图片（\(data.count / 1024) KB）")
    }

    /// 图片内容指纹（SHA256，去重用）
    private static func imageHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func tiffAsPNG(_ tiff: Data?) -> Data? {
        guard let tiff, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 维护

    private func trimAndSave() {
        while items.count > maxItems {
            enqueueImageDeletion(of: items.removeLast())
        }
        saveIndex()
    }

    /// 登记一张待删的图片文件（淘汰、删除、去重都走这里），真正删除等索引落盘成功
    private func enqueueImageDeletion(of item: ClipboardItem) {
        guard let name = item.imageFileName else { return }
        pendingImageDeletions.append(name)
    }

    /// 索引写成功后执行的清理。按**当前**索引判断引用，不按发起写入时的快照：
    /// 期间可能又有条目复用了同一张图，照旧快照删就把活数据删了
    private func flushImageDeletions() {
        let fm = FileManager.default
        let referenced = Set(items.compactMap(\.imageFileName))
        let doomed = pendingImageDeletions.filter { !referenced.contains($0) }
        pendingImageDeletions.removeAll()
        for name in doomed {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func loadIndex() {
        let loaded = AtomicFileStore.load([ClipboardItem].self, from: indexURL)
        if let error = loaded.error {
            storageError = error
            AppLog.clipboard.error("本地存档读取异常：\(error, privacy: .private)")
        }
        guard let decoded = loaded.value else { return }
        let fm = FileManager.default
        var seenImageHashes = Set<String>()
        var result: [ClipboardItem] = []
        var changed = false
        for var item in decoded {
            guard let name = item.imageFileName else { result.append(item); continue }
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { changed = true; continue }   // 文件已丢失的图片项剔除
            // 旧数据补算指纹；按指纹去重——把历史里已堆积的重复图片一次清掉
            if item.imageHash == nil, let d = try? Data(contentsOf: url) {
                item.imageHash = Self.imageHash(d); changed = true
            }
            if let h = item.imageHash {
                if seenImageHashes.contains(h) { enqueueImageDeletion(of: item); changed = true; continue }
                seenImageHashes.insert(h)
            }
            result.append(item)
        }
        items = result
        if changed { saveIndex() }   // 补过指纹 / 清过重复才回写
        AppLog.clipboard.info("加载剪贴板历史 \(self.items.count, privacy: .public) 条")
    }

    private func saveIndex() {
        let snapshot = items
        let url = indexURL
        let revision = PersistRevision.next()
        indexTask = Task { [weak self] in
            do {
                let result = try await AtomicFileStore.shared.write(snapshot, to: url, revision: revision)
                // 被更新的快照顶掉时不清理：那一轮会连着这批一起删
                guard result.didWrite else { return }
                self?.storageError = nil
                self?.flushImageDeletions()
            } catch {
                self?.storageError = "剪贴板索引落盘失败：\(error.localizedDescription)"
                AppLog.clipboard.error("剪贴板索引落盘失败: \(LogRedaction.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// 等待在途索引落盘完成（测试用）
    func waitForIndexWrite() async {
        await indexTask?.value
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
