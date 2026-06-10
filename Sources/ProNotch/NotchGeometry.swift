import AppKit

@MainActor
enum NotchGeometry {
    /// 面板跟随主屏（全局坐标原点、菜单栏所在的屏幕）：
    /// 外接屏作主屏时出现在外接屏顶部中间，仅用内建屏时贴住真实刘海
    static func targetScreen() -> NSScreen {
        guard let primary = NSScreen.screens.first else {
            fatalError("未检测到任何屏幕")
        }
        return primary
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
        // 无刘海屏幕：在菜单栏顶部居中模拟一个热区，高度与菜单栏一致
        let width: CGFloat = 200
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)
        return CGRect(x: frame.midX - width / 2,
                      y: frame.maxY - menuBarHeight,
                      width: width,
                      height: menuBarHeight)
    }
}
