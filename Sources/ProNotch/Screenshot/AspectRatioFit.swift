import Foundation

/// 截图选区的比例辅助：把随手拖出来的框收成规整比例。
///
/// 由来（大梁老师，2026-07-28）：想截一个正方形，只能盯着实时尺寸数字手动拖，
/// 怎么拖都差几个像素。改由预设比例一键收齐。
///
/// 挑在这几档上：1:1 头像与方图，4:3 与 3:2 常规图，16:9 视频与宽屏配图。
/// 竖向比例暂不做——真要竖图，把横向档位的框旋转着框一次更快（大梁老师定）
enum AspectRatio: String, CaseIterable, Identifiable {
    case free, square, fourThree, threeTwo, sixteenNine

    var id: String { rawValue }

    /// 宽 ÷ 高。自由态无约束
    var value: CGFloat? {
        switch self {
        case .free:        return nil
        case .square:      return 1
        case .fourThree:   return 4.0 / 3
        case .threeTwo:    return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        }
    }

    var label: String {
        switch self {
        case .free:        return "自由"
        case .square:      return "1:1"
        case .fourThree:   return "4:3"
        case .threeTwo:    return "3:2"
        case .sixteenNine: return "16:9"
        }
    }

    /// 把选区收成本比例：**中心不动、只往里收**（大梁老师定）。
    ///
    /// 只往里收，是为了不把你没看过的东西带进来——往外扩会把框外内容拉进画面。
    /// 中心不动，是因为框东西时主体一般居中；钉左上角的话主体会往右下偏出去。
    ///
    /// 传进来的应当是**最初拖出的那个框**，不是上一次收完的结果：
    /// 拿结果再收，来回点几个比例就越点越小（这也是 `ratioBaseRect` 存在的理由）
    func fit(_ rect: NSRect) -> NSRect {
        guard let ratio = value, ratio > 0,
              rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return rect }
        var w = rect.width
        var h = rect.height
        if w / h > ratio {
            w = h * ratio          // 太宽 → 收窄
        } else {
            h = w / ratio          // 太高 → 压扁
        }
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
