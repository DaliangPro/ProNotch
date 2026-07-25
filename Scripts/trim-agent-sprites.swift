#!/usr/bin/env swift
// 裁白：把大梁老师重绘的 Agent 精灵去掉四周透明留白，贴身裁成横向小图。
//
// 起因：原图内容只占 512 画布约 43% 高、一半是透明气；先前裁成正方画布又把横向身形上下夹扁，
// 收起态里只有约 14pt 高，仍显小（大梁老师实测：要跟内存环一样大）。改为贴身横向、保留精灵自身
// 长宽比，配合 21pt 高的显示框，精灵就填满高度、与内存环等大——只去空白、不改画面、不变形。
//
// 用法：swift Scripts/trim-agent-sprites.swift
//   读 Resources/agent-sprites-src/*.png（原图母版，保持不动）
//   写 Resources/*.png（build-app.sh 打包进 bundle 的正式素材）
//
// 贴身裁剪：只留极小呼吸边、保留精灵自身横向长宽比（不撑成正方，否则横向身形上下被白边夹扁）。
// 等宽不靠画布正方，而靠槽位固定显示框（见 AgentSlotMetrics）——各图按自身比例 fit 居中进同一个框，
// 框宽恒定 → 刘海宽度不随选谁变；框高 = 内存环高（21pt），精灵就和内存环一样大。
import AppKit

let names = ["claude-code-idle", "claude-code-working", "codex-idle", "codex-working"]
let root = FileManager.default.currentDirectoryPath
let srcDir = root + "/Resources/agent-sprites-src/"
let dstDir = root + "/Resources/"

for n in names {
    guard let img = NSImage(contentsOfFile: srcDir + n + ".png"),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        print("✗ \(n)：读不出"); continue
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    // 不透明包围盒（alpha>0.05 视为有内容）
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX else { print("✗ \(n)：整张透明"); continue }
    let bw = maxX - minX + 1, bh = maxY - minY + 1
    // 贴身横向画布 = 包围盒 + 5% 呼吸边（四周等量，保留精灵自身长宽比，不撑成正方）
    let pad = Int(Double(max(bw, bh)) * 0.05)
    let cw = bw + pad * 2, ch = bh + pad * 2

    // 定尺位图上下文（scale 恒为 1，产物与机器无关，可复现）
    guard let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        print("✗ \(n)：建画布失败"); continue
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    // NSImage 绘制用左下原点：包围盒的 minY 自上而下，需转成左下的 y
    let srcRect = NSRect(x: minX, y: h - (maxY + 1), width: bw, height: bh)
    let dstRect = NSRect(x: pad, y: pad, width: bw, height: bh)
    img.draw(in: dstRect, from: srcRect, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = out.representation(using: .png, properties: [:]) else {
        print("✗ \(n)：编码失败"); continue
    }
    try? data.write(to: URL(fileURLWithPath: dstDir + n + ".png"))
    let fillBefore = Double(bh) / Double(h) * 100
    print(String(format: "✓ %@：内容 %dx%d → 贴身画布 %dx%d（原占高 %.0f%%，比例 %.2f）",
                 n, bw, bh, cw, ch, fillBefore, Double(cw) / Double(ch)))
}
