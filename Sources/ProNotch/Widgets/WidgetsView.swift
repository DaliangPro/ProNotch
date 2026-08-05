import SwiftUI

extension MemorySnapshot {
    /// 占用压力配色（组件卡与收起态 slot 共用）：60 橙、85 红预警，与额度页同语言
    var loadColor: Color {
        if usedPercent >= 85 { return Color(hex: "#FF453A") }
        if usedPercent >= 60 { return Color(hex: "#FF9F0A") }
        return .cyan
    }
}

/// 组件页：整机内存 + 实时天气 + 世界时钟（与额度页同设计语言，后续新组件的家）
struct WidgetsView: View {
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var weather: WeatherStore
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: SettingsStore
    /// 看着页面时数据自己动：内存与排行 3 秒一刷；天气走 store 内置 15 分钟节流
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    /// 出场动画开关：各卡错落浮入（额度页同款节奏）
    @State private var entrancePlayed = false
    /// 时钟卡当前时刻。跟着页面既有的 3 秒心跳走，不单开定时器
    @State private var now = Date()

    var body: some View {
        HStack(spacing: 12) {
            // 只淡入、不上浮：进度条出场只保留从左往右充能，去掉跟随卡片的竖直位移
            // 卡片按各自「内部开关」显隐；关掉的卡不上树也不刷新（真停机）
            if settings.memoryWidgetEnabled {
                MemoryCard(snapshot: memory.snapshot, top: memory.topProcesses,
                           entrancePlayed: entrancePlayed)
                    .opacity(entrancePlayed ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: entrancePlayed)
            }
            if settings.weatherWidgetEnabled {
                WeatherCard(now: weather.now, error: weather.error,
                            entrancePlayed: entrancePlayed)
                    .opacity(entrancePlayed ? 1 : 0)
                    .animation(.easeOut(duration: 0.3).delay(0.07), value: entrancePlayed)
            }
            if settings.clockWidgetEnabled {
                WorldClockCard(now: now, zones: settings.clockCardZones,
                               entrancePlayed: entrancePlayed)
                    .opacity(entrancePlayed ? 1 : 0)
                    .animation(.easeOut(duration: 0.3).delay(0.14), value: entrancePlayed)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, ExpandedContentView.pageHInset)   // 左右留白对齐全局基准线
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            now = Date()
            refreshVisible()
        }
        .onReceive(ticker) { _ in
            guard vm.isExpanded, vm.activeTab == .widgets else { return }
            now = Date()
            refreshVisible()
        }
        .pageEntrance($entrancePlayed)
    }

    /// 只刷新正在显示的卡（内部开关关掉的卡不采样，真停机）：内存 refresh 走 host_statistics
    /// ＋进程枚举，天气 refresh 可能走网络，都不该为一张隐藏的卡付出
    private func refreshVisible() {
        if settings.memoryWidgetEnabled {
            memory.refresh()
            memory.refreshTopProcesses()
        }
        if settings.weatherWidgetEnabled {
            weather.refresh()
        }
    }
}

/// 卡片统一底盘（额度页 QuotaCard 同款）
private struct WidgetCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// 卡内分隔线
private struct CardRule: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
    }
}

/// 卡内元素错峰出场（大梁老师：天气卡不能一整块出来）：
/// 上浮 7pt + 淡入，按 delay 排队——与启动台波浪/Agent 页发牌同一节奏语言
private extension View {
    func entranceBit(_ played: Bool, delay: Double) -> some View {
        opacity(played ? 1 : 0)
            .offset(y: played ? 0 : 7)
            .animation(.spring(response: 0.35, dampingFraction: 0.7).delay(delay),
                       value: played)
    }
}

/// 内存卡：占用概览 + 充能进度条 + App 占用排行（大梁老师定）+ 三类明细
private struct MemoryCard: View {
    let snapshot: MemorySnapshot?
    let top: [ProcessMemory]
    var entrancePlayed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("内存").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
                if let s = snapshot {
                    Text("共 \(MemorySnapshot.gb(s.total))")
                        .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                }
            }
            if let s = snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Text("已用 \(MemorySnapshot.gb(s.used))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(s.usedPercent.rounded()))%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(s.loadColor)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        // 出场充能：从 0 涨到当前占用（额度页同款）
                        Capsule().fill(s.loadColor)
                            .frame(width: max(3, geo.size.width * min(1, s.usedPercent / 100)
                                                 * (entrancePlayed ? 1 : 0)))
                            .animation(.easeOut(duration: 0.55).delay(0.18),
                                       value: entrancePlayed)
                    }
                }
                .frame(height: 6)
                Spacer(minLength: 4)
                // App 占用排行：谁在吃内存一目了然。Helper/服务已并入宿主 App 一行
                //（大梁老师定），数值为组内 phys_footprint 加总（活动监视器同口径）。
                // 视口定高 6 行、位置不动，往下滑看其余名次（大梁老师：别铺满，能滑就行）
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(top) { proc in
                            HStack(spacing: 7) {
                                if let icon = proc.icon {
                                    Image(nsImage: icon)
                                        .resizable().frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.35))
                                        .frame(width: 16, height: 16)
                                }
                                Text(proc.name)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer()
                                Text(MemorySnapshot.mem(proc.footprint))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 140)   // 恰好 6 行（16 行高 + 8 间距）
                Spacer(minLength: 4)
                CardRule()
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("App 内存", s.appMemory)
                    detailRow("联动内存", s.wired)
                    detailRow("被压缩", s.compressed)
                }
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .modifier(WidgetCardChrome())
    }

    private func detailRow(_ label: String, _ bytes: UInt64) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            Spacer()
            Text(MemorySnapshot.gb(bytes))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
        }
    }
}

/// 天气卡：当前概览（含体感/降水）+ 逐时 6 小时 + 5 天预报 + 湿度/风/日出日落
private struct WeatherCard: View {
    let now: WeatherNow?
    let error: String?
    var entrancePlayed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text(now?.city.isEmpty == false ? now!.city : "天气")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
                if let w = now {
                    Text(w.text).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                }
            }
            if let w = now {
                // 焦点行：图标 + 大温度；右侧体感与降水概率
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: w.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 30))
                    Text("\(Int(w.temperature.rounded()))°")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("体感 \(Int(w.apparent.rounded()))°")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                        HStack(spacing: 3) {
                            Image(systemName: "drop.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.cyan.opacity(0.7))
                            Text("\(w.precipProb)%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .entranceBit(entrancePlayed, delay: 0.1)
                // 逐时预报：未来 6 小时——紧贴焦点行的窄条，不吃纵向空间（大梁老师定）
                HStack(spacing: 0) {
                    ForEach(Array(w.hourly.enumerated()), id: \.element.id) { i, h in
                        VStack(spacing: 3) {
                            Text(h.hourLabel)
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.45))
                            Image(systemName: h.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 13))
                            Text("\(Int(h.temp.rounded()))°")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity)
                        .entranceBit(entrancePlayed, delay: 0.16 + Double(i) * 0.035)   // 6 列波浪推右
                    }
                }
                CardRule()
                // 5 天预报（大梁老师：与其留白不如填内容）：五行均分弹性区，
                // 行高封顶 44 防天数少时拉太开
                VStack(spacing: 0) {
                    ForEach(Array(w.days.enumerated()), id: \.element.id) { i, d in
                        HStack(spacing: 8) {
                            Text(d.dayLabel)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.75))
                                .frame(width: 36, alignment: .leading)
                            Image(systemName: d.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 14))
                                .frame(width: 20)
                            HStack(spacing: 2) {
                                Image(systemName: "drop.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.cyan.opacity(0.55))
                                Text("\(d.precipProb)%")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.45))
                            }
                            Spacer()
                            Text("\(Int(d.tMin.rounded()))° ~ \(Int(d.tMax.rounded()))°")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .frame(maxHeight: .infinity)
                        .frame(maxHeight: 44)   // 行高封顶：舒展但别拉满
                        .entranceBit(entrancePlayed, delay: 0.3 + Double(i) * 0.05)   // 5 行发牌
                    }
                }
                .frame(maxHeight: .infinity)
                CardRule()
                // 底行四指标：湿度 / 风速 / 日出 / 日落
                let metrics = [("湿度", "\(w.humidity)%"),
                               ("风速", String(format: "%.0f km/h", w.windSpeed)),
                               ("日出", w.sunrise.isEmpty ? "--" : w.sunrise),
                               ("日落", w.sunset.isEmpty ? "--" : w.sunset)]
                HStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { i, m in
                        bottomMetric(m.0, m.1)
                            .entranceBit(entrancePlayed, delay: 0.55 + Double(i) * 0.035)   // 指标收尾
                    }
                }
            } else if let err = error {
                Spacer()
                Text(err).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .modifier(WidgetCardChrome())
    }

    private func bottomMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }
}


/// 世界时钟卡（大梁老师 2026-08-05 定：时钟属于功能组件，与内存/天气同级）。
///
/// 侧栏那个槽位只显一个时区的 HH:mm；这张卡是它的完整形态——
/// 几个城市并排，各自的钟点、日期差、白天黑夜一眼看全。
/// 无数据源、无网络、无采样：时刻由页面心跳传进来，纯计算
private struct WorldClockCard: View {
    let now: Date
    let zones: [ClockZone]
    var entrancePlayed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("世界时钟")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
            }
            if zones.isEmpty {
                Spacer()
                Text("在设置 → 功能组件 → 时钟里添加城市")
                    .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { i, zone in
                        if i > 0 { CardRule() }
                        row(zone)
                            .entranceBit(entrancePlayed, delay: 0.12 + Double(i) * 0.045)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .modifier(WidgetCardChrome())
    }

    private func row(_ zone: ClockZone) -> some View {
        let tz = zone.timeZone
        return HStack(spacing: 8) {
            // 昼夜标：跨时区最要紧的一眼信息——那边现在是不是该睡了
            Image(systemName: Self.isDaytime(now, tz) ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 10))
                .foregroundColor(Self.isDaytime(now, tz)
                                 ? Color(hex: "#FF9F0A").opacity(0.85)
                                 : .white.opacity(0.35))
                .frame(width: 14)
            Text(zone.title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
            Spacer(minLength: 6)
            // 与本地的日期差：跨时区常差一天，不标出来最容易约错时间
            if let delta = Self.dayDeltaText(now, tz) {
                Text(delta)
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.4))
            }
            Text(ClockFormatter.text(for: now, zone: tz))
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }

    /// 6:00–17:59 算白天。粗口径够用——这一栏是给「现在方便不方便找他」一个提示，
    /// 不是天文意义的日出日落
    static func isDaytime(_ date: Date, _ zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        return (6...17).contains(hour)
    }

    /// 相对本地的日期差：明天 / 昨天；同一天返回 nil（不显示）。
    ///
    /// 两个日历日期必须放进**同一个时区**再相减。
    /// 曾经各用各的时区还原成 Date 再算时间差——那样得到的是「两地零点之间的绝对间隔」，
    /// 不是日期差：本地 8/5 与东京 8/5 明明同一天，却因两个零点相差 16 小时被判成「昨天」
    /// （离屏渲染当场看见，2026-08-05）
    static func dayDeltaText(_ date: Date, _ zone: TimeZone) -> String? {
        var here = Calendar(identifier: .gregorian)
        here.timeZone = .current
        var there = Calendar(identifier: .gregorian)
        there.timeZone = zone
        let a = here.dateComponents([.year, .month, .day], from: date)
        let b = there.dateComponents([.year, .month, .day], from: date)
        // 中立日历：把两边的「年月日」当纯日期还原，差多少天就是多少天（跨月跨年同样正确）
        var neutral = Calendar(identifier: .gregorian)
        neutral.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let d1 = neutral.date(from: a), let d2 = neutral.date(from: b),
              let days = neutral.dateComponents([.day], from: d1, to: d2).day else { return nil }
        switch days {
        case 0:  return nil
        case 1:  return "明天"
        case -1: return "昨天"
        default: return days > 0 ? "+\(days) 天" : "\(days) 天"
        }
    }
}


