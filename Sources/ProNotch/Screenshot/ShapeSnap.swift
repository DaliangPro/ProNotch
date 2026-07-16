import Foundation

/// 停顿吸附识别出的规整形状（结构化，带几何参数，供后期选中/编辑）。
/// line/rect/ellipse 是可编辑对象；polyline（折线）仍作自由笔画、不可编辑。
enum SnappedShape {
    case line(NSPoint, NSPoint)
    case rect(NSRect)
    case ellipse(NSRect)
    case polyline([NSPoint])

    /// 绘制/命中用的采样点序列
    var points: [NSPoint] {
        switch self {
        case .line(let a, let b):
            return [a, b]
        case .rect(let r):
            return [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
                    NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.minY)]
        case .ellipse(let r):
            let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
            return (0...64).map { i in
                let t = 2 * .pi * CGFloat(i) / 64
                return NSPoint(x: cx + a * cos(t), y: cy + b * sin(t))
            }
        case .polyline(let pts):
            return pts
        }
    }
}

/// 手绘轨迹「停顿吸附成形状」：识别直线 / 椭圆(圆) / 矩形 / 折线。纯几何、无副作用。
/// 识别顺序：直线 → 椭圆 → 矩形 → 折线（顺序不可乱，见各分支注释）。
enum ShapeSnap {
    static func recognize(_ points: [NSPoint]) -> SnappedShape? {
        guard points.count >= 8 else { return nil }
        let path = totalLength(points)
        guard path > 40 else { return nil }   // 轨迹太短不吸附
        if let l = asLine(points, pathLength: path) { return l }
        if let e = asEllipse(points, pathLength: path) { return e }   // 椭圆在矩形前：归一化椭圆方程认曲线，矩形四角被挡下
        if let r = asRectangle(points, pathLength: path) { return r }
        if let p = asPolyline(points) { return p }
        return nil
    }

    // MARK: - 直线：首尾连线几乎不绕路，且所有点都贴着这条线
    private static func asLine(_ pts: [NSPoint], pathLength: CGFloat) -> SnappedShape? {
        let a = pts.first!, b = pts.last!
        let chord = dist(a, b)
        guard chord > 24 else { return nil }
        guard pathLength / chord < 1.15 else { return nil }
        let maxDev = pts.map { perpDistance($0, a, b) }.max() ?? 0
        guard maxDev < max(10, chord * 0.08) else { return nil }   // 放宽：稍微画弯一点也认成直线
        return .line(a, b)
    }

    // MARK: - 椭圆/圆：闭合 + 点都落在外接框内切椭圆上（归一化椭圆方程 (x/a)²+(y/b)²≈1）
    private static func asEllipse(_ pts: [NSPoint], pathLength: CGFloat) -> SnappedShape? {
        let p0 = pts.first!, p1 = pts.last!
        guard dist(p0, p1) < pathLength * 0.33 else { return nil }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, a = (x1 - x0) / 2, b = (y1 - y0) / 2
        guard a > 12, b > 12 else { return nil }
        let es = pts.map { p -> CGFloat in let ex = (p.x - cx) / a, ey = (p.y - cy) / b; return ex * ex + ey * ey }
        let mean = es.reduce(0, +) / CGFloat(es.count)
        let std = sqrt(es.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(es.count))
        guard std < 0.30 else { return nil }
        return .ellipse(NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    // MARK: - 矩形：闭合 + 所有点都贴外接框的边（圆已被前面拿走，这里放宽让手抖矩形也过、挡三角形/乱线）
    private static func asRectangle(_ pts: [NSPoint], pathLength: CGFloat) -> SnappedShape? {
        let a = pts.first!, b = pts.last!
        guard dist(a, b) < pathLength * 0.3 else { return nil }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        let w = x1 - x0, h = y1 - y0
        guard w > 24, h > 24 else { return nil }
        let maxEdgeDist = pts.map { min($0.x - x0, x1 - $0.x, $0.y - y0, y1 - $0.y) }.max() ?? 0
        guard maxEdgeDist < min(w, h) * 0.2 else { return nil }
        return .rect(NSRect(x: x0, y: y0, width: w, height: h))
    }

    // MARK: - 折线：Douglas-Peucker 简化出转折点（3~6 个关键点；各段够直）
    private static func asPolyline(_ pts: [NSPoint]) -> SnappedShape? {
        let chord = dist(pts.first!, pts.last!)
        let eps = max(12, chord * 0.06)   // 放宽：拐角更利落地简化出折点
        let simplified = douglasPeucker(pts, epsilon: eps)
        guard simplified.count >= 3, simplified.count <= 6 else { return nil }
        for i in 1..<simplified.count {
            guard let iStart = pts.firstIndex(of: simplified[i - 1]),
                  let iEnd = pts.firstIndex(of: simplified[i]), iEnd > iStart else { continue }
            let seg = Array(pts[iStart...iEnd])
            let segChord = dist(seg.first!, seg.last!)
            guard segChord > 0 else { continue }
            let dev = seg.map { perpDistance($0, seg.first!, seg.last!) }.max() ?? 0
            guard dev < max(14, segChord * 0.18) else { return nil }   // 放宽：手抖的段也认成直
        }
        return .polyline(simplified)
    }

    // MARK: - 几何辅助
    private static func dist(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func totalLength(_ pts: [NSPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var s: CGFloat = 0
        for i in 1..<pts.count { s += dist(pts[i - 1], pts[i]) }
        return s
    }

    private static func perpDistance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return dist(p, a) }
        return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len
    }

    private static func douglasPeucker(_ pts: [NSPoint], epsilon: CGFloat) -> [NSPoint] {
        guard pts.count > 2 else { return pts }
        var dmax: CGFloat = 0, index = 0
        for i in 1..<(pts.count - 1) {
            let d = perpDistance(pts[i], pts.first!, pts.last!)
            if d > dmax { dmax = d; index = i }
        }
        if dmax > epsilon {
            let left = douglasPeucker(Array(pts[0...index]), epsilon: epsilon)
            let right = douglasPeucker(Array(pts[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [pts.first!, pts.last!]
    }
}
