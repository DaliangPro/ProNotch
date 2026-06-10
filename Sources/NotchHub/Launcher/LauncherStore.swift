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
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 启动台数据源：扫描已安装应用、维护置顶列表、启动应用
@MainActor
final class LauncherStore: ObservableObject {
    @Published private(set) var pinned: [AppEntry] = []
    @Published private(set) var allApps: [AppEntry] = []

    /// 置顶区固定槽位数
    let maxPinned = 8

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
        print("[NotchHub] 启动应用: \(app.name)")
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
        print("[NotchHub] 应用扫描完成：全部 \(allApps.count) 个，置顶 \(pinned.count) 个")
    }

    private nonisolated static func scanApplications() -> [AppEntry] {
        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AppEntry] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") && !item.hasPrefix(".") {
                let path = dir + "/" + item
                guard seen.insert(path).inserted else { continue }
                result.append(AppEntry(url: URL(fileURLWithPath: path),
                                       name: fm.displayName(atPath: path)))
            }
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
