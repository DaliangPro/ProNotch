import AppKit

/// 选区四角的对角调整光标。
///
/// 病灶：原实现按名字取 AppKit 的私有光标（下划线开头的那两个 selector），
/// 再 `perform` 调用。私有 API 没有兼容性承诺——哪天改名或改返回类型，
/// 轻则四角悄悄退化成上下箭头，重则 `perform` 拿到的根本不是 NSCursor；
/// 上架审核也会因此被拒。（源码里不再出现那两个名字，另有测试守着不许回潮）
///
/// 对策：macOS 15 起有公开的 `NSCursor.frameResize`，直接用系统货；
/// 部署下限 macOS 14 上自绘一枚双向对角箭头——黑描边 + 白填充，
/// 压在任何截图内容上都看得清。两条路都不碰私有 selector。
enum DiagonalResizeCursor {

    /// 对角方向。`nwse` 是 ↖↘（左上—右下），`nesw` 是 ↗↙（右上—左下）
    enum Axis {
        case nwse
        case nesw
    }

    /// 光标位图边长（pt）。24 与系统各光标同量级，太小则箭头糊成一团
    static let size: CGFloat = 24

    /// resetCursorRects 每次鼠标移动都可能触发，图别重复画
    private static let nwseCursor = makeCursor(.nwse)
    private static let neswCursor = makeCursor(.nesw)

    static func cursor(for axis: Axis) -> NSCursor {
        switch axis {
        case .nwse: return nwseCursor
        case .nesw: return neswCursor
        }
    }

    private static func makeCursor(_ axis: Axis) -> NSCursor {
        if #available(macOS 15.0, *) {
            // 系统自带的边框调整光标，与访达、窗口边缘完全一致
            return NSCursor.frameResize(position: axis == .nwse ? .topLeft : .topRight,
                                        directions: .all)
        }
        // 热点取正中：双向箭头的「抓取点」就在交叉处
        return NSCursor(image: image(for: axis),
                        hotSpot: NSPoint(x: size / 2, y: size / 2))
    }

    /// 自绘的双向对角箭头。抽成独立函数，测试才能在任何系统版本上直接验它
    static func image(for axis: Axis, size: CGFloat = DiagonalResizeCursor.size) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let inset: CGFloat = 3
            // 非翻转坐标系：原点在左下
            let a: NSPoint, b: NSPoint
            switch axis {
            case .nwse:   // ↖ 左上 —— 右下 ↘
                a = NSPoint(x: inset, y: size - inset)
                b = NSPoint(x: size - inset, y: inset)
            case .nesw:   // ↗ 右上 —— 左下 ↙
                a = NSPoint(x: size - inset, y: size - inset)
                b = NSPoint(x: inset, y: inset)
            }

            let heads = NSBezierPath()
            heads.append(head(at: a, towards: b))
            heads.append(head(at: b, towards: a))

            let shaft = NSBezierPath()
            shaft.move(to: a)
            shaft.line(to: b)

            // 先黑后白：描边比填充宽一圈，压在浅色截图上也不会糊掉
            NSColor.black.setStroke()
            shaft.lineWidth = 4.5
            shaft.stroke()
            heads.lineWidth = 3
            heads.lineJoinStyle = .round
            heads.stroke()

            NSColor.white.setStroke()
            NSColor.white.setFill()
            shaft.lineWidth = 2
            shaft.stroke()
            heads.fill()
            return true
        }
    }

    /// 顶点在 `tip`、朝 `other` 反方向张开的三角箭头
    private static func head(at tip: NSPoint, towards other: NSPoint) -> NSBezierPath {
        let dx = other.x - tip.x, dy = other.y - tip.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let ux = dx / len, uy = dy / len          // 由顶点指向另一端的单位向量
        let depth: CGFloat = 7, halfWidth: CGFloat = 4.5
        let baseX = tip.x + ux * depth, baseY = tip.y + uy * depth
        let nx = -uy, ny = ux                     // 法向量

        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: baseX + nx * halfWidth, y: baseY + ny * halfWidth))
        path.line(to: NSPoint(x: baseX - nx * halfWidth, y: baseY - ny * halfWidth))
        path.close()
        return path
    }
}
