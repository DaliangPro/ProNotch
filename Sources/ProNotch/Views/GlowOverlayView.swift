import Foundation
import SwiftUI

/// 屏幕四周向内渗透的柔光，带正弦呼吸 + 淡入淡出。
/// 颜色 / 周期 / 强度 / 厚度来自 `GlowController`；`allowsHitTesting(false)` 再加一层穿透保险。
struct GlowOverlayView: View {
    @EnvironmentObject private var glow: GlowController

    var body: some View {
        GeometryReader { geo in
            if let color = glow.activeColor {
                // breath（呼吸相位）与 envelope（淡入淡出）都由 GlowController 的定时器驱动。
                // pow(breath, 1.4) 让谷值归零、强调暗部，「灭→涨亮→灭」更分明；乘 envelope 做柔和出现/消失。
                edgeGlow(color: color, thickness: CGFloat(glow.thickness))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(glow.intensity * pow(glow.breath, 1.4) * glow.envelope)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 四条边各一道向内渐隐的渐变，四角自然叠加成柔和暗角光圈。
    @ViewBuilder
    private func edgeGlow(color: Color, thickness: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            LinearGradient(colors: [color, color.opacity(0)], startPoint: .bottom, endPoint: .top)
                .frame(height: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            LinearGradient(colors: [color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            LinearGradient(colors: [color, color.opacity(0)], startPoint: .trailing, endPoint: .leading)
                .frame(width: thickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .compositingGroup()
        .blur(radius: 16)
    }
}
