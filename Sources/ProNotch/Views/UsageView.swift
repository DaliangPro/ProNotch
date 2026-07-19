import SwiftUI

/// 额度页：Claude Code 与 Codex 两张卡片，各显示 5 小时窗 / 7 天窗的用量
struct UsageView: View {
    @EnvironmentObject var store: UsageStore
    /// 出场动画开关：三卡错落浮入，进度条随后从 0 充能到当前值
    @State private var entrancePlayed = false

    var body: some View {
        HStack(spacing: 12) {
            let cards = [("Claude Code", BrandIconPaths.claude, store.claude),
                         ("Codex", BrandIconPaths.openai, store.codex),
                         ("Grok", BrandIconPaths.grok, store.grok)]
            ForEach(Array(cards.enumerated()), id: \.offset) { i, card in
                QuotaCard(title: card.0, polys: card.1, quota: card.2,
                          entrancePlayed: entrancePlayed)
                    .offset(y: entrancePlayed ? 0 : 12)
                    .opacity(entrancePlayed ? 1 : 0)
                    .animation(.spring(response: 0.38, dampingFraction: 0.66)
                        .delay(Double(i) * 0.07), value: entrancePlayed)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, ExpandedContentView.pageHInset)   // 左右留白对齐全局基准线
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.refresh() }
        .pageEntrance($entrancePlayed)
    }
}

/// 单个服务的额度卡片
private struct QuotaCard: View {
    let title: String
    let polys: [[CGPoint]]
    let quota: ServiceQuota?
    var entrancePlayed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                BrandIcon(polys: polys)
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 13, height: 13)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                if let plan = quota?.plan, !plan.isEmpty {
                    Text(planLabel(plan))
                        .font(.system(size: 9.5, weight: .semibold)).foregroundColor(.cyan)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.cyan.opacity(0.14)))
                }
                Spacer()
            }
            if let q = quota {
                if let err = q.error {
                    Spacer()
                    Text(err).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    if let p = q.primary {
                        WindowRow(label: p.label, window: p, prominent: true,
                                  entrancePlayed: entrancePlayed)
                    }
                    if let s = q.secondary {
                        WindowRow(label: s.label, window: s, prominent: false,
                                  entrancePlayed: entrancePlayed)
                    }
                    Spacer(minLength: 12)   // 把 Top 3 压到卡片底部（三卡等高，底部自然对齐）
                    if !q.topTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(q.topTasks) { task in
                                HStack(spacing: 6) {
                                    Text(task.name).font(.system(size: 10.5))
                                        .foregroundColor(.white.opacity(0.7)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(Int(task.percentOfTotal.rounded()))%")
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                            }
                        }
                    }
                }
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        default: return raw
        }
    }

}

/// 一个限额窗口行：进度条 + 百分比 + 重置倒计时
private struct WindowRow: View {
    let label: String
    let window: QuotaWindow
    let prominent: Bool
    var entrancePlayed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: prominent ? 11 : 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                if let pct = window.usedPercent {
                    Text("\(window.isEstimate ? "≈" : "")\(Int(pct.rounded()))%")
                        .font(.system(size: prominent ? 20 : 13, weight: .bold, design: .rounded))
                        .foregroundColor(barColor(pct))
                } else if let t = window.usedTokens {
                    Text(Self.tokenText(t))
                        .font(.system(size: prominent ? 16 : 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            if let pct = window.usedPercent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        // 出场充能：从 0 涨到当前值；数据刷新时 pct 变化不受此动画影响
                        Capsule().fill(barColor(pct))
                            .frame(width: max(3, geo.size.width * min(1, pct / 100)
                                                 * (entrancePlayed ? 1 : 0)))
                            .animation(.easeOut(duration: 0.55).delay(0.18),
                                       value: entrancePlayed)
                    }
                }
                .frame(height: prominent ? 6 : 4)
            }
            if let r = window.resetsAt, r > Date() {
                Text("重置于 \(Self.resetText(r))")
                    .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private func barColor(_ pct: Double) -> Color {
        if pct >= 85 { return Color(hex: "#FF453A") }
        if pct >= 60 { return Color(hex: "#FF9F0A") }
        return .cyan
    }

    private static func tokenText(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM tokens", Double(t) / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK tokens", Double(t) / 1_000) }
        return "\(t) tokens"
    }

    private static func resetText(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s < 3600 { return "\(max(1, s / 60)) 分钟后" }
        if s < 86400 { return "\(s / 3600) 小时 \(s % 3600 / 60) 分后" }
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
}
