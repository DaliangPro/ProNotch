import SwiftUI

/// Agent：四家一排磁贴点亮即监控；完成提醒一个总开关决定要不要、一个二选一决定哪种、
/// 只展开选中方式的细节；提醒哪些家用选片；额度一行
struct AgentPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var glow: GlowController

    @State private var probeResults: [AgentProbeResult] = []   // 本地 Agent 检测结果（进页 / 点扫描时刷新）
    @State private var discoveredTools: [DiscoveredTool] = []  // 认识但暂无监控能力的工具（仅展示）
    @State private var colorPopover = false

    /// 只列扫描发现的家（大梁老师定：没装就不出现选项）；已勾选但本体已卸载的仍显示，
    /// 留住关闭入口——否则它会在额度面板里留一个「无数据」的幽灵 tab 没处关
    private var visible: [AgentProbeResult] {
        probeResults.filter { $0.installed || settings.enabledAgents.contains($0.kind) }
    }

    /// 能配完成提醒的家：已监控且支持钩子。没点亮的家不出现在选片里（不灰显）
    private var alertKinds: [AgentKind] {
        AgentKind.allCases.filter { $0.supportsGlow && settings.enabledAgents.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "Agent")

            SettingsSectionHeader(text: "本地 Agent") {
                TextButton(title: "重新扫描") { rescan() }
            }
            if visible.isEmpty {
                SettingsCard {
                    Text("未检测到支持的 AI 编码工具（Claude Code / Codex / Grok / Kimi Code）")
                        .font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(visible) { r in
                        let on = settings.enabledAgents.contains(r.kind)
                        SettingsTile(title: r.kind.displayName, isOn: on, action: { toggle(r.kind) }) {
                            BrandIcon(polys: r.kind.polys)
                                .foregroundColor(r.kind.tint)
                                .frame(width: 14, height: 14)
                                .opacity(on ? 1 : 0.4)
                        }
                        .help(status(r))
                    }
                }
            }
            if !discoveredTools.isEmpty {
                SettingsNote(text: "另检测到 \(discoveredTools.map(\.name).joined(separator: "、"))，暂不支持")
            }

            SectionLabel(text: "完成提醒")
            SettingsCard {
                // 总开关与刘海面板上的「Agent 提醒」按钮是同一个 glowEnabled
                SettingsRow(title: "完成时提醒") { ThemedSwitch(isOn: $settings.glowEnabled) }
                if settings.glowEnabled {
                    CardDivider()
                    SettingsRow(title: "方式") {
                        SegmentedPicker(options: AgentAlertStyle.allCases, title: { $0.title },
                                        selection: $settings.agentAlertStyle)
                    }
                    if settings.agentAlertStyle == .glow {
                        CardDivider()
                        SettingsSlider(title: "呼吸周期", value: $settings.glowBreathPeriod, range: 1.5...6,
                                       display: String(format: "%.1f 秒", settings.glowBreathPeriod))
                        SettingsSlider(title: "强度", value: $settings.glowIntensity, range: 0.3...1,
                                       display: "\(Int(settings.glowIntensity * 100))%")
                        SettingsSlider(title: "厚度", value: $settings.glowThickness, range: 40...180,
                                       display: "\(Int(settings.glowThickness)) pt")
                    }
                    CardDivider()
                    if alertKinds.isEmpty {
                        SettingsRow(title: "哪些家", subtitle: "先在上面点亮至少一家") { EmptyView() }
                    } else {
                        SettingsVRow(title: "哪些家", subtitle: "会写入该 Agent 的钩子配置") {
                            ChipGroup(options: alertKinds, title: { $0.displayName },
                                      isOn: { settings.alertAgents.contains($0) },
                                      toggle: { kind in
                                          if settings.alertAgents.contains(kind) { settings.alertAgents.remove(kind) }
                                          else { settings.alertAgents.insert(kind) }
                                      })
                            ForEach(alertKinds.filter { settings.alertHookErrors[$0] != nil }) { kind in
                                Text(settings.alertHookErrors[kind] ?? "")
                                    .font(.system(size: 12)).foregroundColor(SettingsTheme.danger)
                            }
                        }
                        CardDivider()
                        SettingsRow(title: "颜色") {
                            HStack(spacing: 12) {
                                HStack(spacing: 5) {
                                    ForEach(alertKinds) { kind in
                                        Circle().fill(Color(hex: settings.glowColorHex(for: kind)))
                                            .frame(width: 12, height: 12)
                                    }
                                }
                                TextButton(title: "自定义") { colorPopover = true }
                                    .popover(isPresented: $colorPopover, arrowEdge: .bottom) { colorEditor }
                            }
                        }
                    }
                }
            }

            SectionLabel(text: "额度")
            SettingsCard {
                // 与菜单栏主菜单「Agent 额度」同一份状态；每家是否露出在菜单栏面板该家页面里设
                SettingsRow(title: "菜单栏显示额度") { ThemedSwitch(isOn: $settings.showUsageInMenuBar) }
            }
        }
        .onAppear(perform: rescan)   // 每次进本页都重新检测（stat 级零成本），列表始终反映本机现状
    }

    /// 颜色弹出层：每家一个取色器 + 「预览」（点亮该色边调边看，再点熄灭）
    private var colorEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("提醒颜色").font(.system(size: 13, weight: .semibold)).foregroundColor(SettingsTheme.text)
            ForEach(alertKinds) { kind in
                HStack(spacing: 10) {
                    Text(kind.displayName).font(.system(size: 13)).foregroundColor(SettingsTheme.text)
                    Spacer()
                    ColorPicker("", selection: colorBinding(kind), supportsOpacity: false).labelsHidden().fixedSize()
                    TextButton(title: glow.previewingSource == kind ? "停止" : "预览") { glow.togglePreview(kind) }
                }
            }
        }
        .padding(16).frame(width: 300)
        .background(SettingsTheme.card)
        .preferredColorScheme(.dark)
    }

    private func colorBinding(_ kind: AgentKind) -> Binding<Color> {
        Binding(get: { Color(hex: settings.glowColorHex(for: kind)) },
                set: { settings.setGlowColorHex($0.toHex(), for: kind) })
    }

    private func toggle(_ kind: AgentKind) {
        if settings.enabledAgents.contains(kind) { settings.enabledAgents.remove(kind) }
        else { settings.enabledAgents.insert(kind) }
    }

    private func status(_ r: AgentProbeResult) -> String {
        guard r.installed else {
            if r.kind == .kimi { return "未发现（Kimi Code CLI 与 Kimi 客户端都没装）" }
            return "未发现（~/\(r.kind.homeDir.lastPathComponent) 不存在）"
        }
        guard let d = r.lastActive else { return "已安装" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 3600 { return "已安装 · 刚刚活跃" }
        if s < 86400 { return "已安装 · \(s / 3600) 小时前活跃" }
        return "已安装 · \(s / 86400) 天前活跃"
    }

    private func rescan() {
        probeResults = AgentProbe.detect()
        discoveredTools = AgentProbe.detectTools()
    }
}
