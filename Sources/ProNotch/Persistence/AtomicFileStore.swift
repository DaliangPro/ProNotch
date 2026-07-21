import Foundation

/// 本地 JSON 持久化的统一入口：串行化写入 + 单调 revision + 损坏文件保全。
///
/// 病灶有三处，聊天、剪贴板、话术三个 Store 各中一部分：
///
/// 1. 「主线程改内存 → 甩个 detached task 写盘」。detached task 之间没有顺序保证，
///    连续两次保存完全可能倒着落地，旧快照把新状态盖掉。
/// 2. `try? data.write(to:)` 不是原子写。写到一半掉电/被杀，磁盘上留下半截 JSON，
///    下次启动解码失败——而失败又被 `try?` 静默吞掉，用户的历史就这么无声消失了。
/// 3. 解码失败后直接从空数据开始，接着第一次保存就把那份损坏文件覆盖掉，
///    连事后抢救的机会都没有。
///
/// 对策：写入全部经过这个 actor（天然串行），每次带一个进程内单调递增的 revision，
/// 比已落盘值旧的直接丢弃；写之前先留一份 `.bak`；加载失败时把损坏文件改名保全，
/// 再试 `.bak`，两者都不行才从空数据开始，并把原因交回调用方展示。
actor AtomicFileStore {
    static let shared = AtomicFileStore()

    /// 每个文件已落盘的最高 revision（键为标准化后的路径）
    private var written: [String: UInt64] = [:]

    enum WriteResult: Equatable {
        case written(revision: UInt64)
        /// 已有更新的快照落盘，本次作废
        case stale(revision: UInt64, latest: UInt64)

        var didWrite: Bool { if case .written = self { return true } else { return false } }
    }

    // MARK: - 写入

    /// 编码并原子写入。编码放在 actor 上执行，不占主线程
    @discardableResult
    func write<T: Encodable & Sendable>(_ value: T, to url: URL, revision: UInt64) throws -> WriteResult {
        // 先挡代际再编码：过期快照连编码的开销都省掉
        if let stale = staleResult(for: url, revision: revision) { return stale }
        return try writeData(JSONEncoder().encode(value), to: url, revision: revision)
    }

    @discardableResult
    func writeData(_ data: Data, to url: URL, revision: UInt64) throws -> WriteResult {
        if let stale = staleResult(for: url, revision: revision) { return stale }
        try Self.writeAtomically(data, to: url)
        written[Self.key(url)] = revision
        return .written(revision: revision)
    }

    /// 已落盘的最高 revision（测试与诊断用）
    func writtenRevision(for url: URL) -> UInt64? { written[Self.key(url)] }

    private func staleResult(for url: URL, revision: UInt64) -> WriteResult? {
        guard let latest = written[Self.key(url)], revision <= latest else { return nil }
        return .stale(revision: revision, latest: latest)
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// 原子替换 + 留底：先把旧内容抄一份 `.bak`，再原子写新内容。
    /// 任何一步崩掉，磁盘上都至少还有一份完整可解码的 JSON
    nonisolated static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 备份失败不阻断主写入：备份是加分项，主文件才是正事
        if let old = try? Data(contentsOf: url), !old.isEmpty {
            try? old.write(to: backupURL(for: url), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    // MARK: - 加载

    /// 一次加载的结果
    struct LoadResult<T>: Sendable where T: Sendable {
        /// nil 表示没有可用数据（首次运行，或损坏且无备份），调用方应从空数据开始
        var value: T?
        /// 非 nil 表示主文件出过问题，文案可直接展示给用户
        var error: String?
        /// 损坏原件的保全去处
        var quarantined: URL?
    }

    /// 解码本地 JSON。主文件损坏时**不覆盖**：改名保全为 `.corrupt-<时间戳>`，
    /// 再尝试从 `.bak` 恢复；都不行才返回空值并带上可见错误
    nonisolated static func load<T: Decodable & Sendable>(
        _ type: T.Type, from url: URL, now: Date = Date()
    ) -> LoadResult<T> {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(value: nil)   // 文件不存在：首次运行，不算异常
        }
        if let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return LoadResult(value: decoded)
        }
        let name = url.lastPathComponent
        let kept = quarantine(url, now: now)
        let keptName = kept?.lastPathComponent ?? "（改名失败）"
        if let backup = try? Data(contentsOf: backupURL(for: url)),
           let decoded = try? JSONDecoder().decode(T.self, from: backup) {
            // 备份可用就把它扶正，下次启动走正常路径
            try? backup.write(to: url, options: .atomic)
            return LoadResult(value: decoded,
                              error: "\(name) 已损坏，已从备份恢复；损坏原件保留为 \(keptName)",
                              quarantined: kept)
        }
        return LoadResult(value: nil,
                          error: "\(name) 已损坏且无可用备份，将从空数据开始；损坏原件保留为 \(keptName)",
                          quarantined: kept)
    }

    /// 把损坏文件改名保全——只改名，绝不覆盖、绝不删除
    @discardableResult
    nonisolated static func quarantine(_ url: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let base = url.appendingPathExtension("corrupt-\(stamp(now))")
        var target = base
        var n = 2
        // 同一秒内连续损坏两次也不能互相盖掉
        while fm.fileExists(atPath: target.path) {
            target = url.appendingPathExtension("corrupt-\(stamp(now))-\(n)")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// 时间戳用 DateComponents 现拼：DateFormatter 是可变对象，做成全局单例会引入
    /// 一个跨线程共享的可变状态，得不偿失
    private nonisolated static func stamp(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

/// 进程内单调递增的保存代际。
///
/// 为什么不放在各 Store 里各记各的：Store 可能被重建（测试里更是频繁重建），
/// 而 `AtomicFileStore` 记的是**文件**的最高 revision。各记各的会让新 Store 的
/// 第一次保存带着 revision 1 撞上文件里已有的 revision 5，被当成过期快照丢掉。
/// 全局单调就没有这个坑
@MainActor
enum PersistRevision {
    private static var counter: UInt64 = 0

    static func next() -> UInt64 {
        counter &+= 1
        return counter
    }
}
