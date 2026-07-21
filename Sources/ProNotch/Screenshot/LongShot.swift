import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import QuartzCore

/// 长截图的资源上限，集中定义。
///
/// 长图是「录多久就长多少」的，没有上限时一个无限滚动的页面能一直拼到系统内存耗尽——
/// 而且失败点在最后 `result()` 里一次性分配整张 RGBA buffer 的那一刻，
/// 此时用户已经录了几分钟，内容全部作废。所以上限要在「加新段之前」就判。
struct LongShotLimits: Sendable {
    /// 最大像素数
    let maxPixels: Int
    /// 最大高度（像素）。窄选区下像素预算不吃紧，靠这条兜住
    let maxHeight: Int
    /// 最大段数。段本身也占内存与合成时间
    let maxSegments: Int
    /// 最大录制时长（秒）
    let maxDuration: TimeInterval

    /// 最终图按 RGBA 8888 一次性分配，给 256 MB 安全预算
    static let pixelBudgetBytes = 256 * 1024 * 1024
    static let bytesPerPixel = 4

    /// 生产默认值。测试用小上限构造实例，省得真去拼一张 6700 万像素的图
    static let `default` = LongShotLimits(
        maxPixels: pixelBudgetBytes / bytesPerPixel,   // 约 6710 万，1440 宽约合 4.6 万像素高
        maxHeight: 100_000,
        maxSegments: 5_000,
        maxDuration: 600)

    enum Reason: Equatable {
        case pixels, height, segments, duration
        /// 提示语统一在这里，触发上限时告诉用户是"安全收尾"而不是"出错了"
        var message: String {
            switch self {
            case .pixels:   return "已达到安全上限（图像过大），已自动收尾"
            case .height:   return "已达到安全上限（长度过长），已自动收尾"
            case .segments: return "已达到安全上限（片段过多），已自动收尾"
            case .duration: return "已达到安全上限（录制过久），已自动收尾"
            }
        }
    }
}

/// 一次接帧的结果。
///
/// "接了 0 行"有两种完全不同的含义：「这帧没对上或页面没动」可以继续录，
/// 「撞上安全上限」必须立刻收尾。都返回 0 的话调用方无从区分。
enum LongShotIngest: Equatable {
    case appended(rows: Int)
    case skipped
    case rejected(LongShotLimits.Reason)

    var rows: Int { if case .appended(let r) = self { return r } else { return 0 } }
    var isRejected: Bool { if case .rejected = self { return true } else { return false } }
}

/// 长截图拼接器（自动滚动专用）：相邻两帧对齐求「实际滚了多少」δ，把新一帧底部 δ 行接到结果底部。
/// 自动滚动每帧只滚一点、留大量重叠，且用「一大块内容(整帧的 1/3 ≈ 十几行字)」作参考——
/// 十几行字组合起来唯一，即使整页都是相似消息也绝不会挑错位置（这正是之前"小参考带"堆叠的根因）。
///
/// 用 actor 而不是 `@unchecked Sendable` 的类：内部有可变段数组与灰度缓存，
/// 而接帧在后台跑、用户点「停止」或「双击预览」会同时来调 `result()`，
/// 靠"调用方记得 await"来保证串行是没有强制力的，actor 由编译器保证。
actor LongShotStitcher {
    /// 帧宽是不可变的，跨隔离读取无需 await
    nonisolated let frameW: Int
    private let H: Int                 // 帧高(像素)
    private let cols: Int              // 粗灰度采样列数（阶段①候选生成，求快）
    private let colsFine: Int          // 细灰度采样列数（阶段②整段复核——密集版面靠字形横向细节区分相似行）
    private var segments: [CGImage]    // 向下：首帧 + 各次新增底条
    private var headSegs: [CGImage] = []  // 向上：各次新增顶条（最近的在前）
    private(set) var totalHeight: Int
    private var prevGray: [UInt8]      // 上一帧粗灰度（cols×H，行0=顶）
    private var prevGrayFine: [UInt8]  // 上一帧细灰度（colsFine×H）
    private var lastDelta: Int?        // 上一帧实测滚动量（连续性先验中心）
    private var missStreak = 0         // 连续没对上的帧数（≥2 强制换锚，防动画区导致永久停摆）
    private let startedAt: TimeInterval
    private let limits: LongShotLimits
    /// 已触发的上限（触发后只读不增，已拼内容照常可取）
    private(set) var limitReason: LongShotLimits.Reason?

    /// `startedAt` 走参数而不是内部读时钟：测试要能确定性地推进"录制时长"，
    /// 生产侧靠默认值自动取单调时钟，两边都不用改调用姿势
    init?(firstFrame cg: CGImage,
          startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
          limits: LongShotLimits = .default) {
        guard cg.height > 80, cg.width > 8 else { return nil }
        let c = min(512, cg.width), cf = min(1536, cg.width)
        guard let g = Self.gray(cg, cols: c), let gf = Self.gray(cg, cols: cf) else { return nil }
        frameW = cg.width; H = cg.height; cols = c; colsFine = cf
        segments = [cg]; totalHeight = cg.height
        prevGray = g; prevGrayFine = gf
        self.startedAt = startedAt
        self.limits = limits
    }

    // MARK: - 资源上限

    /// 加新段之前先算「加进去之后」的总量。超了就拒收并记下原因——
    /// 不能等到 `result()` 里分配整张 buffer 时才失败，那时录了几分钟的内容已经没救了
    private func sizeLimit(rows: Int) -> LongShotLimits.Reason? {
        let nextHeight = totalHeight + rows
        if nextHeight > limits.maxHeight { return .height }
        if nextHeight > limits.maxPixels / max(1, frameW) { return .pixels }
        if segments.count + headSegs.count + 1 > limits.maxSegments { return .segments }
        return nil
    }

    private func admit(rows: Int, at now: TimeInterval) -> LongShotLimits.Reason? {
        if let limitReason { return limitReason }
        if now - startedAt > limits.maxDuration { return .duration }
        return sizeLimit(rows: rows)
    }

    /// 统一的收口：命中上限就记账并返回 `.rejected`，否则返回 nil 让调用方继续接
    private func reject(rows: Int, at now: TimeInterval) -> LongShotIngest? {
        guard let reason = admit(rows: rows, at: now) else { return nil }
        limitReason = reason
        return .rejected(reason)
    }

    /// 仅按时长判定（还没算出 δ 时先用它挡住，省掉一整轮匹配开销）
    private func rejectByDeadline(_ now: TimeInterval) -> LongShotIngest? {
        if let limitReason { return .rejected(limitReason) }
        guard now - startedAt > limits.maxDuration else { return nil }
        limitReason = .duration
        return .rejected(.duration)
    }

    /// 与上一帧匹配求实际滚动量 δ 与匹配误差（每像素 SAD）。不改状态。
    /// 取「上一帧中部」一大块作参考（H/4≈8 行字，唯一）；它在这一帧出现在 (refTop-δ) 处。
    /// 连续性先验：δ 应≈「上一帧实测 δ」(首帧用命令值兜底)，越偏离越加分（轻量，只破平局）。
    /// 两阶段匹配（无窗口，全范围）：① 参考带在「全部可能 δ」上按带 SAD 排名（真 δ 带 SAD≈0=第一）取候选；
    /// ② 对候选用「整段重叠」逐像素复核，挑全重叠误差最小者（连续性轻微破平局）。
    /// 真 δ 是整段重叠误差的全局最小，必被找到——从根上杜绝"被窗口关在门外"；返回的 meanSad 即整段重叠误差。
    private func matchAgainstPrev(_ g: [UInt8], _ gFine: [UInt8], center: Int, up: Bool) -> (delta: Int, meanSad: Int) {
        let band = max(60, H / 5)
        let refTop = (H - band) / 2
        guard refTop > 0 else { return (0, 9999) }
        let span = band * cols
        let maxDelta = refTop                                  // δ 上限（参考块仍落在重叠区内）
        // ① 全范围算每个 δ 的带 SAD（粗灰度，求快；真 δ 带 SAD≈0 必进候选）
        var scored: [(sad: Int, delta: Int)] = []
        scored.reserveCapacity(maxDelta + 1)
        prevGray.withUnsafeBufferPointer { pp in
            g.withUnsafeBufferPointer { np in
                let rbase = refTop * cols
                var delta = 0
                while delta <= maxDelta {
                    let pos = up ? refTop + delta : refTop - delta
                    let nbase = pos * cols
                    var sad = 0, i = 0
                    while i < span { let d = Int(pp[rbase + i]) - Int(np[nbase + i]); sad += d < 0 ? -d : d; i += 1 }
                    scored.append((sad, delta))
                    delta += 1
                }
            }
        }
        guard !scored.isEmpty else { return (0, 9999) }
        // ② 候选用「细灰度整段重叠」复核。三处关键设计（离线仿真验证：普通/重复版面均零可见错误）：
        //    a) 候选自适应：带 SAD 接近最小值的全部复核（封顶 48）+ 强制纳入先验中心±3——
        //       周期版面下近似并列的候选有几十个，固定 topK 会把真 δ 挤出候选集（错一整行的根源之一）；
        //    b) 细灰度复核：粗灰度把不同文字行糊成相近轮廓，行高周期下假 δ 得分也低；细灰度保留字形细节；
        //    c) 误差 ×256 保精度：整数量化下噪声一翻就盖过先验，高精度后「内容差异≫先验≫噪声」层级稳定。
        let sortedAll = scored.sorted { $0.sad < $1.sad }
        let minSad = sortedAll[0].sad
        let margin = minSad + minSad / 2 + 40
        var cand = Array(sortedAll.prefix { $0.sad <= margin }.prefix(48).map { $0.delta })
        if center >= 0 {
            for d in max(0, center - 3)...min(maxDelta, center + 3) where !cand.contains(d) { cand.append(d) }
        }
        var bestDelta = sortedAll[0].delta, bestFm256 = Int.max, bestScore = Int.max
        for delta in cand {
            let fm256 = fullOverlapSad256(gFine, delta: delta, up: up)
            let s = fm256 + abs(delta - center)               // 全重叠误差为主，连续性破平局
            if s < bestScore { bestScore = s; bestDelta = delta; bestFm256 = fm256 }
        }
        return (bestDelta, bestFm256 / 256)
    }

    /// 「整段重叠」逐像素平均 SAD ×256（细灰度、高精度）：向下=prev[δ:] vs new[:H-δ]，向上=prev[:H-δ] vs new[δ:]。
    /// 真 δ 全段对齐→很小；δ=0 即全帧比对（静止帧识别）。
    private func fullOverlapSad256(_ gFine: [UInt8], delta: Int, up: Bool) -> Int {
        guard delta >= 0, delta < H else { return 9999 * 256 }
        let n = (H - delta) * colsFine
        guard n > 0 else { return 9999 * 256 }
        return prevGrayFine.withUnsafeBufferPointer { pp in
            gFine.withUnsafeBufferPointer { np -> Int in
                let pBase = up ? 0 : delta * colsFine
                let nBase = up ? delta * colsFine : 0
                var sad = 0, i = 0
                while i < n { let d = Int(pp[pBase + i]) - Int(np[nBase + i]); sad += d < 0 ? -d : d; i += 1 }
                return Int(UInt64(sad) * 256 / UInt64(n))
            }
        }
    }

    /// 接入新一帧（已停稳）。expectedDelta=命令的滚动量(像素)，用作连续性先验。返回实际接入的新行数（0=没接/没动）。
    @discardableResult
    func addFrame(_ cg: CGImage, expectedDelta: Int, resync: Bool = false,
                  at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> LongShotIngest {
        // actor 方法在调用方的任务上下文里执行：主循环被 cancelLongShot 取消后，
        // 那一帧哪怕已经排到 actor 队列里也不会再写进结果
        if Task.isCancelled { return .skipped }
        if let stop = rejectByDeadline(now) { return stop }
        guard cg.width == frameW, cg.height == H,
              let g = Self.gray(cg, cols: cols), let gf = Self.gray(cg, cols: colsFine) else { return .skipped }
        // 恢复对齐(resync)：围绕 0 全范围找，接住暂停期间任意漂移；常规帧：围绕上一帧 δ 找
        let (delta, meanSad) = matchAgainstPrev(g, gf, center: resync ? 0 : (lastDelta ?? expectedDelta), up: false)
        if meanSad < 28 {
            missStreak = 0
            prevGray = g; prevGrayFine = gf
            guard delta > 0 else { return .skipped }          // 对上了但页面没动
            let newH = min(delta, H)
            if let stop = reject(rows: newH, at: now) { return stop }
            guard let seg = cg.cropping(to: CGRect(x: 0, y: H - newH, width: frameW, height: newH)) else { return .skipped }
            segments.append(seg); totalHeight += newH
            if !resync { lastDelta = delta }                  // 漂移量不是滚动速率，恢复时不更新先验
            return .appended(rows: newH)
        }
        // 没对上：保留旧参考——下一帧对「上一个对上的帧」求累计 δ，中间内容不丢
        // （旧逻辑此处换参考帧，滚过的内容直接漏掉=缺行）；连挂两帧（动画区/画面突变）才强制换锚防停摆
        missStreak += 1
        if missStreak >= 2 { prevGray = g; prevGrayFine = gf; missStreak = 0 }
        return .skipped
    }

    /// 向上接入新一帧：内容向下移、新内容在顶部 δ 行 → 拼到结果「最顶」（最近的在前，result 时逆序）。
    @discardableResult
    func prependFrame(_ cg: CGImage, expectedDelta: Int, resync: Bool = false,
                      at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> LongShotIngest {
        // actor 方法在调用方的任务上下文里执行：主循环被 cancelLongShot 取消后，
        // 那一帧哪怕已经排到 actor 队列里也不会再写进结果
        if Task.isCancelled { return .skipped }
        if let stop = rejectByDeadline(now) { return stop }
        guard cg.width == frameW, cg.height == H,
              let g = Self.gray(cg, cols: cols), let gf = Self.gray(cg, cols: colsFine) else { return .skipped }
        let (delta, meanSad) = matchAgainstPrev(g, gf, center: resync ? 0 : (lastDelta ?? expectedDelta), up: true)
        if meanSad < 28 {
            missStreak = 0
            prevGray = g; prevGrayFine = gf
            guard delta > 0 else { return .skipped }
            let newH = min(delta, H)
            if let stop = reject(rows: newH, at: now) { return stop }
            guard let seg = cg.cropping(to: CGRect(x: 0, y: 0, width: frameW, height: newH)) else { return .skipped }   // 顶部 newH 行
            headSegs.append(seg); totalHeight += newH
            if !resync { lastDelta = delta }
            return .appended(rows: newH)
        }
        missStreak += 1
        if missStreak >= 2 { prevGray = g; prevGrayFine = gf; missStreak = 0 }
        return .skipped
    }

    /// 方向探测（不改任何状态）：探帧相对当前参考帧，内容像「向下滚」（新内容出现在底部）返回 +1，
    /// 相反返回 -1，没动/看不清返回 0。用于开滚前校准滚轮方向被「自然滚动/反转工具」翻转的情况。
    func probeDirection(_ cg: CGImage) -> Int {
        guard cg.width == frameW, cg.height == H,
              let g = Self.gray(cg, cols: cols), let gf = Self.gray(cg, cols: colsFine) else { return 0 }
        let down = matchAgainstPrev(g, gf, center: 0, up: false)
        let upM  = matchAgainstPrev(g, gf, center: 0, up: true)
        let downOK = down.meanSad < 28 && down.delta > 2
        let upOK   = upM.meanSad < 28 && upM.delta > 2
        if downOK, !upOK { return 1 }
        if upOK, !downOK { return -1 }
        if downOK, upOK { return down.meanSad <= upM.meanSad ? 1 : -1 }
        return 0
    }

    /// 到底后补「框下方」尾部：tall=最终位置向下伸到视口底的高帧；viewportBottom=视口底(tall 像素行)。
    /// 用 tall 顶部一框高与上一帧对齐求 δ，把「结果末尾之后 → 视口底」整段接上（含框内最后 δ 行 + 框下尾巴）。
    @discardableResult
    func addTail(_ tall: CGImage, viewportBottom: Int) -> LongShotIngest {
        if Task.isCancelled { return .skipped }
        guard tall.width == frameW, tall.height > H,
              let topBox = tall.cropping(to: CGRect(x: 0, y: 0, width: frameW, height: H)),
              let g = Self.gray(topBox, cols: cols), let gf = Self.gray(topBox, cols: colsFine) else { return .skipped }
        let (delta, meanSad) = matchAgainstPrev(g, gf, center: 0, up: false)   // 末帧静止，期望 δ≈0
        let d = (meanSad < 28 && delta > 0) ? delta : 0       // 末帧通常没动(δ=0)
        let cutTop = max(0, H - d)
        let bottom = min(max(viewportBottom, H), tall.height)
        guard bottom > cutTop else { return .skipped }
        // 收尾补段不看时长（本来就是最后一段，超时也该把这段补上），但尺寸上限必须守住
        if let reason = sizeLimit(rows: bottom - cutTop) { limitReason = reason; return .rejected(reason) }
        guard let seg = tall.cropping(to: CGRect(x: 0, y: cutTop, width: frameW, height: bottom - cutTop)) else { return .skipped }
        segments.append(seg); totalHeight += (bottom - cutTop)
        return .appended(rows: bottom - cutTop)
    }

    /// 到顶后补「框上方」头部：tallUp=最终位置向上伸到视口顶的高帧（框在其底部 H 行）；viewportTop=视口顶(tallUp 像素行)。
    /// 用 tallUp 底部一框高与上一帧对齐求 δ，把「视口顶 → 结果开头之前」整段拼到最顶。
    @discardableResult
    func addHead(_ tallUp: CGImage, viewportTop: Int) -> LongShotIngest {
        if Task.isCancelled { return .skipped }
        let TH = tallUp.height
        guard tallUp.width == frameW, TH > H,
              let botBox = tallUp.cropping(to: CGRect(x: 0, y: TH - H, width: frameW, height: H)),
              let g = Self.gray(botBox, cols: cols), let gf = Self.gray(botBox, cols: colsFine) else { return .skipped }
        let (delta, meanSad) = matchAgainstPrev(g, gf, center: 0, up: true)    // 末帧静止，期望 δ≈0
        let d = (meanSad < 28 && delta > 0) ? delta : 0       // 末帧通常没动(δ=0)
        let cutBottom = min(TH, (TH - H) + d)                 // 框顶(+δ)以上都是新内容
        let top = max(0, min(viewportTop, cutBottom))
        guard cutBottom > top else { return .skipped }
        if let reason = sizeLimit(rows: cutBottom - top) { limitReason = reason; return .rejected(reason) }
        guard let seg = tallUp.cropping(to: CGRect(x: 0, y: top, width: frameW, height: cutBottom - top)) else { return .skipped }
        headSegs.append(seg); totalHeight += (cutBottom - top)
        return .appended(rows: cutBottom - top)
    }

    /// 拼成最终长图（CGImage，左上为页顶）：向上接入段(逆序) + 首帧 + 向下接入段。
    /// 不再做"成图后去重"——匹配已精确无重叠，去重只会误删页面上"长得像但不同"的真实内容（造成缺块）。
    private var orderedSegments: [CGImage] { Array(headSegs.reversed()) + segments }

    func result() -> CGImage? {
        let segs = orderedSegments
        let h = segs.reduce(0) { $0 + $1.height }
        // 兜底：入口处的 admit 已挡住超限，这里再确认一次，绝不让 CGContext 去分配一个越界的 buffer
        guard h <= limits.maxHeight, h * frameW <= limits.maxPixels else { return nil }
        guard h > 0, let ctx = CGContext(data: nil, width: frameW, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = h
        for seg in segs {                         // CGContext 左下原点：第一段画在最上
            y -= seg.height
            ctx.draw(seg, in: CGRect(x: 0, y: y, width: frameW, height: seg.height))
        }
        return ctx.makeImage()
    }

    /// 实时预览：把已拼内容缩到指定宽度的小图（驱动控制条预览，随截随长；不去重、求快）
    func previewImage(width pw: Int) -> CGImage? {
        guard frameW > 0, totalHeight > 0 else { return nil }
        let ph = max(1, totalHeight * pw / frameW)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        let s = CGFloat(pw) / CGFloat(frameW)
        var y = CGFloat(ph)
        for seg in orderedSegments {
            let sh = CGFloat(seg.height) * s
            y -= sh
            ctx.draw(seg, in: CGRect(x: 0, y: y, width: CGFloat(pw), height: sh))
        }
        return ctx.makeImage()
    }


    /// 取灰度（行0=顶）：垂直保留每行(rows=H)，水平降到 cols 列。CGContext 转灰度，兼容任意像素格式。
    private static func gray(_ cg: CGImage, cols: Int) -> [UInt8]? {
        let H = cg.height
        guard H > 0, cols > 0, let ctx = CGContext(data: nil, width: cols, height: H, bitsPerComponent: 8, bytesPerRow: cols,
                                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cols, height: H))   // 不翻转：ctx.data 行0=顶，与 CGImage.cropping 一致
        guard let d = ctx.data else { return nil }
        let p = d.bindMemory(to: UInt8.self, capacity: cols * H)
        return Array(UnsafeBufferPointer(start: p, count: cols * H))
    }
}

/// 长截图方向
enum LongShotDirection { case down, up }

/// 长截图方向选择条：点「长截图」后先选向上 / 向下（浮在选区中央）
struct LongShotDirectionBar: View {
    let onUp: () -> Void
    let onDown: () -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("选择长截图方向").font(.system(size: 13, weight: .semibold)).foregroundColor(ToolbarChrome.mono(1))
            HStack(spacing: 14) {
                dirButton("向上", "arrow.up", action: onUp)
                dirButton("向下", "arrow.down", action: onDown)
            }
            Button(action: onCancel) {
                Text("取消").font(.system(size: 12)).foregroundColor(ToolbarChrome.mono(0.7))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(ToolbarChrome.panel(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ToolbarChrome.mono(0.12), lineWidth: 0.5))
        .fixedSize()
    }
    private func dirButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(ToolbarChrome.mono(1))
            .frame(width: 80, height: 64)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ToolbarChrome.mono(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ToolbarChrome.mono(0.18)))
        }.buttonStyle(.plain)
    }
}

/// 长截图输出选择条：录完后显示长图预览 + 复制 / 保存到桌面 / 丢弃（不再自动弹访达）
struct LongShotResultBar: View {
    let sizeText: String
    let preview: NSImage?
    let onInspect: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void
    /// 按宽高比显式算预览尺寸（不放大）。用 maxWidth/maxHeight 弹性约束时，
    /// NSHostingView.fittingSize 会按图片原始尺寸算理想大小 → 面板被撑得巨大而内容只占一角
    private static func fit(_ s: NSSize, maxW: CGFloat, maxH: CGFloat) -> NSSize {
        guard s.width > 0, s.height > 0 else { return NSSize(width: maxW, height: maxH) }
        let k = min(maxW / s.width, maxH / s.height, 1)
        return NSSize(width: s.width * k, height: s.height * k)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let preview {
                let size = Self.fit(preview.size, maxW: 300, maxH: 320)
                Image(nsImage: preview).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ToolbarChrome.mono(0.14)))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onInspect() }   // 双击放大检查，确认成不成再决定保存
                    .help("双击放大查看")
            }
            HStack(spacing: 10) {
                Text("长截图 \(sizeText)").font(.system(size: 11)).foregroundColor(ToolbarChrome.mono(0.55))
                Button(action: onDiscard) {
                    Text("丢弃").font(.system(size: 12)).foregroundColor(ToolbarChrome.mono(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(ToolbarChrome.mono(0.12)))
                }.buttonStyle(.plain)
                Button(action: onSave) {
                    Text("保存到桌面").font(.system(size: 12)).foregroundColor(ToolbarChrome.mono(1))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(ToolbarChrome.mono(0.18)))
                }.buttonStyle(.plain)
                Button(action: onCopy) {
                    Text("复制").font(.system(size: 12, weight: .semibold)).foregroundColor(ToolbarChrome.mono(1))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(ToolbarChrome.panel(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ToolbarChrome.mono(0.12), lineWidth: 0.5))
        .fixedSize()
    }
}

/// 长截图录制状态：驱动控制条显示阶段 / 已拼高度 / 实时预览，并回传完成 / 取消
@MainActor
final class LongShotSession: ObservableObject {
    /// 截取阶段（驱动状态文字，消除"停在那不知道在干嘛"的困惑）
    enum Phase {
        case scrolling, confirming, finalizing, paused
        var label: String {
            switch self {
            case .scrolling:  return "自动滚动截取中…"
            case .confirming: return "确认是否到底…"
            case .finalizing: return "补全底部…"
            case .paused:     return "鼠标移开 · 已暂停滚动"
            }
        }
    }
    @Published var pointHeight = 0           // 已拼高度（点）
    @Published var phase: Phase = .scrolling // 当前阶段
    @Published var preview: NSImage?         // 实时长图预览（随截随长）
    let onFinish: () -> Void
    let onCancel: () -> Void
    init(onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
    }
}

/// 长截图录制控制条：实时长图预览 + 阶段状态 + 已拼高度 + 完成 / 取消（浮在选区一侧的独立面板）
struct LongShotControlBar: View {
    @ObservedObject var session: LongShotSession
    let onInspect: () -> Void
    var body: some View {
        HStack(spacing: 11) {
            ZStack {                                 // 实时长图：随截随长，用户直接看到成果（固定占位，尺寸稳定不跳）
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ToolbarChrome.mono(0.06))
                if let preview = session.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "rectangle.portrait").foregroundColor(ToolbarChrome.mono(0.25)).font(.system(size: 18))
                }
            }
            .frame(width: 54, height: 124)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(ToolbarChrome.mono(0.15)))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onInspect() }   // 双击放大检查拼接质量
            .help("双击放大查看")
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(session.phase.label)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(ToolbarChrome.mono(0.92))
                }
                Text("已拼 \(session.pointHeight)pt · 想提前结束就点「停止」")
                    .font(.system(size: 11)).foregroundColor(ToolbarChrome.mono(0.5)).fixedSize()
                HStack(spacing: 8) {
                    Button(action: session.onCancel) {
                        Text("取消").font(.system(size: 12)).foregroundColor(ToolbarChrome.mono(0.85))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(ToolbarChrome.mono(0.12)))
                    }.buttonStyle(.plain)
                    Button(action: session.onFinish) {
                        Text("停止").font(.system(size: 12, weight: .semibold)).foregroundColor(ToolbarChrome.mono(1))
                            .padding(.horizontal, 18).padding(.vertical, 6)
                            .background(Capsule().fill(Color.green.opacity(0.9)))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(ToolbarChrome.panel(0.9), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ToolbarChrome.mono(0.12), lineWidth: 0.5))
        .fixedSize()
    }
}

/// 长图检视面板：双击控制条/结果条的预览打开——全宽适配、纵向滚动看细节，
/// 用户据此判断拼接成不成功、要不要保存。✕ 或再双击预览关闭。
struct LongShotInspector: View {
    let image: NSImage
    let fitWidth: CGFloat
    let onClose: () -> Void

    var body: some View {
        let scale = fitWidth / max(1, image.size.width)
        let fullH = image.size.height * scale
        VStack(spacing: 0) {
            HStack {
                Text("长图检查 · 滚动查看全图")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(ToolbarChrome.mono(0.8))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(ToolbarChrome.mono(0.85))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ToolbarChrome.mono(0.12)))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fitWidth, height: fullH)
            }
        }
        .background(ToolbarChrome.panel(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ToolbarChrome.mono(0.14), lineWidth: 0.5))
    }
}
