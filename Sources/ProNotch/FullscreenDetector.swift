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
        var excluded: Set<Int> = [Int(ProcessInfo.processInfo.processIdentifier)]
        // 排除程序坞：它在每块屏上都挂一个与整屏等大的背景窗（layer 20）。放宽层级判据后
        // 这东西会被当成全屏应用，副屏刘海就此永久隐藏——用户看到的是「副屏根本没有刘海」，
        // 极难联想到是全屏检测误判。按 bundle id 认，不认本地化的 owner 名
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            excluded.insert(Int(app.processIdentifier))
        }
        return hasFullscreen(in: windows, target: target, excludingPIDs: excluded)
    }

    /// 纯判定（可单测）：窗口列表里是否存在铺满 target 屏、且不属于排除进程的可见窗口。
    /// 放宽层级——不再只认普通窗口层(layer 0)：Keynote 放映幕布挂在抬升层(layer>0)，
    /// 只要与整屏等大即算全屏；代价是必须显式排除那些同样整屏等大的常驻窗：
    /// 本进程（自家全屏光晕窗）与程序坞（每屏一个整屏背景窗），
    /// 漏排任一个都会把自己误判成「别的全屏应用」而永久隐藏刘海。
    nonisolated static func hasFullscreen(in windows: [[String: Any]],
                                          target: CGRect, excludingPIDs: Set<Int>) -> Bool {
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, !excludingPIDs.contains(pid),
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
