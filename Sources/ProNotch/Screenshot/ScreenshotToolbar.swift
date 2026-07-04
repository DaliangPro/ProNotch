import AppKit
import SwiftUI

/// 框选子选项面板：形状(矩形/椭圆) / 线型(实线/虚线) / 高亮 / 颜色 / 粗细
struct BoxOptionsBar: View {
    let shape: BoxShape
    let dashed: Bool
    let highlight: Bool
    let colorHex: String
    let lineWidth: CGFloat
    let onShape: (BoxShape) -> Void
    let onDashed: (Bool) -> Void
    let onHighlight: () -> Void
    let onColor: (String) -> Void
    let onWidth: (CGFloat) -> Void

    static let palette = ["#FF453A", "#FF9F0A", "#FFD60A", "#34C759", "#0A84FF", "#FFFFFF"]
    static let widths: [CGFloat] = [2, 3.5, 5]

    var body: some View {
        HStack(spacing: 5) {
            icon("rectangle", active: shape == .rect) { onShape(.rect) }
            icon("circle", active: shape == .oval) { onShape(.oval) }
            sep
            lineBtn(false)
            lineBtn(true)
            sep
            icon("lightbulb", active: highlight, action: onHighlight)
            sep
            ForEach(Self.palette, id: \.self) { swatch($0) }
            sep
            ForEach(Self.widths, id: \.self) { widthBtn($0) }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }

    private var sep: some View { Divider().frame(height: 19).overlay(Color.white.opacity(0.15)) }

    private func icon(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 15))
                .foregroundColor(active ? .cyan : .white.opacity(0.85))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Color.cyan.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func lineBtn(_ d: Bool) -> some View {
        Button { onDashed(d) } label: {
            Group {
                if d { HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Capsule().frame(width: 5, height: 2.4) } } }
                else { Capsule().frame(width: 19, height: 2.4) }
            }
            .foregroundColor(dashed == d ? .cyan : .white.opacity(0.85))
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(dashed == d ? Color.cyan.opacity(0.18) : .clear))
            .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func swatch(_ hex: String) -> some View {
        Button { onColor(hex) } label: {
            Circle().fill(Color(hex: hex))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.white.opacity(colorHex == hex ? 0.95 : 0.25), lineWidth: colorHex == hex ? 2 : 0.5))
                .contentShape(Circle())
        }.buttonStyle(.plain)
    }

    private func widthBtn(_ w: CGFloat) -> some View {
        Button { onWidth(w) } label: {
            Capsule().fill(lineWidth == w ? Color.cyan : Color.white.opacity(0.85))
                .frame(width: 16, height: w)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lineWidth == w ? Color.cyan.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

/// 画笔子选项：颜色 + 粗细
struct PenOptionsBar: View {
    let colorHex: String
    let lineWidth: CGFloat
    let onColor: (String) -> Void
    let onWidth: (CGFloat) -> Void
    static let widths: [CGFloat] = [2.5, 4, 6.5]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(BoxOptionsBar.palette, id: \.self) { hex in
                Button { onColor(hex) } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white.opacity(colorHex == hex ? 0.95 : 0.25), lineWidth: colorHex == hex ? 2 : 0.5))
                        .contentShape(Circle())
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 19).overlay(Color.white.opacity(0.15))
            ForEach(Self.widths, id: \.self) { w in
                Button { onWidth(w) } label: {
                    Circle().fill(lineWidth == w ? Color.cyan : Color.white.opacity(0.85))
                        .frame(width: w + 3, height: w + 3).frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lineWidth == w ? Color.cyan.opacity(0.18) : .clear)).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)).fixedSize()
    }
}

/// 纯调色板子选项（备注 / 流程共用）
struct ColorOptionsBar: View {
    let colorHex: String
    let onColor: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(BoxOptionsBar.palette, id: \.self) { hex in
                Button { onColor(hex) } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 19, height: 19)
                        .overlay(Circle().strokeBorder(Color.white.opacity(colorHex == hex ? 0.95 : 0.25), lineWidth: colorHex == hex ? 2 : 0.5))
                        .contentShape(Circle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)).fixedSize()
    }
}

/// 马赛克子选项：涂抹/区域 模式 + 涂抹粗细
struct MosaicOptionsBar: View {
    let isBox: Bool
    let lineWidth: CGFloat
    let onMode: (Bool) -> Void
    let onWidth: (CGFloat) -> Void
    static let widths: [CGFloat] = [14, 22, 34]
    var body: some View {
        HStack(spacing: 5) {
            modeBtn("rectangle.dashed", active: isBox) { onMode(true) }       // 区域（默认、在前）
            modeBtn("paintbrush.pointed", active: !isBox) { onMode(false) }   // 涂抹
            if !isBox {
                Divider().frame(height: 19).overlay(Color.white.opacity(0.15))
                ForEach(Self.widths, id: \.self) { w in
                    Button { onWidth(w) } label: {
                        Circle().fill(lineWidth == w ? Color.cyan : Color.white.opacity(0.85))
                            .frame(width: w / 3 + 5, height: w / 3 + 5).frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lineWidth == w ? Color.cyan.opacity(0.18) : .clear)).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)).fixedSize()
    }
    private func modeBtn(_ icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15))
                .foregroundColor(active ? .cyan : .white.opacity(0.85))
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Color.cyan.opacity(0.18) : .clear)).contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

/// 马赛克图标：圆角方块内的双明度棋盘格（照大梁老师认可的示意图复刻，细密小格更像真实马赛克）
/// side = 视觉边长，调它即可与工具栏其它 SF Symbol 图标对齐
private struct ScreenshotMosaicGlyph: View {
    var color: Color
    var side: CGFloat = 20
    private let n = 5                       // 5×5 细棋盘
    var body: some View {
        let cell = side / CGFloat(n)
        VStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<n, id: \.self) { c in
                        Rectangle()
                            .fill(color.opacity((r + c).isMultiple(of: 2) ? 1.0 : 0.4))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
    }
}

/// 长截图图标（大梁老师选定方案：竖页三段分割）：竖长圆角页 + 两道分割线，
/// 墨水高 15.75 与 OCR 等高
private struct ScreenshotLongShotGlyph: View {
    var color: Color = .white
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.2)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5))
                .frame(width: 13.2, height: 16.0)
            Path { p in   // 一道中分割线
                p.move(to: CGPoint(x: 4.6, y: 9.0)); p.addLine(to: CGPoint(x: 16.4, y: 9.0))
            }.stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .frame(width: 21, height: 18)
    }
}

/// 翻译图标（大梁老师选定方案：横排双弧循环）：A ⇄ 文 横排，上下两道弧形循环箭头。
/// 圆弧类图标按字体设计惯例放大约 12% 才与平顶图标光学等大（画布 18.6 高）
private struct ScreenshotTranslateGlyph: View {
    var color: Color = .white
    private let line = StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
    var body: some View {
        ZStack {
            Text("A").font(.system(size: 9.0, weight: .bold)).foregroundColor(color)
                .position(x: 5.4, y: 9.3)
            Text("文").font(.system(size: 8.8, weight: .semibold)).foregroundColor(color)
                .position(x: 15.6, y: 9.3)
            Path { p in   // 上弧（左→右）+ 右端箭头
                p.move(to: CGPoint(x: 3.7, y: 2.7))
                p.addCurve(to: CGPoint(x: 17.3, y: 2.7),
                           control1: CGPoint(x: 7.9, y: -0.2), control2: CGPoint(x: 13.1, y: -0.2))
                p.move(to: CGPoint(x: 15.5, y: 1.2))
                p.addLine(to: CGPoint(x: 17.5, y: 2.7)); p.addLine(to: CGPoint(x: 15.3, y: 4.1))
            }.stroke(color, style: line)
            Path { p in   // 下弧（右→左）+ 左端箭头
                p.move(to: CGPoint(x: 17.3, y: 15.9))
                p.addCurve(to: CGPoint(x: 3.7, y: 15.9),
                           control1: CGPoint(x: 13.1, y: 18.8), control2: CGPoint(x: 7.9, y: 18.8))
                p.move(to: CGPoint(x: 5.5, y: 17.4))
                p.addLine(to: CGPoint(x: 3.5, y: 15.9)); p.addLine(to: CGPoint(x: 5.7, y: 14.5))
            }.stroke(color, style: line)
        }
        .frame(width: 21, height: 18.6)
    }
}

/// 工具栏图标按钮统一容器：静止略暗，hover 时图标 + 背景一起变亮；active 显示青色高亮
private struct ToolbarIconButton<Content: View>: View {
    var active: Bool = false
    let help: String
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content   // 传入 hover 状态，让图标自身随之变亮
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            content(hover)
                .frame(width: 35, height: 31)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.cyan.opacity(hover ? 0.30 : 0.18)
                                 : Color.white.opacity(hover ? 0.13 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .overlay(alignment: .top) {   // 中文说明气泡：浮在该图标正下方（水平居中于本按钮）
            if hover {
                Text(help)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .offset(y: 46)   // 从按钮顶边下推到工具栏下方约 8pt
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: hover)
    }
}

/// 截图工具栏：框选 / 备注 / 流程 / 保存到桌面 / 取消 / 复制（确定）
struct ScreenshotToolbar: View {
    let boxActive: Bool
    let penActive: Bool
    let mosaicActive: Bool
    let noteActive: Bool
    let flowActive: Bool
    let translateTitle: String
    let onBox: () -> Void
    let onPen: () -> Void
    let onMosaic: () -> Void
    let onNote: () -> Void
    let onFlow: () -> Void
    let onUndo: () -> Void
    let onOCR: () -> Void
    let onLongShot: () -> Void
    let onPin: () -> Void
    let onAskAI: () -> Void
    let onTranslate: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            // 标注：框选 / 备注 / 流程 / 画笔 / 马赛克
            button("框选标注", "rectangle", active: boxActive, action: onBox)
            button("文字备注", "bubble.left", active: noteActive, action: onNote)
            button("步骤序号标注", "list.number", active: flowActive, action: onFlow)
            button("自由画笔", "pencil.tip", active: penActive, action: onPen)
            mosaicButton(active: mosaicActive)
            Divider().frame(height: 20).overlay(Color.white.opacity(0.15)).padding(.horizontal, 1)
            // 撤回：独立成组
            button("撤销上一步", "arrow.uturn.backward", action: onUndo)
            Divider().frame(height: 20).overlay(Color.white.opacity(0.15)).padding(.horizontal, 1)
            // 智能：翻译 / 提取文字
            if translateTitle == "翻译" { translateButton }   // 自绘「A ⇄ 文」字形
            else { button(translateTitle, "arrow.2.squarepath", action: onTranslate) }
            button("提取文字（OCR）", "text.viewfinder", action: onOCR)
            longShotButton
            button("截图问 AI", "sparkles", action: onAskAI)
            Divider().frame(height: 20).overlay(Color.white.opacity(0.15)).padding(.horizontal, 1)
            // 完成：取消 / 保存 / 复制(确定)
            button("取消", "xmark", action: onCancel)
            button("钉在屏幕（贴图）", "pin", action: onPin)
            button("保存到桌面", "arrow.down.to.line", action: onSave)
            button("复制到剪贴板", "checkmark", tint: .green, action: onCopy)
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }

    /// 长截图按钮：自绘横向矩形字形（与 OCR 图标墨水等高）
    private var longShotButton: some View {
        ToolbarIconButton(help: "长截图", action: onLongShot) { hover in
            ScreenshotLongShotGlyph(color: .white.opacity(hover ? 1.0 : 0.85))
        }
    }

    /// 翻译按钮：大梁老师提供的原稿
    private var translateButton: some View {
        ToolbarIconButton(help: "原位翻译", action: onTranslate) { hover in
            ScreenshotTranslateGlyph(color: .white.opacity(hover ? 1.0 : 0.85))
        }
    }

    /// 马赛克按钮：棋盘格自绘字形
    private func mosaicButton(active: Bool) -> some View {
        ToolbarIconButton(active: active, help: "马赛克遮挡", action: onMosaic) { hover in
            ScreenshotMosaicGlyph(color: active ? .cyan : .white.opacity(hover ? 1.0 : 0.85))
        }
    }

    private func button(_ title: String, _ icon: String, active: Bool = false,
                        tint: Color = .white, action: @escaping () -> Void) -> some View {
        ToolbarIconButton(active: active, help: title, action: action) { hover in
            Image(systemName: icon).font(.system(size: 16.5))
                .foregroundColor(active ? .cyan : tint.opacity(hover ? 1.0 : 0.85))
        }
    }
}

/// OCR 识别结果面板：可编辑修正后复制（A 方案）
struct OCRResultPanel: View {
    @State var text: String
    let onCopy: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("识别结果（可编辑修正）")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.9))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(.white.opacity(0.5))
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .frame(width: 400, height: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
            HStack {
                Text(text.isEmpty ? "未识别到文字" : "\(text.split(separator: "\n").count) 行")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Button(action: { onCopy(text) }) {
                    Text("复制").font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 432)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
