import SwiftUI
import AppKit

/// 菜单栏额度栏点开的弹出面板：顶部 tab「概览 / Claude / Codex / Grok」，
/// 选中看该服务的进度条 + 已用% + 重置倒计时；底部刷新 / 设置。
/// 逻辑与刘海额度页一致：柱状条显示「已用/消耗了多少」（不是剩余）。
struct UsageMenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}
    @State private var tab = 0   // 0=概览，1…n = 各勾选服务

    private struct Svc { let name: String; let short: String; let polys: [[CGPoint]]; let tint: Color; let quota: ServiceQuota? }
    /// 只列勾选的家（设置 → Agent 每家总开关），与额度页/菜单栏标题同一套过滤
    private var services: [Svc] {
        AgentKind.allCases.filter { settings.enabledAgents.contains($0) }.map {
            Svc(name: $0.displayName, short: $0.shortName, polys: $0.polys,
                tint: $0.tint, quota: store.quota(for: $0))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                // 勾选变少后 tab 可能越界（面板开着时取消勾选）：回落概览
                if tab >= 1, tab <= services.count { detail(services[tab - 1]) } else { overview }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 320)
        .background(VisualEffectBackground(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 顶部 tab
    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(0, "概览") { Image(systemName: "square.grid.2x2").font(.system(size: 15)) }
            ForEach(0..<services.count, id: \.self) { idx in
                let s = services[idx]
                tabButton(idx + 1, s.short) { BrandIcon(polys: s.polys).frame(width: 15, height: 15) }
            }
        }
        .padding(8)
    }

    private func tabButton<Icon: View>(_ i: Int, _ name: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button { tab = i } label: {
            VStack(spacing: 4) {
                icon()
                Text(name).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .foregroundColor(tab == i ? .white : .secondary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tab == i ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 概览：勾选服务简览（已用%）
    private var overview: some View {
        VStack(spacing: 12) {
            if services.isEmpty {
                Text("未勾选要监控的 Agent（设置 → Agent 里勾选）")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            ForEach(0..<services.count, id: \.self) { i in
                let s = services[i]
                HStack(spacing: 8) {
                    BrandIcon(polys: s.polys).foregroundColor(s.tint).frame(width: 13, height: 13).frame(width: 16)
                    Text(s.name).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    if let w = overviewWindow(s.quota), let used = w.usedPercent {
                        Text("\(w.label) · \(pct(used))% 已用")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(barColor(used))
                    } else {
                        Text(s.quota?.error != nil ? "无数据" : "—").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                if let w = overviewWindow(s.quota), let used = w.usedPercent { bar(used) }
            }
        }
    }

    // MARK: - 单服务详情（已用%）
    @ViewBuilder private func detail(_ s: Svc) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.name.replacingOccurrences(of: " Code", with: ""))
                        .font(.system(size: 18, weight: .semibold))
                    if let plan = s.quota?.plan, !plan.isEmpty {
                        Text(plan).font(.system(size: 10, weight: .semibold)).foregroundColor(s.tint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(s.tint.opacity(0.15)))
                    }
                }
                Text(updatedText(s.quota)).font(.system(size: 11)).foregroundColor(.secondary)
            }
            if let err = s.quota?.error {
                Text(err).font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                // 该服务的所有额度窗口都列出（Claude/Codex：5 小时 + 7 天；Grok：仅周）
                let windows = [s.quota?.primary, s.quota?.secondary].compactMap { $0 }
                if windows.isEmpty {
                    Text("读取中…").font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                        windowBlock(w)
                    }
                }
            }
        }
    }

    /// 单个额度窗口小节：标题（如「7 天额度」）+ 柱状条 + 已用% + 重置倒计时
    @ViewBuilder private func windowBlock(_ w: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(w.label)额度").font(.system(size: 14, weight: .medium))
            if let used = w.usedPercent {
                bar(used)
                HStack {
                    Text("\(w.isEstimate ? "≈" : "")\(pct(used))% 已用")
                        .font(.system(size: 12.5, weight: .medium)).foregroundColor(barColor(used))
                    Spacer()
                    if let r = w.resetsAt, r > Date() {
                        Text("\(resetText(r)) 后重置").font(.system(size: 11.5)).foregroundColor(.secondary)
                    }
                }
            } else {
                Text("暂无数据").font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 底部菜单
    private var footer: some View {
        VStack(spacing: 0) {
            menuButton("刷新额度", "arrow.clockwise", "R") { onRefresh() }
            menuButton("设置…", "gearshape", ",") { onSettings() }
        }
        .padding(.vertical, 4)
    }

    private func menuButton(_ title: String, _ icon: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 12.5))
                Spacer()
                Text("⌘\(key)").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 辅助
    /// 概览优先显示「周额度」——5 小时窗恢复快，周额度才是真正的用量上限
    private func overviewWindow(_ q: ServiceQuota?) -> QuotaWindow? { q?.secondary ?? q?.primary }
    private func pct(_ used: Double) -> Int { min(100, max(0, Int(used.rounded()))) }

    /// 柱状条填充「已用量」——与刘海额度页一致
    private func bar(_ used: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(barColor(used))
                    .frame(width: max(3, geo.size.width * min(1, max(0, used) / 100)))
            }
        }
        .frame(height: 6)
    }

    /// 已用越多越告急（同刘海：低=青、60%+=橙、85%+=红）
    private func barColor(_ used: Double) -> Color {
        if used >= 85 { return Color(hex: "#FF453A") }
        if used >= 60 { return Color(hex: "#FF9F0A") }
        return .cyan
    }

    private func updatedText(_ q: ServiceQuota?) -> String {
        guard let at = q?.dataAt else { return "尚未获取" }
        let s = Int(Date().timeIntervalSince(at))
        if s < 60 { return "刚刚更新" }
        if s < 3600 { return "\(s / 60) 分钟前更新" }
        return "\(s / 3600) 小时前更新"
    }

    private func resetText(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s < 3600 { return "\(max(1, s / 60)) 分钟" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

/// 原生毛玻璃背景（NSVisualEffectView）：系统菜单材质，半透明模糊，替代纯色
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
