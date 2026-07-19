import AppKit
import SwiftUI
import CryptoKit

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
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

    /// 保留条数上限（设置项 clipboardLimit，默认 200）
    private var maxItems: Int {
        let value = UserDefaults.standard.integer(forKey: "clipboardLimit")
        return value > 0 ? value : 200
    }

    private var limitObserver: Any?
    private var clearObserver: Any?
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

    init() {
        // 设置页「清空历史」走通知触发（设置窗口不持有本 store，沿用全局通知风格）；
        // 与记录开关独立：关着也能清
        clearObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchClipboardClearRequested"),
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
                forName: NSNotification.Name("ProNotchClipboardLimitChanged"),
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
        print("[ProNotch] 已复制回剪贴板: \(item.kind == .text ? "文本" : "图片")")
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
            print("[ProNotch] 多选合并复制：图片 \(images.count) 张")
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
        print("[ProNotch] 多选合并复制：文本 \(texts.count) 条 + 图片 \(imageCount) 张（RTFD）")
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
            print("[ProNotch] 图片保存失败: \(error)")
            return
        }
        items.insert(ClipboardItem(id: UUID(), kind: .image, text: nil,
                                   imageFileName: name, imageHash: hash, date: Date()), at: 0)
        trimAndSave()
        print("[ProNotch] 捕获图片（\(data.count / 1024) KB）")
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
                if seenImageHashes.contains(h) { removeImageFile(of: item); changed = true; continue }
                seenImageHashes.insert(h)
            }
            result.append(item)
        }
        items = result
        if changed { saveIndex() }   // 补过指纹 / 清过重复才回写
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
