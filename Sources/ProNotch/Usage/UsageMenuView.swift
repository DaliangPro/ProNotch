import SwiftUI

/// 菜单栏下拉里的额度详情：Claude / Codex 两行，各带 5 小时 + 7 天进度条。
/// 用于 NSMenuItem 的 hosting view，宽度固定，深色卡片风格
struct UsageMenuView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 8) {
            MenuServiceRow(title: "Claude Code", quota: store.claude)
            Divider().overlay(Color.primary.opacity(0.12))
            MenuServiceRow(title: "Codex", quota: store.codex)
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct MenuServiceRow: View {
    let title: String
    let quota: ServiceQuota?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let plan = quota?.plan, !plan.isEmpty {
                    Text(planLabel(plan)).font(.system(size: 9, weight: .semibold)).foregroundColor(.cyan)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                Spacer()
                if let acc = quota?.account, !acc.isEmpty {
                    Text(acc).font(.system(size: 9)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 130, alignment: .trailing)
                }
            }
            if let err = quota?.error {
                Text(err).font(.system(size: 10.5)).foregroundColor(.secondary)
            } else if let q = quota {
                if let p = q.primary { MenuBar(label: p.label, w: p) }
                if let s = q.secondary { MenuBar(label: s.label, w: s) }
            } else {
                Text("读取中…").font(.system(size: 10.5)).foregroundColor(.secondary)
            }
        }
    }

    private func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"; case "plus": return "Plus"
        default: return raw
        }
    }
}

private struct MenuBar: View {
    let label: String
    let w: QuotaWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    if let pct = w.usedPercent {
                        Capsule().fill(color(pct)).frame(width: max(3, geo.size.width * min(1, pct / 100)))
                    }
                }
            }
            .frame(height: 5)
            Group {
                if let pct = w.usedPercent {
                    Text("\(w.isEstimate ? "≈" : "")\(Int(pct.rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(color(pct))
                } else if let t = w.usedTokens {
                    Text(tokenText(t)).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.secondary)
                } else {
                    Text("—").foregroundColor(.secondary)
                }
            }
            .frame(width: 46, alignment: .trailing)
        }
    }

    private func color(_ pct: Double) -> Color {
        if pct >= 85 { return Color(hex: "#FF453A") }
        if pct >= 60 { return Color(hex: "#FF9F0A") }
        return .cyan
    }
    private func tokenText(_ t: Int) -> String {
        t >= 1_000_000 ? String(format: "%.1fM", Double(t) / 1e6) : t >= 1000 ? "\(t / 1000)K" : "\(t)"
    }
}
