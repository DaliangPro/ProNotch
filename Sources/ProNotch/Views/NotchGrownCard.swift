import SwiftUI

/// 「从刘海长出来的一块大卡」这套外壳：出场/收回与刘海展开完全同一套动画
/// （揭示裁剪 + 单次过冲弹跳，大梁老师要求对齐），外加一圈呼吸光晕。
///
/// 抽出来是因为现在有两种卡共用它：恶劣天气预警、Agent 等你拍板。
/// 此前这套动画参数（0.22 easeOut、+8% 过冲、1.1s 呼吸）散在天气预警卡里，
/// 第二种卡照抄一遍就等于抄了一份要同步维护的动画副本——大梁老师要求两者观感一致，
/// 那就只能是同一份代码。
struct NotchGrownCard<Content: View>: View {
    /// 卡宽（天气 440；Agent 提醒窄一些）
    let width: CGFloat
    /// 卡在刘海下方伸出的高度（不含刘海本身那条）
    let grownHeight: CGFloat
    /// 光晕与描边颜色
    let glow: Color
    /// 出场/退场开关：true 时长出来
    let shown: Bool
    /// 内容与卡壳顶边的间距（顶部另加一条刘海条高度，让出摄像头/两侧功能区）。
    /// 默认 12 是天气预警卡的原值；要四边等距的卡传 `NotchGrownCardMetrics.inset`
    var topGap: CGFloat = 12
    /// 内容与卡壳底边的间距。默认 16 同上
    var bottomGap: CGFloat = 16
    /// 整卡点击。nil＝卡里自己有按钮——套一层 Button 会跟里面的按钮抢事件
    let action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @EnvironmentObject private var vm: NotchViewModel
    /// 周边光晕呼吸相位（大梁老师：提醒必须让人看见）
    @State private var glowPulse = false

    private var face: some View {
        let shape = NotchShape(topRadius: NotchGrownCardMetrics.topRadius,
                               bottomRadius: NotchGrownCardMetrics.bottomRadius)
        return content()
            .padding(.top, vm.notchRect.height + topGap)
            .padding(.bottom, bottomGap)
            .frame(width: width)
            // 放大版刘海形状（与展开面板同一套语言）；描边跟随光晕色
            .background(shape.fill(Color.black))
            .overlay(shape.stroke(glow.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { face }.buttonStyle(.plain)
            } else {
                face
            }
        }
        // 与刘海展开同一扇「揭示窗」：窗口从收起态黑条尺寸平滑扩到整卡，
        // 内容钉在终态位置被逐渐揭示，物理上同种运动
        .clipShape(RevealNotchShape(
            width: shown ? width : vm.collapsedShapeWidth,
            height: shown ? vm.notchRect.height + grownHeight : vm.notchRect.height,
            topRadius: shown ? NotchGrownCardMetrics.topRadius : 6,
            bottomRadius: shown ? NotchGrownCardMetrics.bottomRadius : 10))
        // 周边呼吸光晕贴裁剪后的轮廓
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

/// 大卡的几何口径（对称是设计前提，大梁老师定：「协调对称这种美很重要」）。
///
/// 关键一条是**同心圆角**：卡内元素的圆角取 `bottomRadius - inset`，
/// 于是它左下/右下角的圆心与卡壳圆角的圆心**重合**，两条弧之间的间距处处等于 `inset`——
/// 与左右直边、底部直边的留白完全相同。此前按钮圆角 9 配边距 16，圆心差 1.4pt，
/// 角上实际净空只有 13.6pt 而直边是 16pt，这正是大梁老师说的
/// 「按钮的 R 角和刘海弹出来的 R 角感觉比例不协调」。
///
/// 放在非泛型 enum 里而不是 `NotchGrownCard` 的 static 成员：后者是泛型，
/// 取常量得写成 `NotchGrownCard<AnyView>.inset`，调用处会很难看
enum NotchGrownCardMetrics {
    static let topRadius: CGFloat = 9
    static let bottomRadius: CGFloat = 24
    /// 内容到卡壳三边（左、右、下）的**可见**留白
    static let inset: CGFloat = 14

    /// 内容的左右边距（按名义宽度给）。
    ///
    /// 刘海形状的竖直壁并不在名义边缘上，而是缩进 `topRadius`（上角是外扩的圆角，
    /// 名义宽度只是顶边宽度，见 `NotchShape.path`）。所以左右要多让出这一截，
    /// 可见留白才等于 `inset`。离屏渲染实测过：此前左右按 16 给，可见留白只剩 7pt，
    /// 而底部实打实 16pt——这正是大梁老师说的「左右下三边，它的留白不一致」
    static let horizontalInset: CGFloat = topRadius + inset

    /// 卡内元素（按钮、详情块）的圆角：与卡壳底圆角**同心**。
    /// 壳角圆心 (topRadius + bottomRadius, H - bottomRadius)、
    /// 按钮角圆心 (horizontalInset + innerRadius, H - inset - innerRadius) 两点重合，
    /// 于是角上净空与三边直边留白处处相等
    static let innerRadius: CGFloat = bottomRadius - inset
}

/// 大卡出场/收回的节奏（两种卡共用，大梁老师要求观感一致）：
/// 长出来用 easeOut 0.22 快速到位（弹跳由 keyframe 叠加），缩回去用弹簧钻回刘海里
enum NotchGrownCardMotion {
    static let grow = Animation.easeOut(duration: 0.22)
    static let shrink = Animation.spring(response: 0.35, dampingFraction: 0.9)
}

/// 展开揭示裁剪：在恒定布局（整块面板）内，只露出顶部中央 width×height 的刘海形状。
/// 尺寸与圆角都可动画——「展开」就是这扇窗从刘海尺寸平滑扩到整面板，
/// 内容全程钉在终态位置被逐渐揭示，物理上不可能再横移
struct RevealNotchShape: Shape {
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
