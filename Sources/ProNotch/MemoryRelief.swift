import Foundation

/// 主动内存归还：截图/长截图会瞬时分配 GB 级位图，对象释放后 libmalloc 默认把
/// 大块留在自家 free cache 备用、不还内核，phys_footprint 长期虚高（实测常驻
/// 617 MB，其中 MALLOC_LARGE (empty) 空壳就占 381 MB，堆里并无存活大对象）。
/// 在重路径收尾调一次 malloc_zone_pressure_relief，把空闲大块 madvise 还给系统。
enum MemoryRelief {
    /// 延迟归还：等当前 runloop 的 autorelease pool 排干、大对象真正 free 之后再收；
    /// 立刻调会扑空（大位图此刻还挂在池里没释放）
    static func relieveSoon(after seconds: Double = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let freed = malloc_zone_pressure_relief(nil, 0)
            if freed > 0 {
                print("[ProNotch] 内存归还: \(freed / 1_048_576) MB 空闲块还给系统")
            }
        }
    }
}
