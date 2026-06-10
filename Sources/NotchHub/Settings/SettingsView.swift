import SwiftUI

/// 设置窗口内容：通用（开机自启）+ AI 对话配置（复用面板内的表单）
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通用")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Toggle("开机自动启动 NotchHub", isOn: $settings.launchAtLogin)
                .toggleStyle(.switch)
                .font(.system(size: 12))

            if let hint = settings.loginItemHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            Text("提示：移动应用位置后需重新设置开机自启")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Toggle("全屏应用时禁用悬停展开", isOn: $settings.disableHoverInFullscreen)
                .toggleStyle(.switch)
                .font(.system(size: 12))
            Text("开启后，当前屏幕有应用处于全屏时，悬停刘海不会展开面板")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Divider()
                .padding(.vertical, 6)

            Text("AI 对话")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            ChatSettingsForm(showSettings: .constant(true))

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480, height: 340, alignment: .topLeading)
    }
}
