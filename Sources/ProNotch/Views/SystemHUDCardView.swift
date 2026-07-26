import SwiftUI

/// 音量 / 亮度提示卡：顶替系统那块弹在屏幕正中的半透明方块。
///
/// 外壳复用 `NotchGrownCard`（与天气预警、Agent 拍板卡同一套「从刘海长出来」的语言），
/// 但关掉了呼吸光晕——那是提醒类卡片的语汇，音量条 1.5 秒就走，
/// 一秒钟的呼吸看着只会像在抖。
///
/// 卡宽刻意只比收起态黑条宽一点点（`extraWidth`）：调音量是个高频小动作，
/// 每按一下就整块大幅张开会很吵。于是横向几乎不动、只往下长出一条，
/// 观感是「刘海自己把提示托出来」而不是「弹出一张卡」。
struct SystemHUDCardView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var hud: SystemHUDStore

    /// 退场动画期间仍要有东西可画，与 store 的 reading 解耦（与两种大卡同一套写法）
    @State private var displayed: SystemHUDStore.Reading?
    @State private var shown = false

    /// 比收起态黑条宽出多少。留一点点，进度条两端才不至于顶到圆角直壁上
    private static let extraWidth: CGFloat = 36
    /// 卡在刘海下方伸出多高：上留白 8 + 内容 22 + 下留白 14。
    /// 必须与卡面自算高度**分毫不差**——揭示裁剪的终态窗口用的是这个数，
    /// 大了会在卡底下留一条空窗（光晕/阴影贴的是裁剪轮廓，会跟着虚出去一截），
    /// 小了直接把卡的底边圆角削平
    private static let grownHeight: CGFloat = 8 + 22 + 14

    /// 展开态不显示——面板都开着了，没必要再挂卡（与两种大卡同口径）
    private var showing: Bool { hud.reading != nil && !vm.isExpanded }

    private var cardWidth: CGFloat { vm.collapsedShapeWidth + Self.extraWidth }

    var body: some View {
        ZStack(alignment: .top) {
            if let r = displayed {
                card(r)
            }
        }
        .onChange(of: showing) { _, on in
            if on {
                displayed = hud.reading
                withAnimation(NotchGrownCardMotion.grow) { shown = true }
            } else {
                withAnimation(NotchGrownCardMotion.shrink) { shown = false } completion: {
                    if !showing { displayed = nil }
                }
            }
        }
        // 连按只换值不重播出场：卡稳稳停着，只有条在动
        .onChange(of: hud.reading) { _, new in
            if let new, showing {
                withAnimation(.easeOut(duration: 0.12)) { displayed = new }
            }
        }
        .onAppear {
            // 离屏渲染路径：视图上树前 reading 已就位，onChange 等不到，直接摆到位
            if showing {
                displayed = hud.reading
                shown = true
            }
        }
    }

    private func card(_ r: SystemHUDStore.Reading) -> some View {
        NotchGrownCard(width: cardWidth, grownHeight: Self.grownHeight,
                       glow: .clear, shown: shown,
                       topGap: 8, bottomGap: 14, glowPulses: false, action: nil) {
            HStack(spacing: 12) {
                Image(systemName: r.symbolName)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    // 图标随档位换字形（喇叭的波纹数、太阳的芒长），宽度却不能跟着变，
                    // 否则进度条的左端会随音量高低左右横跳。定宽 18 把这一路钉死
                    .frame(width: 18)
                bar(r)
                Text("\(r.percent)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 24, alignment: .trailing)
            }
            .frame(height: 22)
            .padding(.horizontal, NotchGrownCardMetrics.horizontalInset)
        }
    }

    private func bar(_ r: SystemHUDStore.Reading) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                // 极小值也留一截可见的圆头，不然「1%」看着和 0 一样
                Capsule().fill(Color.white.opacity(0.92))
                    .frame(width: max(r.fill > 0 ? 6 : 0, geo.size.width * r.fill))
            }
        }
        .frame(height: 6)
    }
}
