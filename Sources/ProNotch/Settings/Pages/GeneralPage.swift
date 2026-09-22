import SwiftUI

/// 通用：开机自启、软件、权限。
/// 三项权限集中在这里看全，功能页只在未授权时弹一行警告（2026-09-21 产品审阅第 6 条）
struct GeneralPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var updates: UpdateChecker

    /// 权限状态快照：进页面和 App 回到前台时刷新（用户去系统设置授完权切回来立刻反映）
    @State private var granted: [PermissionKind: Bool] = [:]

    private let permissions: [PermissionKind] = [.accessibility, .location, .screenRecording]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "通用")

            SettingsCard {
                SettingsRow(title: "开机自动启动") { ThemedSwitch(isOn: $settings.launchAtLogin) }
            }
            if let hint = settings.loginItemHint {
                SettingsNote(text: hint)
            }

            SectionLabel(text: "软件")
            SettingsCard {
                HStack {
                    Text("ProNotch").font(.system(size: 13, weight: .semibold)).foregroundColor(SettingsTheme.text)
                    Spacer()
                    Text(updates.currentVersion).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                CardDivider()
                SettingsRow(title: "更新") {
                    HStack(spacing: 12) {
                        updateStatus
                        if updates.checking {
                            ProgressView().controlSize(.small)
                        } else {
                            TextButton(title: "检查") { updates.check() }
                        }
                    }
                }
                CardDivider()
                SettingsRow(title: "项目主页") {
                    Link("github.com/DaliangPro/ProNotch",
                         destination: URL(string: "https://github.com/DaliangPro/ProNotch")!)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(SettingsTheme.text)
                }
            }

            SectionLabel(text: "权限")
            SettingsCard {
                ForEach(Array(permissions.enumerated()), id: \.offset) { i, kind in
                    if i > 0 { CardDivider() }
                    SettingsRow(title: kind.title, subtitle: kind.usedBy) {
                        if granted[kind] ?? false {
                            Text("已授权").font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                        } else {
                            HStack(spacing: 12) {
                                Text("未授权").font(.system(size: 12)).foregroundColor(SettingsTheme.danger)
                                TextButton(title: "去授权") { PermissionStatus.openSystemSettings(kind) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    @ViewBuilder private var updateStatus: some View {
        if let release = updates.available {
            Link("发现 \(release.version)，前往下载", destination: release.url)
                .font(.system(size: 12)).foregroundColor(SettingsTheme.text)
        } else if updates.checkedUpToDate {
            Text("已是最新").font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
        } else if updates.lastError != nil {
            Text("检查失败").font(.system(size: 12)).foregroundColor(SettingsTheme.danger)
        }
    }

    private func refresh() {
        for kind in permissions { granted[kind] = PermissionStatus.granted(kind) }
    }
}
