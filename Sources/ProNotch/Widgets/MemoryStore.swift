import AppKit
import Foundation

/// 整机内存占用快照（活动监视器同口径：已用 = App 内存 + 联动 + 被压缩）
struct MemorySnapshot {
    let total: UInt64        // 物理内存总量
    let appMemory: UInt64    // App 内存（internal − purgeable）
    let wired: UInt64        // 联动内存（内核锁定，不可换出）
    let compressed: UInt64   // 被压缩内存

    var used: UInt64 { appMemory + wired + compressed }
    var usedPercent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }

    /// 字节 → 「12.3 GB」（组件卡与收起态 slot 共用）
    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// 字节 → 智能单位（排行里小进程显示 MB 更可读）
    static func mem(_ bytes: UInt64) -> String {
        bytes >= 1_073_741_824
            ? String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
            : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

/// 排行条目：按 App 聚合的内存占用。一个 App 的主进程与全部 Helper/服务
/// 合并成一行（大梁老师定：要看的是「哪个 App 吃内存」，不是一堆 Helper 各排各的）
struct ProcessMemory: Identifiable {
    let id: String           // 聚合键：最外层 .app bundle 路径，或可执行文件路径
    let name: String
    let footprint: UInt64    // 组内各进程 phys_footprint 之和（活动监视器「内存」列同口径）
    let icon: NSImage?       // App 取 bundle 图标；纯进程为 nil（视图给兜底符号）
}

/// 按 App 聚合的纯函数逻辑（单测对象）
enum MemoryGrouping {
    /// 可执行路径 → 所属最外层 .app bundle 路径：Chrome/Claude 一类多进程 App 的
    /// Helper（含内嵌 .app/.xpc）可执行文件都藏在宿主包里，取最外层即归并到宿主；
    /// 不在任何 .app 内返回 nil。只认目录组件——末段是可执行文件本体，不参与匹配
    static func appBundlePath(of executablePath: String) -> String? {
        var prefix = ""
        for comp in executablePath.split(separator: "/").dropLast() {
            prefix += "/\(comp)"
            if comp.hasSuffix(".app") { return prefix }
        }
        return nil
    }
}

/// 内存数据源：host_statistics64 读 host 级 VM 统计。
/// 单次读取微秒级、无网络无磁盘，调用方按需驱动刷新（展开页 3s、收起 slot 10s）
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot?
    /// 占用排行 top N（仅组件页展开时刷新——全量遍历比 refresh() 重，收起态心跳不跑）
    @Published private(set) var topProcesses: [ProcessMemory] = []
    /// bundle 名与图标缓存（路径 → 结果，App 不变结果不变）
    private var appNameCache: [String: String] = [:]
    private var appIconCache: [String: NSImage] = [:]

    func refresh() {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        // App 内存 = 匿名页 − 可清除页（活动监视器口径）
        let app = UInt64(max(0, Int64(info.internal_page_count) - Int64(info.purgeable_count))) * page
        snapshot = MemorySnapshot(
            total: ProcessInfo.processInfo.physicalMemory,
            appMemory: app,
            wired: UInt64(info.wire_count) * page,
            compressed: UInt64(info.compressor_page_count) * page)
    }

    /// 刷新占用排行：proc_listallpids 全量遍历 + proc_pid_rusage 读 phys_footprint，
    /// 按「最外层 .app bundle」聚合（见 MemoryGrouping）后取前 count 名；
    /// CLI/守护进程按可执行路径聚合（多实例同样合并）。
    /// 同 uid 进程可读、系统进程 EPERM 自动跳过；整趟毫秒级，3 秒节奏主线程可担。
    /// 取 15 名：视口定高可见 6 行，其余滚动看（大梁老师定）
    func refreshTopProcesses(count: Int = 15) {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(n) + 32)   // 留余量防两次调用间新进程
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return }
        // 聚合键 → (App bundle 路径, 兜底展示名, 组内占用和)；名字图标只对最终上榜者解析
        var groups: [String: (appPath: String?, fallbackName: String, foot: UInt64)] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = rusage_info_current()
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard kr == 0, info.ri_phys_footprint > 0 else { continue }
            let exec = Self.execPath(pid)
            let appPath = exec.flatMap { MemoryGrouping.appBundlePath(of: $0) }
            let fallbackName = exec.map { String($0.split(separator: "/").last ?? "") }
                ?? Self.bsdName(pid)
            let key = appPath ?? exec ?? "name:\(fallbackName)"
            groups[key, default: (appPath: appPath, fallbackName: fallbackName, foot: 0)]
                .foot += info.ri_phys_footprint
        }
        topProcesses = groups.sorted { $0.value.foot > $1.value.foot }.prefix(count).map { key, g in
            guard let app = g.appPath else {
                return ProcessMemory(id: key, name: g.fallbackName, footprint: g.foot, icon: nil)
            }
            return ProcessMemory(id: key, name: appName(app), footprint: g.foot, icon: appIcon(app))
        }
    }

    /// bundle 路径 → Finder 本地化名（微信这类中文名靠它）；结果缓存，
    /// displayName 走 LaunchServices 不便宜，3 秒一刷别对同一 App 反复取
    private func appName(_ path: String) -> String {
        if let hit = appNameCache[path] { return hit }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }   // 用户开了「显示扩展名」时会带着
        appNameCache[path] = name
        return name
    }

    /// bundle 路径 → App 图标（IconServices 同样不便宜，缓存同理）
    private func appIcon(_ path: String) -> NSImage {
        if let hit = appIconCache[path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        appIconCache[path] = icon
        return icon
    }

    private static func execPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    private static func bsdName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let name = String(cString: buf)
        return name.isEmpty ? "pid \(pid)" : name
    }
}
