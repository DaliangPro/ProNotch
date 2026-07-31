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

    /// 当前可见的黑形状（收起态刘海条 / 展开态整块面板）。裁剪与命中区共用一份，
    /// 免得两处参数各写一遍、日后改圆角只改一处漏另一处
    private var revealShape: RevealNotchShape {
        RevealNotchShape(width: shapeWidth, height: shapeHeight,
                         topRadius: vm.isExpanded ? 12 : 6,
                         bottomRadius: vm.isExpanded ? 20 : 10)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 两种大卡垫底：从刘海形状背后弹出（形状不透明，缩回即被盖住），
            // 层级在黑形状之下，滑动过程天然是「刘海绽放成一块大卡」
            WeatherAlertCardView()
            AgentWaitCardView()
            SystemHUDCardView()
            notchLayer
            // 两侧功能区（左内存右天气）压在最上层，而不是塞在 notchLayer 里面：
            // 那一层被 `clipShape(revealShape)` 裁到收起态黑条宽（312pt），
            // 图标一旦随大卡张开往外走就会被整块裁掉。搬到最上层后，
            // 收起态它落在黑条上、大卡张开时落在卡的顶部留白带里，都不会被裁。
            // 必须保持 `allowsHitTesting(false)`：它盖着卡的整条顶部，
            // 接管点击就会把「点卡跳终端」吃掉
            CollapsedSlotsView()
                .opacity(vm.isExpanded ? 0 : 1)
                .animation(vm.isExpanded ? .easeIn(duration: 0.1)
                                         : .easeOut(duration: 0.15).delay(0.2),
                           value: vm.isExpanded)
                .allowsHitTesting(false)
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
        }
        // 布局恒定为展开尺寸，「长大」只发生在下面的裁剪窗口——布局若随形状一起长，
        // 常驻内容会在动画期间被钉到形状左缘、随扩张从左滑入 380pt
        //（实测 geometry 轨迹 minX 424→44），这正是「展开时图标从左到右出现」的元凶
        .frame(width: vm.expandedShapeSize.width,
               height: vm.expandedShapeSize.height,
               alignment: .top)
        .clipShape(revealShape)
        // 命中区必须跟着可见形状一起收：`clipShape` **只裁画面、不裁点击**，
        // 上面那块 Color.black 的布局恒为整块面板尺寸，被裁掉看不见的那片黑照样把落在
        // 「刘海以下」的点击全吃光——垫在黑形状底下的两种大卡（天气预警、Agent 等你拍板）
        // 因此一个按钮都点不动（实测：整卡区域合成点击全被吞，见 probeGrownCardHits）。
        // 收起态收到刘海条后，刘海以下的空白才让给大卡；展开态形状即整面板，行为不变
        .contentShape(revealShape)
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
    /// 正在展示的内容：退场动画期间仍要有东西可画，与 store 的 alert 解耦
    @State private var displayed: WeatherAlert?
    /// 出场/退场开关：驱动揭示裁剪与过冲弹跳，节奏对齐刘海展开
    @State private var shown = false

    /// 预警橙：标签底色恒定用它，光晕才随天气变——标签管「这是预警」，光晕管「是哪种」
    private static let warnColor = Color(hex: "#FF9F0A")

    /// 卡宽。抽成常量是因为两侧小图标要随卡张开外移到卡的两边（见 `NotchViewModel.grownCardWidth`）
    static let cardWidth: CGFloat = 440

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
                // 卡宽登记进 vm 并放在同一条动画事务里：两侧小图标靠它随卡张开一起外移
                withAnimation(NotchGrownCardMotion.grow) {
                    shown = true
                    vm.alertCardWidth = Self.cardWidth
                }
            } else {
                // 缩回刘海里，收完再移除视图
                withAnimation(NotchGrownCardMotion.shrink) {
                    shown = false
                    vm.alertCardWidth = 0
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
                vm.alertCardWidth = Self.cardWidth
            }
        }
    }

    private func card(_ a: WeatherAlert) -> some View {
        // 点一下就是关掉它，不再顺手展开刘海到组件页（大梁老师 2026-07-31 定的分工）：
        // 天气是「告诉你一声」，看完即弃；只有「有人在等你」那类才需要把你送到能处理的地方
        NotchGrownCard(width: Self.cardWidth, grownHeight: 180, glow: glowColor(a), shown: shown) {
            weather.dismissAlert()
        } content: {
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
        }
    }
}
