import SwiftUI

/// 额度页：Claude Code 与 Codex 两张卡片，各显示 5 小时窗 / 7 天窗的用量
struct UsageView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        HStack(spacing: 12) {
            QuotaCard(title: "Claude Code", icon: "asterisk", quota: store.claude)
            QuotaCard(title: "Codex", icon: "chevron.left.forwardslash.chevron.right", quota: store.codex)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {   // 居中悬于两卡上方——全局刷新，不偏向任何一张卡
            Button {
                store.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(store.refreshing ? 0.25 : 0.55))
                    .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                    .animation(store.refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: store.refreshing)
            }
            .buttonStyle(.plain)
            .disabled(store.refreshing)
            .help("刷新全部额度")
            .padding(.top, 4)
        }
        .onAppear { store.refresh() }
    }
}

/// 单个服务的额度卡片
private struct QuotaCard: View {
    let title: String
    let icon: String
    let quota: ServiceQuota?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                if let plan = quota?.plan, !plan.isEmpty {
                    Text(planLabel(plan))
                        .font(.system(size: 9.5, weight: .semibold)).foregroundColor(.cyan)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.cyan.opacity(0.14)))
                }
                Spacer()
            }
            if let acc = quota?.account, !acc.isEmpty {
                Text(acc).font(.system(size: 9.5)).foregroundColor(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, -6)
            }
            if let q = quota {
                if let err = q.error {
                    Spacer()
                    Text(err).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    if let p = q.primary { WindowRow(label: p.label, window: p, prominent: true) }
                    if let s = q.secondary { WindowRow(label: s.label, window: s, prominent: false) }
                    Spacer(minLength: 0)
                    if let at = q.dataAt {
                        Text("数据 \(Self.ago(at))\(q.primary?.isEstimate == true ? " · ≈本地估算" : " · 官方数据")")
                            .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.35))
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

    private static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 90 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }
}

/// 一个限额窗口行：进度条 + 百分比 + 重置倒计时
private struct WindowRow: View {
    let label: String
    let window: QuotaWindow
    let prominent: Bool

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
                        Capsule().fill(barColor(pct))
                            .frame(width: max(3, geo.size.width * min(1, pct / 100)))
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
