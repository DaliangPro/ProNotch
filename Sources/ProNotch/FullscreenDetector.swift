import AppKit

/// 全屏检测：目标屏幕上是否有铺满整屏的覆盖窗（原生全屏 / Keynote 放映幕布等都算）。
/// 基于 CGWindowList（仅读取边界与层级，无需任何权限）
@MainActor
enum FullscreenDetector {
    static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let frame = screen.frame
        // NSScreen 原点在主屏左下，CGWindow 原点在主屏左上，做一次 Y 翻转
        let target = CGRect(x: frame.origin.x,
                            y: primary.frame.maxY - frame.maxY,
                            width: frame.width,
                            height: frame.height)
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { return false }
        return hasFullscreen(in: windows, target: target,
                             excludingPID: Int(ProcessInfo.processInfo.processIdentifier))
    }

    /// 纯判定（可单测）：窗口列表里是否存在铺满 target 屏、且非本进程的可见窗口。
    /// 放宽层级——不再只认普通窗口层(layer 0)：Keynote 放映幕布挂在抬升层(layer>0)，
    /// 只要与整屏等大即算全屏；但必须排除本进程窗口——自家全屏光晕窗也整屏等大，
    /// 若不排除会把自己误判成"别的全屏应用"而永久隐藏刘海。
    nonisolated static func hasFullscreen(in windows: [[String: Any]],
                                          target: CGRect, excludingPID: Int) -> Bool {
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, pid != excludingPID,
                  let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.1,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            // 与整屏等大（容差）：普通窗口/悬浮窗不会精确铺满，只有全屏应用与放映幕布会
            if abs(bounds.minX - target.minX) <= 2,
               abs(bounds.minY - target.minY) <= 2,
               abs(bounds.width - target.width) <= 4,
               abs(bounds.height - target.height) <= 4 {
                return true
            }
        }
        return false
    }
}
