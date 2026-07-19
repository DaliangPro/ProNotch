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

/// 排行条目：占用内存最多的进程
struct ProcessMemory: Identifiable {
    let pid: Int32
    let name: String
    let footprint: UInt64    // phys_footprint（活动监视器「内存」列同口径）
    let icon: NSImage?       // GUI App 有图标；纯进程为 nil（视图给兜底符号）
    var id: Int32 { pid }
}

/// 内存数据源：host_statistics64 读 host 级 VM 统计。
/// 单次读取微秒级、无网络无磁盘，调用方按需驱动刷新（展开页 3s、收起 slot 10s）
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot?
    /// 占用排行 top N（仅组件页展开时刷新——全量遍历比 refresh() 重，收起态心跳不跑）
    @Published private(set) var topProcesses: [ProcessMemory] = []

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

    /// 刷新占用排行：proc_listallpids 全量遍历 + proc_pid_rusage 读 phys_footprint。
    /// 同 uid 进程可读、系统进程 EPERM 自动跳过；整趟毫秒级，3 秒节奏主线程可担。
    /// 取 15 名：视口定高可见 6 行，其余滚动看（大梁老师定）
    func refreshTopProcesses(count: Int = 15) {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(n) + 32)   // 留余量防两次调用间新进程
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return }
        var entries: [(pid: Int32, foot: UInt64)] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = rusage_info_current()
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            if kr == 0, info.ri_phys_footprint > 0 {
                entries.append((pid, info.ri_phys_footprint))
            }
        }
        topProcesses = entries.sorted { $0.foot > $1.foot }.prefix(count).map { entry in
            // GUI App 优先取本地化名与图标；helper/纯进程回退 BSD 名
            if let app = NSRunningApplication(processIdentifier: entry.pid) {
                return ProcessMemory(pid: entry.pid,
                                     name: app.localizedName ?? Self.bsdName(entry.pid),
                                     footprint: entry.foot,
                                     icon: app.icon)
            }
            return ProcessMemory(pid: entry.pid, name: Self.bsdName(entry.pid),
                                 footprint: entry.foot, icon: nil)
        }
    }

    private static func bsdName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let name = String(cString: buf)
        return name.isEmpty ? "pid \(pid)" : name
    }
}
