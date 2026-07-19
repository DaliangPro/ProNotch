import SwiftUI

/// 窗口根视图：绘制刘海黑色形状，承载悬停检测与展开内容
struct NotchContainerView: View {
    @EnvironmentObject var vm: NotchViewModel

    private var shapeWidth: CGFloat {
        vm.isExpanded ? vm.expandedShapeSize.width : vm.collapsedShapeWidth
    }

    private var shapeHeight: CGFloat {
        vm.isExpanded ? vm.expandedShapeSize.height : vm.notchRect.height
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 预警大卡垫底：从刘海形状背后弹出（形状不透明，缩回即被盖住），
            // 层级在黑形状之下，滑动过程天然是「刘海绽放成一块大卡」
            WeatherAlertCardView()
            notchLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var notchLayer: some View {
        ZStack(alignment: .top) {
            Color.black
            // 内容常驻、只做透明度门控（收起先快速隐去）——
            // 旧写法 if isExpanded 每次展开都从零重建整棵内容树，边长面板边搭视图必掉帧，
            // 这是展开动画不丝滑的主因；常驻后展开只剩形状与透明度动画。
            // 淡入必须赶在 0.21s 的过冲峰值前完成：内容显了形才会被容器缩放
            // 带着一起弹（NookX 同理，内容全程在场跟面板同冲同回）；此前延迟到
            // 0.15s 起淡，峰值时刚半透明，看着就是「黑形状在弹、内容没动画」
            ExpandedContentView()
                .frame(width: vm.expandedShapeSize.width,
                       height: vm.expandedShapeSize.height,
                       alignment: .top)
                .opacity(vm.isExpanded ? 1 : 0)
                .animation(vm.isExpanded ? .easeOut(duration: 0.12).delay(0.05)
                                         : .easeIn(duration: 0.1),
                           value: vm.isExpanded)
                .allowsHitTesting(vm.isExpanded)
            // 收起态两侧功能区（左内存右天气）：展开瞬间先快速隐去，收起完再淡回，
            // 与内容层的透明度门控互为镜像
            CollapsedSlotsView()
                .opacity(vm.isExpanded ? 0 : 1)
                .animation(vm.isExpanded ? .easeIn(duration: 0.1)
                                         : .easeOut(duration: 0.15).delay(0.2),
                           value: vm.isExpanded)
                .allowsHitTesting(false)
        }
        // 布局恒定为展开尺寸，「长大」只发生在下面的裁剪窗口——布局若随形状一起长，
        // 常驻内容会在动画期间被钉到形状左缘、随扩张从左滑入 380pt
        //（实测 geometry 轨迹 minX 424→44），这正是「展开时图标从左到右出现」的元凶
        .frame(width: vm.expandedShapeSize.width,
               height: vm.expandedShapeSize.height,
               alignment: .top)
        .clipShape(RevealNotchShape(width: shapeWidth, height: shapeHeight,
                                    topRadius: vm.isExpanded ? 12 : 6,
                                    bottomRadius: vm.isExpanded ? 20 : 10))
        .shadow(color: .black.opacity(vm.isExpanded ? 0.55 : 0), radius: 14, y: 5)
        // 展开弹跳 = NookX 式单次过冲（AX 实测对标：尺寸过冲约 8%、只冲一次、
        // 回落顺滑不折返）——Q 弹感来自「冲得狠 + 回得柔」，不是方向反复切换；
        // 此前「冲大→缩小→回正」的两次折返观感机械，已废。过冲空间靠窗口
        // 余量 64pt 支撑（见 windowFrame 注释）；收起不弹，轨迹恒为 1
        .keyframeAnimator(initialValue: CGFloat(1.0), trigger: vm.isExpanded) { view, scale in
            view.scaleEffect(scale, anchor: .top)
        } keyframes: { _ in
            // builder 不接受异构 if/else 分支，用同一轨迹参数化：收起时各帧恒 1 = 不弹
            let on = vm.isExpanded
            KeyframeTrack(\.self) {
                LinearKeyframe(CGFloat(1.0), duration: 0.05)               // 形状起步，缩放稍候
                CubicKeyframe(CGFloat(on ? 1.08 : 1.0), duration: 0.16)    // 唯一一冲：+8% 大过冲
                SpringKeyframe(CGFloat(1.0), duration: 0.34,
                               spring: Spring(duration: 0.34, bounce: 0.25)) // 弹簧滑回，自然衰减
            }
        }
    }
}

/// 恶劣天气预警大卡（大梁老师：小横幅太不明显，要大的）：收起态从刘海
/// 「长」出一块放大版刘海形状的预警卡。出场/收回与刘海展开完全同一套动画
/// （揭示裁剪 + 单次过冲弹跳，大梁老师要求对齐）；周边呼吸光晕颜色随天气
/// 而变；停 8 秒自动缩回（WeatherStore 控制）；点击展开面板到组件页看详情
private struct WeatherAlertCardView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var weather: WeatherStore
    /// 周边光晕呼吸相位（大梁老师：预警必须让人看见）
    @State private var glowPulse = false
    /// 正在展示的内容：退场动画期间仍要有东西可画，与 store 的 alert 解耦
    @State private var displayed: WeatherAlert?
    /// 出场/退场开关：驱动揭示裁剪与过冲弹跳，节奏对齐刘海展开
    @State private var shown = false

    /// 预警橙：标签底色恒定用它，光晕才随天气变——标签管「这是预警」，光晕管「是哪种」
    private static let warnColor = Color(hex: "#FF9F0A")

    /// 展开态不显示（面板都开着，没必要再挂卡）
    private var showing: Bool { weather.alert != nil && !vm.isExpanded }

    /// 光晕随天气换色（大梁老师定）：雷暴金黄、大雪冷白、冻雨冰蓝、大风青、降雨蓝
    private func glowColor(_ a: WeatherAlert) -> Color {
        switch a.symbol {
        case "cloud.bolt.rain.fill": return Color(hex: "#FFD60A")
        case "cloud.snow.fill":      return Color(hex: "#BFD9FF")
        case "cloud.sleet.fill":     return Color(hex: "#64D2FF")
        case "wind":                 return Color(hex: "#66D4CF")
        default:                     return Color(hex: "#0A84FF")
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let a = displayed {
                card(a)
            }
        }
        .onChange(of: showing) { _, on in
            // 收起态窗口对鼠标隐形，大卡在场时临时解除穿透才点得到（见 NotchViewModel）
            vm.alertBannerVisible = on
            if on {
                displayed = weather.alert
                // 与刘海展开同款节奏：形状 easeOut 0.22 快速长大到位，弹跳由 keyframe 叠加
                withAnimation(.easeOut(duration: 0.22)) { shown = true }
            } else {
                // 与刘海收起同款弹簧缩回刘海里，收完再移除视图
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    shown = false
                } completion: {
                    if !showing { displayed = nil }
                }
            }
        }
        // 展示中换内容（预览连点另一种天气）：只换卡面与光色，不重播出场
        .onChange(of: weather.alert) { _, new in
            if let new, showing { displayed = new }
        }
        .onAppear {
            // 快照/演示路径：视图出现前 alert 已就位，onChange 等不到，直接摆到位
            if showing {
                displayed = weather.alert
                shown = true
                vm.alertBannerVisible = true
            }
        }
    }

    private func card(_ a: WeatherAlert) -> some View {
        let glow = glowColor(a)
        return Button {
            weather.dismissAlert()
            vm.activeTab = .widgets
            vm.expandProgrammatically()
        } label: {
            VStack(spacing: 9) {
                Text("恶劣天气预警")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Self.warnColor)
                    .padding(.horizontal, 10).padding(.vertical, 3.5)
                    .background(Capsule().fill(Self.warnColor.opacity(0.16)))
                HStack(spacing: 14) {
                    Image(systemName: a.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 42))
                    Text(a.title)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(.white)
                }
                if !a.detail.isEmpty {
                    Text(a.detail)
                        .font(.system(size: 13.5))
                        .foregroundColor(.white.opacity(0.55))
                }
                Text("点击查看详情")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 2)
            }
            .padding(.top, vm.notchRect.height + 12)   // 顶部让出摄像头/两侧功能区一条
            .padding(.bottom, 16)
            .frame(width: 440)
            // 放大版刘海形状（与展开面板同一套语言）；描边跟随光晕色
            .background(NotchShape(topRadius: 9, bottomRadius: 24).fill(Color.black))
            .overlay(NotchShape(topRadius: 9, bottomRadius: 24)
                .stroke(glow.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 与刘海展开同一扇「揭示窗」（大梁老师要求动画一致）：窗口从收起态
        // 黑条尺寸平滑扩到整卡，内容钉在终态位置被逐渐揭示，物理上同种运动
        .clipShape(RevealNotchShape(
            width: shown ? 440 : vm.collapsedShapeWidth,
            height: shown ? vm.notchRect.height + 180 : vm.notchRect.height,
            topRadius: shown ? 9 : 6,
            bottomRadius: shown ? 24 : 10))
        // 周边呼吸光晕贴裁剪后的轮廓，颜色随天气（大梁老师：不同天气不同发光）
        .shadow(color: glow.opacity(glowPulse ? 0.75 : 0.4),
                radius: glowPulse ? 30 : 16, y: 5)
        .shadow(color: glow.opacity(glowPulse ? 0.4 : 0.18),
                radius: glowPulse ? 75 : 45, y: 10)
        // 刘海展开的同款过冲：唯一一冲 +8%，弹簧滑回（NookX 式 Q 弹）
        .keyframeAnimator(initialValue: CGFloat(1.0), trigger: shown) { view, scale in
            view.scaleEffect(scale, anchor: .top)
        } keyframes: { _ in
            let on = shown
            KeyframeTrack(\.self) {
                LinearKeyframe(CGFloat(1.0), duration: 0.05)
                CubicKeyframe(CGFloat(on ? 1.08 : 1.0), duration: 0.16)
                SpringKeyframe(CGFloat(1.0), duration: 0.34,
                               spring: Spring(duration: 0.34, bounce: 0.25))
            }
        }
        .onAppear {
            glowPulse = false
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}

/// 展开揭示裁剪：在恒定布局（整块面板）内，只露出顶部中央 width×height 的刘海形状。
/// 尺寸与圆角都可动画——「展开」就是这扇窗从刘海尺寸平滑扩到整面板，
/// 内容全程钉在终态位置被逐渐揭示，物理上不可能再横移
private struct RevealNotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(width, height),
                           AnimatablePair(topRadius, bottomRadius))
        }
        set {
            width = newValue.first.first
            height = newValue.first.second
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let window = CGRect(x: rect.midX - width / 2, y: rect.minY,
                            width: min(width, rect.width),
                            height: min(height, rect.height))
        return NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            .path(in: window)
    }
}
