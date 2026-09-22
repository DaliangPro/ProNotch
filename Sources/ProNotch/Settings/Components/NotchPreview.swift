import SwiftUI

/// 刘海收起态的真实预览：屏幕顶部一条菜单栏、中间黑色胶囊、两侧槽位按真实样式渲染
///（内存环、天气图标加气温、时钟），改左右槽位立刻看到效果。
/// 此前那版是黑条上两个文字下拉，大梁老师觉得太抽象。
///
/// 内容渲染与 `CollapsedSlotsView` 同一套口径（环 21pt、字号、间距），只是不依赖 NotchViewModel；
/// 内存用一次性读数，天气取设置窗环境里那份 WeatherStore 的当前值，时钟按所选时区走真实时间
struct NotchPreview: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var weather: WeatherStore
    @StateObject private var memory = MemoryStore()

    /// 与真实收起态同比例：物理刘海 150、单侧槽位 56、高 30
    private let notchWidth: CGFloat = 150
    private let sideWidth: CGFloat = NotchSlot.fixedSideWidth
    private let pillHeight: CGFloat = 30
    private let barHeight: CGFloat = 30

    var body: some View {
        ZStack(alignment: .top) {
            // 屏幕：上面一条菜单栏，下面露一点桌面
            VStack(spacing: 0) {
                menuBar.frame(height: barHeight)
                Color.clear.frame(height: 24)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.notchStrip))
            pill
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { memory.refresh() }
    }

    /// 假菜单栏：只为让人认出「这是屏幕顶部」，内容故意灰淡
    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 11))
            Text("访达").font(.system(size: 11, weight: .semibold))
            Text("文件").font(.system(size: 11))
            Text("编辑").font(.system(size: 11))
            Text("显示").font(.system(size: 11))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 10))
            Image(systemName: "battery.100").font(.system(size: 11))
            Text("周一 14:32").font(.system(size: 11))
        }
        .foregroundColor(.white.opacity(0.45))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
    }

    /// 黑色胶囊：两侧都关时只有物理刘海那么宽；任一侧开启即两侧对称加宽（与真实一致）
    private var pill: some View {
        let active = settings.sideSlotsActive
        return HStack(spacing: 0) {
            if active {
                slot(settings.leftSlot)
                    .frame(width: sideWidth, alignment: .center)
                    .padding(.trailing, NotchSlot.leadingPad)
            }
            Color.clear.frame(width: notchWidth)
            if active {
                slot(settings.rightSlot)
                    .padding(.leading, NotchSlot.leadingPad)
                    .frame(width: sideWidth, alignment: .leading)
            }
        }
        .frame(height: pillHeight)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
            .fill(Color.black))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: active)
    }

    @ViewBuilder private func slot(_ s: NotchSlot) -> some View {
        switch s {
        case .none: Color.clear
        case .memory: memorySlot
        case .weather: weatherSlot
        case .clock: clockSlot
        }
    }

    private static let ringWidth: CGFloat = 2.5

    private var memorySlot: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: Self.ringWidth)
            if let s = memory.snapshot {
                Circle().inset(by: Self.ringWidth / 2)
                    .trim(from: 0, to: min(1, s.usedPercent / 100))
                    .stroke(s.loadColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(s.usedPercent.rounded()))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .minimumScaleFactor(0.7)
            } else {
                Text("--").font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(width: 21, height: 21)
    }

    private var clockSlot: some View {
        TimelineView(.everyMinute) { ctx in
            Text(ClockFormatter.text(for: ctx.date, zone: settings.clockZone.timeZone))
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(.white.opacity(0.92))
                .frame(width: NotchSlot.clockWidth)
        }
    }

    private var weatherSlot: some View {
        HStack(spacing: 4) {
            if let w = weather.now {
                Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 11))
                Text("\(Int(w.temperature.rounded()))°")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            } else {
                Image(systemName: "cloud").font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
                Text("--").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}
