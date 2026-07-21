import CoreGraphics
import Foundation

/// 一次窗口形状捕获的结果，和它属于谁绑在一起。
///
/// 只存 `CGImage` 是不够的：图从哪个窗口来、属于第几次吸附，都得跟着走
struct CapturedWindowShape {
    let windowID: CGWindowID
    let generation: UInt64
    let image: CGImage
}

/// 窗口吸附截图的身份与代际管理。
///
/// 吸附窗口 A 后异步截它的真实圆角形状图。用户手快，可以在这期间改吸附窗口 B——
/// 若 A 的结果后返回，原实现直接 `snappedWindowImage = img` 就把 B 的图覆盖了，
/// 而导出只判断"图非空"，于是复制/保存出来的是 A 的内容。
/// 这里把每次吸附标上代际，异步结果回来要同时对上窗口 ID、代际、以及 overlay 还没关，
/// 三者缺一就丢弃。
@MainActor
final class WindowShapeCoordinator {
    private(set) var generation: UInt64 = 0
    private(set) var windowID: CGWindowID?
    private(set) var shape: CapturedWindowShape?
    private(set) var isClosed = false
    private var task: Task<Void, Never>?

    /// 开始吸附一个新窗口：递增代际、取消在途任务、清掉旧形状、记下当前窗口
    @discardableResult
    func beginSnap(windowID id: CGWindowID) -> UInt64 {
        task?.cancel()
        task = nil
        generation &+= 1
        windowID = id
        shape = nil
        return generation
    }

    /// 自由框选、重新选区、关闭 overlay：让在途结果全部作废
    func invalidate() {
        task?.cancel()
        task = nil
        generation &+= 1
        windowID = nil
        shape = nil
    }

    /// overlay 关闭：之后任何结果都不再收
    func close() {
        invalidate()
        isClosed = true
    }

    func track(_ task: Task<Void, Never>?) {
        self.task = task
    }

    /// 收下一份异步结果。三重校验都过才写入，返回是否被采纳
    @discardableResult
    func accept(_ image: CGImage?, windowID id: CGWindowID, generation gen: UInt64) -> Bool {
        guard !isClosed, gen == generation, id == windowID, let image else { return false }
        shape = CapturedWindowShape(windowID: id, generation: gen, image: image)
        return true
    }

    /// 当前可用于该窗口的形状图。ID 或代际对不上一律当作没有——
    /// 宁可重截一次，也不能把别的窗口的画面导出去
    func shapeImage(for id: CGWindowID?) -> CGImage? {
        guard let id, let shape, shape.windowID == id, shape.generation == generation else { return nil }
        return shape.image
    }

    /// 当前吸附窗口的形状图是否已就绪
    var currentShapeImage: CGImage? { shapeImage(for: windowID) }
}
