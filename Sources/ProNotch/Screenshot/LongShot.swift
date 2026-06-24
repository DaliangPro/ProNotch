import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import QuartzCore

/// 长截图拼接器（自动滚动专用）：相邻两帧对齐求「实际滚了多少」δ，把新一帧底部 δ 行接到结果底部。
/// 自动滚动每帧只滚一点、留大量重叠，且用「一大块内容(整帧的 1/3 ≈ 十几行字)」作参考——
/// 十几行字组合起来唯一，即使整页都是相似消息也绝不会挑错位置（这正是之前"小参考带"堆叠的根因）。
final class LongShotStitcher: @unchecked Sendable {   // 拼接放后台线程；调用方用 await 串行化访问，无并发
    let frameW: Int
    private let H: Int                 // 帧高(像素)
    private let cols: Int              // 匹配用水平采样列数
    private var segments: [CGImage]    // 向下：首帧 + 各次新增底条
    private var headSegs: [CGImage] = []  // 向上：各次新增顶条（最近的在前）
    private(set) var totalHeight: Int
    private var prevGray: [UInt8]      // 上一帧灰度（cols×H，行0=顶）
    private var lastDelta: Int?        // 上一帧实测滚动量（连续性先验中心）

    init?(firstFrame cg: CGImage) {
        guard cg.height > 80, cg.width > 8, let g = Self.gray(cg, cols: min(512, cg.width)) else { return nil }
        frameW = cg.width; H = cg.height; cols = min(512, cg.width)   // 高横向分辨率：密集文字也能区分行，破周期性误配
        segments = [cg]; totalHeight = cg.height
        prevGray = g
    }

    /// 与上一帧匹配求实际滚动量 δ 与匹配误差（每像素 SAD）。不改状态。
    /// 取「上一帧中部」一大块作参考（H/4≈8 行字，唯一）；它在这一帧出现在 (refTop-δ) 处。
    /// 连续性先验：δ 应≈「上一帧实测 δ」(首帧用命令值兜底)，越偏离越加分（轻量，只破平局）。
    /// 两阶段匹配（无窗口，全范围）：① 参考带在「全部可能 δ」上按带 SAD 排名（真 δ 带 SAD≈0=第一）取候选；
    /// ② 对候选用「整段重叠」逐像素复核，挑全重叠误差最小者（连续性轻微破平局）。
    /// 真 δ 是整段重叠误差的全局最小，必被找到——从根上杜绝"被窗口关在门外"；返回的 meanSad 即整段重叠误差。
    private func matchAgainstPrev(_ g: [UInt8], center: Int, up: Bool) -> (delta: Int, meanSad: Int) {
        let band = max(60, H / 5)
        let refTop = (H - band) / 2
        guard refTop > 0 else { return (0, 9999) }
        let span = band * cols
        let maxDelta = refTop                                  // δ 上限（参考块仍落在重叠区内）
        // ① 全范围算每个 δ 的带 SAD
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
        // ② 整段重叠复核带 SAD 最小的若干候选
        let topK = scored.sorted { $0.sad < $1.sad }.prefix(14)
        var bestDelta = scored[0].delta, bestFm = Int.max, bestScore = Int.max
        for c in topK {
            let fm = fullOverlapMeanSad(g, delta: c.delta, up: up)
            let s = fm * 24 + abs(c.delta - center)           // 全重叠误差为主，连续性轻微破平局
            if s < bestScore { bestScore = s; bestDelta = c.delta; bestFm = fm }
        }
        return (bestDelta, bestFm)
    }

    /// 「整段重叠」逐像素平均 SAD：向下=prev[δ:] vs new[:H-δ]，向上=prev[:H-δ] vs new[δ:]。真 δ 全段对齐→很小。
    private func fullOverlapMeanSad(_ g: [UInt8], delta: Int, up: Bool) -> Int {
        guard delta > 0, delta < H else { return 9999 }
        let n = (H - delta) * cols
        guard n > 0 else { return 9999 }
        return prevGray.withUnsafeBufferPointer { pp in
            g.withUnsafeBufferPointer { np -> Int in
                let pBase = up ? 0 : delta * cols
                let nBase = up ? delta * cols : 0
                var sad = 0, i = 0
                while i < n { let d = Int(pp[pBase + i]) - Int(np[nBase + i]); sad += d < 0 ? -d : d; i += 1 }
                return sad / n
            }
        }
    }

    /// 接入新一帧（已停稳）。expectedDelta=命令的滚动量(像素)，用作连续性先验。返回实际接入的新行数（0=没接/没动）。
    @discardableResult
    func addFrame(_ cg: CGImage, expectedDelta: Int, resync: Bool = false) -> Int {
        guard cg.width == frameW, cg.height == H, let g = Self.gray(cg, cols: cols) else { return 0 }
        // 恢复对齐(resync)：围绕 0 全范围找，接住暂停期间任意漂移；常规帧：围绕上一帧 δ 的窗口找
        let (delta, meanSad) = matchAgainstPrev(g, center: resync ? 0 : (lastDelta ?? expectedDelta), up: false)
        prevGray = g                                          // 始终更新（下一帧对齐用）
        guard meanSad < 28, delta > 0 else { return 0 }       // 没对上 / 没动 → 不接
        let newH = min(delta, H)
        guard let seg = cg.cropping(to: CGRect(x: 0, y: H - newH, width: frameW, height: newH)) else { return 0 }
        segments.append(seg); totalHeight += newH
        if !resync { lastDelta = delta }                      // 漂移量不是滚动速率，恢复时不更新先验
        return newH
    }

    /// 向上接入新一帧：内容向下移、新内容在顶部 δ 行 → 拼到结果「最顶」（最近的在前，result 时逆序）。
    @discardableResult
    func prependFrame(_ cg: CGImage, expectedDelta: Int, resync: Bool = false) -> Int {
        guard cg.width == frameW, cg.height == H, let g = Self.gray(cg, cols: cols) else { return 0 }
        let (delta, meanSad) = matchAgainstPrev(g, center: resync ? 0 : (lastDelta ?? expectedDelta), up: true)
        prevGray = g
        guard meanSad < 28, delta > 0 else { return 0 }
        let newH = min(delta, H)
        guard let seg = cg.cropping(to: CGRect(x: 0, y: 0, width: frameW, height: newH)) else { return 0 }   // 顶部 newH 行
        headSegs.append(seg); totalHeight += newH
        if !resync { lastDelta = delta }
        return newH
    }

    /// 到底后补「框下方」尾部：tall=最终位置向下伸到视口底的高帧；viewportBottom=视口底(tall 像素行)。
    /// 用 tall 顶部一框高与上一帧对齐求 δ，把「结果末尾之后 → 视口底」整段接上（含框内最后 δ 行 + 框下尾巴）。
    @discardableResult
    func addTail(_ tall: CGImage, viewportBottom: Int) -> Int {
        guard tall.width == frameW, tall.height > H,
              let topBox = tall.cropping(to: CGRect(x: 0, y: 0, width: frameW, height: H)),
              let g = Self.gray(topBox, cols: cols) else { return 0 }
        let (delta, meanSad) = matchAgainstPrev(g, center: 0, up: false)   // 末帧静止，期望 δ≈0
        let d = (meanSad < 28 && delta > 0) ? delta : 0       // 末帧通常没动(δ=0)
        let cutTop = max(0, H - d)
        let bottom = min(max(viewportBottom, H), tall.height)
        guard bottom > cutTop, let seg = tall.cropping(to: CGRect(x: 0, y: cutTop, width: frameW, height: bottom - cutTop)) else { return 0 }
        segments.append(seg); totalHeight += (bottom - cutTop)
        return bottom - cutTop
    }

    /// 到顶后补「框上方」头部：tallUp=最终位置向上伸到视口顶的高帧（框在其底部 H 行）；viewportTop=视口顶(tallUp 像素行)。
    /// 用 tallUp 底部一框高与上一帧对齐求 δ，把「视口顶 → 结果开头之前」整段拼到最顶。
    @discardableResult
    func addHead(_ tallUp: CGImage, viewportTop: Int) -> Int {
        let TH = tallUp.height
        guard tallUp.width == frameW, TH > H,
              let botBox = tallUp.cropping(to: CGRect(x: 0, y: TH - H, width: frameW, height: H)),
              let g = Self.gray(botBox, cols: cols) else { return 0 }
        let (delta, meanSad) = matchAgainstPrev(g, center: 0, up: true)    // 末帧静止，期望 δ≈0
        let d = (meanSad < 28 && delta > 0) ? delta : 0       // 末帧通常没动(δ=0)
        let cutBottom = min(TH, (TH - H) + d)                 // 框顶(+δ)以上都是新内容
        let top = max(0, min(viewportTop, cutBottom))
        guard cutBottom > top, let seg = tallUp.cropping(to: CGRect(x: 0, y: top, width: frameW, height: cutBottom - top)) else { return 0 }
        headSegs.append(seg); totalHeight += (cutBottom - top)
        return cutBottom - top
    }

    /// 拼成最终长图（CGImage，左上为页顶）：向上接入段(逆序) + 首帧 + 向下接入段。
    /// 不再做"成图后去重"——匹配已精确无重叠，去重只会误删页面上"长得像但不同"的真实内容（造成缺块）。
    private var orderedSegments: [CGImage] { Array(headSegs.reversed()) + segments }

    func result() -> CGImage? {
        let segs = orderedSegments
        let h = segs.reduce(0) { $0 + $1.height }
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
            Text("选择长截图方向").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            HStack(spacing: 14) {
                dirButton("向上", "arrow.up", action: onUp)
                dirButton("向下", "arrow.down", action: onDown)
            }
            Button(action: onCancel) {
                Text("取消").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }
    private func dirButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(width: 80, height: 64)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
        }.buttonStyle(.plain)
    }
}

/// 长截图输出选择条：录完后显示长图预览 + 复制 / 保存到桌面 / 丢弃（不再自动弹访达）
struct LongShotResultBar: View {
    let sizeText: String
    let preview: NSImage?
    let onCopy: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            if let preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 150, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            }
            HStack(spacing: 10) {
                Text("长截图 \(sizeText)").font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
                Button(action: onDiscard) {
                    Text("丢弃").font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }.buttonStyle(.plain)
                Button(action: onSave) {
                    Text("保存到桌面").font(.system(size: 12)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }.buttonStyle(.plain)
                Button(action: onCopy) {
                    Text("复制").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
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
    var body: some View {
        HStack(spacing: 11) {
            ZStack {                                 // 实时长图：随截随长，用户直接看到成果（固定占位，尺寸稳定不跳）
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.06))
                if let preview = session.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "rectangle.portrait").foregroundColor(.white.opacity(0.25)).font(.system(size: 18))
                }
            }
            .frame(width: 54, height: 124)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(session.phase.label)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.92))
                }
                Text("已拼 \(session.pointHeight)pt · 想提前结束就点「停止」")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5)).fixedSize()
                HStack(spacing: 8) {
                    Button(action: session.onCancel) {
                        Text("取消").font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }.buttonStyle(.plain)
                    Button(action: session.onFinish) {
                        Text("停止").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 6)
                            .background(Capsule().fill(Color.green.opacity(0.9)))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }
}
