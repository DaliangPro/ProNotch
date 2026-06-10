import AppKit

/// 全屏检测：目标屏幕上是否有普通层级窗口铺满整屏。
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

        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  alpha > 0.1,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            // 普通最大化窗口不会覆盖菜单栏区域，只有全屏空间的窗口与整屏等大
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
