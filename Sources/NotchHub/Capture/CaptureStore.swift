import AppKit
import SwiftUI

struct CaptureEntry: Identifiable, Equatable {
    let id = UUID()
    let time: String
    let content: String
    /// 文件中的原始行块，用于精确删除
    let rawBlock: String
}

/// 妙记：直接追加写入 Obsidian vault 的收件箱文件（按天分节、带时间戳）。
/// 不唤起 Obsidian、不打断当前工作；Obsidian 监听文件变化会实时刷新
@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var todayEntries: [CaptureEntry] = []
    @Published private(set) var lastError: String?
    /// 输入草稿放 Store，面板收起重开不丢失
    @Published var draft = ""

    private static let defaultPath = "~/Documents/OrbitOS Vault/00_收件箱/妙记.md"
    /// 功能历次更名留下的旧默认路径（速记 → 闪记 → 妙记）
    private static let legacyDefaultPaths = [
        "~/Documents/OrbitOS Vault/00_收件箱/闪记.md",
        "~/Documents/OrbitOS Vault/00_收件箱/速记.md",
    ]

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var inboxPath: String {
        UserDefaults.standard.string(forKey: "captureInboxPath") ?? Self.defaultPath
    }

    var inboxFileURL: URL {
        URL(fileURLWithPath: (inboxPath as NSString).expandingTildeInPath)
    }

    var inboxFileName: String {
        inboxFileURL.lastPathComponent
    }

    init() {
        UserDefaults.standard.register(defaults: ["captureInboxPath": Self.defaultPath])
        migrateLegacyFileIfNeeded()
        refresh()
    }

    /// 功能更名（速记 → 闪记 → 妙记）：默认收件箱文件随之改名，
    /// 老文件存在则原地重命名；用户自定义路径不受影响
    private func migrateLegacyFileIfNeeded() {
        if Self.legacyDefaultPaths.contains(inboxPath) {
            UserDefaults.standard.set(Self.defaultPath, forKey: "captureInboxPath")
        }
        guard inboxPath == Self.defaultPath else { return }
        let fm = FileManager.default
        let newPath = (Self.defaultPath as NSString).expandingTildeInPath
        guard !fm.fileExists(atPath: newPath) else { return }
        for legacy in Self.legacyDefaultPaths {
            let oldPath = (legacy as NSString).expandingTildeInPath
            if fm.fileExists(atPath: oldPath) {
                try? fm.moveItem(atPath: oldPath, toPath: newPath)
                print("[NotchHub] 收件箱文件已更名: \((oldPath as NSString).lastPathComponent) → 妙记.md")
                return
            }
        }
    }

    /// 打开收件箱：优先用 Obsidian 定位该笔记，无 Obsidian 时回退系统默认应用；
    /// 文件尚未创建时先建空文件
    func openInbox() {
        let url = inboxFileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else {
                lastError = "目录不存在：\(url.deletingLastPathComponent().path)"
                return
            }
            fm.createFile(atPath: url.path, contents: Data())
        }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if let obsidianURL = components.url, NSWorkspace.shared.open(obsidianURL) {
            print("[NotchHub] 已在 Obsidian 中打开收件箱")
        } else {
            NSWorkspace.shared.open(url)
            print("[NotchHub] 已用默认应用打开收件箱")
        }
    }

    /// 追加一条妙记，返回是否成功
    @discardableResult
    func capture(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let path = inboxFileURL.path
        let parent = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent) else {
            lastError = "目录不存在：\(parent)"
            print("[NotchHub] 妙记失败：目录不存在 \(parent)")
            return false
        }

        var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let heading = "## \(Self.dayFormatter.string(from: Date()))"

        if !content.isEmpty && !content.hasSuffix("\n") {
            content += "\n"
        }
        // 当日小节不存在则补一个（本文件为追加式，当日小节总在末尾）
        if !content.components(separatedBy: "\n").contains(heading) {
            if !content.isEmpty { content += "\n" }
            content += heading + "\n"
        }

        // 多行内容：首行跟在时间后，后续行缩进两格作列表续行
        let lines = trimmed.components(separatedBy: "\n")
        var block = "- \(Self.timeFormatter.string(from: Date())) \(lines[0])"
        for extra in lines.dropFirst() {
            block += "\n  \(extra)"
        }
        content += block + "\n"

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            lastError = "写入失败：\(error.localizedDescription)"
            print("[NotchHub] 妙记写入失败: \(error.localizedDescription)")
            return false
        }
        lastError = nil
        refresh()
        print("[NotchHub] 妙记已存入 \(inboxFileName)（今天共 \(todayEntries.count) 条）")
        return true
    }

    func delete(_ entry: CaptureEntry) {
        let path = inboxFileURL.path
        guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        if let range = content.range(of: entry.rawBlock + "\n")
            ?? content.range(of: entry.rawBlock) {
            content.removeSubrange(range)
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
            refresh()
        }
    }

    /// 从文件解析「今天」小节的条目（最新在前）
    func refresh() {
        guard let content = try? String(contentsOfFile: inboxFileURL.path, encoding: .utf8) else {
            todayEntries = []
            return
        }
        let heading = "## \(Self.dayFormatter.string(from: Date()))"
        var entries: [CaptureEntry] = []
        var inToday = false
        var currentTime: String?
        var currentLines: [String] = []
        var currentRaw: [String] = []

        func flush() {
            if let time = currentTime {
                entries.append(CaptureEntry(
                    time: time,
                    content: currentLines.joined(separator: "\n"),
                    rawBlock: currentRaw.joined(separator: "\n")))
            }
            currentTime = nil
            currentLines = []
            currentRaw = []
        }

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                inToday = (line == heading)
                continue
            }
            guard inToday else { continue }
            if line.hasPrefix("- "), line.count >= 8 {
                flush()
                let body = String(line.dropFirst(2))
                currentTime = String(body.prefix(5))
                currentLines = [body.count > 6 ? String(body.dropFirst(6)) : ""]
                currentRaw = [line]
            } else if line.hasPrefix("  "), currentTime != nil {
                currentLines.append(String(line.dropFirst(2)))
                currentRaw.append(line)
            } else if line.isEmpty {
                flush()
            }
        }
        flush()
        todayEntries = entries.reversed()
    }
}
