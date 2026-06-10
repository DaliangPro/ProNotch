import AppKit

@MainActor
enum NotchGeometry {
    /// 优先选择带刘海的内建屏；没有刘海时退回主屏
    static func targetScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        if let main = NSScreen.main ?? NSScreen.screens.first {
            return main
        }
        fatalError("未检测到任何屏幕")
    }

    /// 刘海矩形（全局坐标，AppKit 原点在屏幕左下角）
    static func notchRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return CGRect(x: frame.midX - width / 2,
                          y: frame.maxY - topInset,
                          width: width,
                          height: topInset)
        }
        // 无刘海机型：在屏幕顶部居中模拟一个刘海热区
        let width: CGFloat = 196
        let height: CGFloat = 32
        return CGRect(x: frame.midX - width / 2,
                      y: frame.maxY - height,
                      width: width,
                      height: height)
    }
}
