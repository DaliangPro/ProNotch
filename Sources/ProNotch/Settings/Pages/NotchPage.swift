import SwiftUI

/// 刘海：示意图直接点槽位、组件页三张磁贴、音量亮度两个选片。
/// 时区、时钟城市、预警类型、权限警告都是条件行，默认状态一屏放下
struct NotchPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var weather: WeatherStore

    @State private var cityPopover = false
    @State private var locationGranted = true
    @State private var axGranted = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "刘海")

            SettingsCard {
                NotchPreview().padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)
                CardDivider()
                SettingsRow(title: "左侧") {
                    SegmentedPicker(options: NotchSlot.allCases, title: { $0.title }, selection: $settings.leftSlot)
                }
                CardDivider()
                SettingsRow(title: "右侧") {
                    SegmentedPicker(options: NotchSlot.allCases, title: { $0.title }, selection: $settings.rightSlot)
                }
                if settings.leftSlot == .clock || settings.rightSlot == .clock {
                    CardDivider()
                    SettingsRow(title: "时区") {
                        PopupMenu(label: settings.clockZone.title) {
                            ForEach(ClockZone.allCases) { zone in
                                Button(zone.title) { settings.clockZone = zone }
                            }
                        }
                    }
                }
                CardDivider()
                SettingsRow(title: "全屏时隐藏") { ThemedSwitch(isOn: $settings.hideNotchInFullscreen) }
                CardDivider()
                SettingsRow(title: "显示在") {
                    SegmentedPicker(options: NotchScreenMode.allCases, title: { $0.title },
                                    selection: $settings.notchScreenMode)
                }
            }

            SectionLabel(text: "组件页")
            HStack(spacing: 8) {
                SettingsTile(title: "内存卡", isOn: settings.memoryWidgetEnabled,
                             action: { settings.memoryWidgetEnabled.toggle() }) {
                    tileIcon("memorychip", on: settings.memoryWidgetEnabled)
                }
                SettingsTile(title: "时钟卡", isOn: settings.clockWidgetEnabled,
                             action: { settings.clockWidgetEnabled.toggle() }) {
                    tileIcon("clock", on: settings.clockWidgetEnabled)
                }
                SettingsTile(title: "天气卡", isOn: settings.weatherWidgetEnabled,
                             action: { settings.weatherWidgetEnabled.toggle() }) {
                    tileIcon("cloud.sun", on: settings.weatherWidgetEnabled)
                }
            }
            SettingsCard {
                if settings.clockWidgetEnabled {
                    SettingsRow(title: "时钟城市") {
                        HStack(spacing: 12) {
                            Text(citySummary).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                                .lineLimit(1).truncationMode(.tail)
                            TextButton(title: "编辑") { cityPopover = true }
                                .popover(isPresented: $cityPopover, arrowEdge: .bottom) { CityPicker() }
                        }
                    }
                    CardDivider()
                }
                // 预警独立于天气卡显示：关掉天气卡仍按设置弹预警；关此开关才停 900 秒兜底刷新
                SettingsRow(title: "恶劣天气预警") {
                    HStack(spacing: 14) {
                        PopupMenu(label: "预览") {
                            ForEach(WeatherStore.previewAlerts, id: \.label) { item in
                                Button(item.label) { weather.preview(item.alert) }
                            }
                            Divider()
                            Button("停止") { weather.dismissAlert() }
                        }
                        ThemedSwitch(isOn: $settings.weatherAlertsEnabled)
                    }
                }
                if settings.weatherAlertsEnabled {
                    CardDivider()
                    SettingsRow(title: "预警类型") {
                        ChipGroup(options: WeatherAlertType.allCases, title: { $0.displayName },
                                  isOn: { settings.weatherAlertTypes.contains($0) },
                                  toggle: { type in
                                      if settings.weatherAlertTypes.contains(type) { settings.weatherAlertTypes.remove(type) }
                                      else { settings.weatherAlertTypes.insert(type) }
                                  })
                    }
                }
                if !locationGranted && (settings.weatherWidgetEnabled || settings.weatherAlertsEnabled
                                        || settings.leftSlot == .weather || settings.rightSlot == .weather) {
                    CardDivider()
                    WarningRow(text: "定位未授权，天气无法更新", action: "去授权") {
                        PermissionStatus.openSystemSettings(.location)
                    }
                }
            }

            SectionLabel(text: "音量与亮度")
            SettingsCard {
                SettingsRow(title: "按键时在刘海显示") {
                    ChipGroup(options: ["音量", "亮度"], title: { $0 },
                              isOn: { $0 == "音量" ? settings.volumeHUDEnabled : settings.brightnessHUDEnabled },
                              toggle: { name in
                                  if name == "音量" { settings.volumeHUDEnabled.toggle() }
                                  else { settings.brightnessHUDEnabled.toggle() }
                              })
                }
                if !axGranted && (settings.volumeHUDEnabled || settings.brightnessHUDEnabled) {
                    CardDivider()
                    WarningRow(text: "辅助功能未授权，按键不会被接管", action: "去授权") {
                        PermissionStatus.openSystemSettings(.accessibility)
                    }
                }
            }
        }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var citySummary: String {
        settings.clockCardZones.isEmpty ? "未选" : settings.clockCardZones.map(\.title).joined(separator: "、")
    }

    private func tileIcon(_ name: String, on: Bool) -> some View {
        Image(systemName: name).font(.system(size: 14))
            .foregroundColor(on ? SettingsTheme.text : SettingsTheme.textMuted)
            .frame(width: 16)
    }

    private func refreshPermissions() {
        locationGranted = PermissionStatus.granted(.location)
        axGranted = PermissionStatus.granted(.accessibility)
    }
}

/// 时钟卡城市多选（弹出层）：点选即增删，点击顺序即卡上顺序
private struct CityPicker: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("时钟卡城市").font(.system(size: 13, weight: .semibold)).foregroundColor(SettingsTheme.text)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                ForEach(ClockZone.allCases) { zone in
                    let on = settings.clockCardZones.contains(zone)
                    Button {
                        if on { settings.clockCardZones.removeAll { $0 == zone } }
                        else { settings.clockCardZones.append(zone) }
                    } label: {
                        Text(zone.title).font(.system(size: 12))
                            .foregroundColor(on ? SettingsTheme.text : SettingsTheme.textMuted)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? SettingsTheme.fillOn : SettingsTheme.fillOff))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("点击顺序即卡上顺序").font(.system(size: 11)).foregroundColor(SettingsTheme.textMuted)
        }
        .padding(16).frame(width: 380)
        .background(SettingsTheme.card)
        .preferredColorScheme(.dark)
    }
}
