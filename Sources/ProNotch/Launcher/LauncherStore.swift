import AppKit
import SwiftUI

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: String { url.path }
}

/// 应用图标缓存：NSWorkspace 取图标有 IconServices 缓存，这里再包一层避免重复创建 NSImage
@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let raw = NSWorkspace.shared.icon(forFile: url.path)
        let masked = squircle(raw)
        cache.setObject(masked, forKey: key)
        return masked
    }

    /// 套 macOS 启动台同款「连续圆角方形(squircle)」遮罩：满铺方形图标（抖音/爱奇艺等国产 App）
    /// 被削成圆角，和系统启动台一致；本身已内缩的圆角图标（内容在遮罩内）外观不变。
    /// macOS 26 起系统会给所有图标统一套此遮罩，而 NSWorkspace 取的是未处理的原始图标。
    private static func squircle(_ icon: NSImage, size: CGFloat = 128) -> NSImage {
        let s = NSSize(width: size, height: size)
        let out = NSImage(size: s)
        out.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            // 用 SwiftUI 连续圆角路径 → 系统级 squircle 曲率（比普通圆角矩形更贴合）
            let path = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .path(in: CGRect(origin: .zero, size: s)).cgPath
            ctx.addPath(path); ctx.clip()
        }
        icon.draw(in: NSRect(origin: .zero, size: s), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }
}

/// 启动台数据源：扫描已安装应用、维护置顶列表、启动应用
@MainActor
final class LauncherStore: ObservableObject {
    @Published private(set) var pinned: [AppEntry] = []
    @Published private(set) var allApps: [AppEntry] = []
    /// 搜索关键词（顶行搜索框与网格过滤共用，面板收起时清空）
    @Published var searchText = ""

    /// 置顶区固定槽位数
    let maxPinned = 8

    /// 按搜索关键词过滤后的应用列表（匹配本地化名称与英文文件名）
    var filteredApps: [AppEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allApps }
        return allApps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    private let pinnedKey = "topPinnedAppPaths"
    private var lastScan: Date = .distantPast

    /// 扫描应用目录（距上次扫描超过 60 秒才重扫，面板每次展开时调用无负担）
    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastScan) > 60 else { return }
        lastScan = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let apps = Self.scanApplications()
            await self?.apply(apps)
        }
    }

    func launch(_ app: AppEntry) {
        print("[ProNotch] 启动应用: \(app.name)")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config)
    }

    func isPinned(_ app: AppEntry) -> Bool {
        pinned.contains { $0.id == app.id }
    }

    func togglePin(_ app: AppEntry) {
        if isPinned(app) {
            pinned.removeAll { $0.id == app.id }
        } else {
            guard pinned.count < maxPinned else { return }
            pinned.append(app)
        }
        UserDefaults.standard.set(pinned.map(\.url.path), forKey: pinnedKey)
    }

    /// 置顶图标拖动换位（与标签 / 快捷图标同款交互），顺序持久化
    func movePinned(from: Int, to: Int) {
        guard from != to, pinned.indices.contains(from), pinned.indices.contains(to) else { return }
        pinned.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        UserDefaults.standard.set(pinned.map(\.url.path), forKey: pinnedKey)
    }

    // MARK: - 私有

    private func apply(_ apps: [AppEntry]) {
        allApps = apps
        let fm = FileManager.default
        // 按保存顺序恢复置顶列表，剔除已卸载的应用；默认留空
        let saved = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
        pinned = saved.prefix(maxPinned).compactMap { path in
            guard fm.fileExists(atPath: path) else { return nil }
            return apps.first { $0.url.path == path }
                ?? AppEntry(url: URL(fileURLWithPath: path), name: fm.displayName(atPath: path))
        }
        print("[ProNotch] 应用扫描完成：全部 \(allApps.count) 个，置顶 \(pinned.count) 个")
    }

    /// 递归扫描（最深两层子目录）：覆盖 Chrome Apps.localized 这类嵌套安装，
    /// skipsPackageDescendants 保证不进 .app 包内部（不会误收 iPad 应用的 Wrapper）
    private nonisolated static func scanApplications() -> [AppEntry] {
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AppEntry] = []
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    let path = url.path
                    if seen.insert(path).inserted {
                        result.append(AppEntry(url: url,
                                               name: fm.displayName(atPath: path)))
                    }
                } else if enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
