import AppKit

/// 刘海在哪些屏幕上显示（设置页可选）
enum NotchScreenMode: String, CaseIterable {
    case all, primary, secondary

    var title: String {
        switch self {
        case .all: return "全部屏幕"
        case .primary: return "仅主屏幕"
        case .secondary: return "仅副屏幕"
        }
    }
}

@MainActor
enum NotchGeometry {
    /// 按设置筛选出要建刘海的屏幕。
    /// 「主屏」取 NSScreen.screens.first（菜单栏所在那块）而非 NSScreen.main——
    /// 后者是「当前有键盘焦点」的屏，会随鼠标点击在屏间跳，刘海会跟着漂移。
    /// 选了「仅副屏」却只剩一块屏时退回主屏：否则刘海整个消失，用户只会当成 App 坏了
    static func screens(for mode: NotchScreenMode) -> [NSScreen] {
        pick(NSScreen.screens, mode: mode)
    }

    /// 纯筛选（可单测）：列表首项即主屏，与 NSScreen.screens 的约定一致
    nonisolated static func pick<T>(_ all: [T], mode: NotchScreenMode) -> [T] {
        guard let primary = all.first else { return [] }
        switch mode {
        case .all: return all
        case .primary: return [primary]
        case .secondary:
            let rest = Array(all.dropFirst())
            return rest.isEmpty ? [primary] : rest
        }
    }

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
