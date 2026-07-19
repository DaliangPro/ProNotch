import SwiftUI

extension MemorySnapshot {
    /// 占用压力配色（组件卡与收起态 slot 共用）：60 橙、85 红预警，与额度页同语言
    var loadColor: Color {
        if usedPercent >= 85 { return Color(hex: "#FF453A") }
        if usedPercent >= 60 { return Color(hex: "#FF9F0A") }
        return .cyan
    }
}

/// 组件页：整机内存 + 实时天气两张卡（与额度页同设计语言，后续新组件的家）
struct WidgetsView: View {
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var weather: WeatherStore
    @EnvironmentObject var vm: NotchViewModel
    /// 看着页面时数据自己动：内存与排行 3 秒一刷；天气走 store 内置 15 分钟节流
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    /// 出场动画开关：两卡错落浮入（额度页同款节奏）
    @State private var entrancePlayed = false

    var body: some View {
        HStack(spacing: 12) {
            MemoryCard(snapshot: memory.snapshot, top: memory.topProcesses,
                       entrancePlayed: entrancePlayed)
                .offset(y: entrancePlayed ? 0 : 12)
                .opacity(entrancePlayed ? 1 : 0)
                .animation(.spring(response: 0.38, dampingFraction: 0.66), value: entrancePlayed)
            WeatherCard(now: weather.now, error: weather.error,
                        entrancePlayed: entrancePlayed)
                .offset(y: entrancePlayed ? 0 : 12)
                .opacity(entrancePlayed ? 1 : 0)
                .animation(.spring(response: 0.38, dampingFraction: 0.66).delay(0.07),
                           value: entrancePlayed)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, ExpandedContentView.pageHInset)   // 左右留白对齐全局基准线
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            memory.refresh()
            memory.refreshTopProcesses()
            weather.refresh()
        }
        .onReceive(ticker) { _ in
            guard vm.isExpanded, vm.activeTab == .widgets else { return }
            memory.refresh()
            memory.refreshTopProcesses()
            weather.refresh()
        }
        .pageEntrance($entrancePlayed)
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
                // App 占用排行：谁在吃内存一目了然（活动监视器 phys_footprint 口径）。
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
                // 逐时预报：未来 6 小时——紧贴焦点行的窄条，不吃纵向空间（大梁老师定）
                HStack(spacing: 0) {
                    ForEach(w.hourly) { h in
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
                    }
                }
                CardRule()
                // 5 天预报（大梁老师：与其留白不如填内容）：五行均分弹性区，
                // 行高封顶 44 防天数少时拉太开
                VStack(spacing: 0) {
                    ForEach(w.days) { d in
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
                    }
                }
                .frame(maxHeight: .infinity)
                CardRule()
                // 底行四指标：湿度 / 风速 / 日出 / 日落
                HStack(spacing: 0) {
                    bottomMetric("湿度", "\(w.humidity)%")
                    bottomMetric("风速", String(format: "%.0f km/h", w.windSpeed))
                    bottomMetric("日出", w.sunrise.isEmpty ? "--" : w.sunrise)
                    bottomMetric("日落", w.sunset.isEmpty ? "--" : w.sunset)
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
