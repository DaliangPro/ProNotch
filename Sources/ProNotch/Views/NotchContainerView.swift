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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
