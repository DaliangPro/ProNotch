// NotchHub 应用图标生成器：黑色圆角底 + 亮色屏幕 + 顶部刘海 + 展开面板暗示
// 用法: swift Scripts/generate-icon.swift <输出 1024px PNG 路径>
import AppKit

guard CommandLine.arguments.count > 1 else {
    print("用法: swift generate-icon.swift <输出.png>")
    exit(1)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// 底：macOS 标准留白的圆角方形，深色渐变
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let bgGrad = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.18, green: 0.19, blue: 0.23, alpha: 1).cgColor,
    NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad,
                       start: CGPoint(x: 512, y: 924),
                       end: CGPoint(x: 512, y: 100), options: [])

// 屏幕：亮色渐变圆角矩形
let screen = CGRect(x: 196, y: 196, width: 632, height: 632)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 72, cornerHeight: 72, transform: nil)
ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()
let screenGrad = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.38, green: 0.90, blue: 0.96, alpha: 1).cgColor,
    NSColor(red: 0.12, green: 0.40, blue: 0.88, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(screenGrad,
                       start: CGPoint(x: 512, y: 828),
                       end: CGPoint(x: 512, y: 196), options: [])

// 刘海：屏幕顶部中央的黑色凸舌（底部圆角）
let notchWidth: CGFloat = 280
let notchHeight: CGFloat = 92
let notchRadius: CGFloat = 36
let notch = CGRect(x: 512 - notchWidth / 2, y: screen.maxY - notchHeight,
                   width: notchWidth, height: notchHeight)
let notchPath = CGMutablePath()
notchPath.move(to: CGPoint(x: notch.minX, y: notch.maxY))
notchPath.addLine(to: CGPoint(x: notch.minX, y: notch.minY + notchRadius))
notchPath.addQuadCurve(to: CGPoint(x: notch.minX + notchRadius, y: notch.minY),
                       control: CGPoint(x: notch.minX, y: notch.minY))
notchPath.addLine(to: CGPoint(x: notch.maxX - notchRadius, y: notch.minY))
notchPath.addQuadCurve(to: CGPoint(x: notch.maxX, y: notch.minY + notchRadius),
                       control: CGPoint(x: notch.maxX, y: notch.minY))
notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY))
notchPath.closeSubpath()
ctx.setFillColor(NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1).cgColor)
ctx.addPath(notchPath)
ctx.fillPath()

// 展开面板暗示：刘海正下方半透明圆角矩形 + 三个圆点
let panel = CGRect(x: 512 - 210, y: notch.minY - 40 - 170, width: 420, height: 170)
let panelPath = CGPath(roundedRect: panel, cornerWidth: 44, cornerHeight: 44, transform: nil)
ctx.setFillColor(NSColor(white: 0, alpha: 0.30).cgColor)
ctx.addPath(panelPath)
ctx.fillPath()
let dotRadius: CGFloat = 28
for index in 0..<3 {
    let cx = panel.midX + CGFloat(index - 1) * 116
    ctx.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - dotRadius, y: panel.midY - dotRadius,
                               width: dotRadius * 2, height: dotRadius * 2))
}

ctx.restoreGState()
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("已生成 1024px 图标: \(CommandLine.arguments[1])")
