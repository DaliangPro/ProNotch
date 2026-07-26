import CoreGraphics
import Foundation

/// 内置屏亮度的读写。
///
/// 亮度没有公开 API——`CoreDisplay_Display_GetUserBrightness` 对外接屏会返回假的 1.0，
/// IOKit 那条路在 Apple Silicon 上早已不通。可用的只有私有框架 `DisplayServices`，
/// 用 `dlopen` + `dlsym` 取符号（不链接私有框架，符号缺失时静默降级为「不可调」，
/// 不会因为某次系统更新改了框架就起不来）。
///
/// 实测边界（2026-07-26 本机）：
/// - 内置屏（`CGDisplayIsBuiltin`）：`Get` 返回 0，`CanChange` 为 true，读到 0.688 ✅
/// - 外接 LG TV：`Get` 返回 1000（失败码），`CanChange` 为 false ❌
/// - `DisplayServicesBrightnessChanged` 这个符号在本机 macOS 上**不存在**，
///   所以取符号一律走可选路径，有才调
///
/// 因此本控制器只管**内置屏**。合盖或纯外接使用时降级为「不可调」，
/// 我们不接管亮度键，原样放行交回系统。
@MainActor
enum BrightnessController {

    struct Reading {
        /// 0…1；`available == false` 时无意义
        let brightness: Double
        let available: Bool

        static let unavailable = Reading(brightness: 0, available: false)
    }

    /// 与音量同步：一格 1/16，⇧⌥ 微调 1/4 格（系统同款手感）
    static let step = 1.0 / 16
    static let fineStep = step / 4

    static func read() -> Reading {
        guard let display = builtinDisplay(), let get = fn.get else { return .unavailable }
        var value: Float = 0
        guard get(display, &value) == 0 else { return .unavailable }
        return Reading(brightness: Double(value), available: true)
    }

    /// 在当前亮度上加减一步并返回落定后的读数（同样在真实读数上做加减，见 VolumeController）
    @discardableResult
    static func nudge(by delta: Double) -> Reading {
        let now = read()
        guard now.available, let display = builtinDisplay(), let set = fn.set else { return .unavailable }
        let target = min(1, max(0, now.brightness + delta))
        guard set(display, Float(target)) == 0 else { return now }
        // 有这个符号的系统上要吼一嗓子，控制中心的亮度条才会跟着动；本机没有，故为可选。
        // 返回码无意义（叫不动就是没人听），显式丢弃
        _ = fn.changed?(display, target)
        return Reading(brightness: target, available: true)
    }

    // MARK: - 私有符号

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Int32

    private struct Symbols {
        let get: GetFn?
        let set: SetFn?
        let can: CanFn?
        let changed: ChangedFn?
    }

    /// 只 dlopen 一次。句柄故意不 dlclose——进程活多久就用多久，
    /// 关了下次还得重开，白白多一次磁盘映射
    private static let fn: Symbols = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            AppLog.systemHUD.error("DisplayServices 加载失败，亮度功能降级为不可用")
            return Symbols(get: nil, set: nil, can: nil, changed: nil)
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        return Symbols(
            get: sym("DisplayServicesGetBrightness", GetFn.self),
            set: sym("DisplayServicesSetBrightness", SetFn.self),
            can: sym("DisplayServicesCanChangeBrightness", CanFn.self),
            changed: sym("DisplayServicesBrightnessChanged", ChangedFn.self))
    }()

    /// 内置屏且当前真能调亮度才返回。合盖（内置屏不在活动列表里）时自然为 nil
    private static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first {
            CGDisplayIsBuiltin($0) == 1 && (fn.can?($0) ?? false)
        }
    }
}
