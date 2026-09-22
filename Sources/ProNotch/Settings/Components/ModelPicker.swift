import SwiftUI

/// 按账号分组的模型下拉：每个功能在自己页上选模型，账号在「AI 模型配置」页管。
/// 一个账号一组（Section 头是账号名），组里是它的模型；没有任何账号时给一条「去添加」
struct ModelPicker: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var chatStore: ChatStore

    let label: String
    /// 翻译用：顶上多一项「跟随闪问」
    var followChat: (() -> Void)? = nil
    let onPick: (APIProvider, String) -> Void

    private var hasAnyModel: Bool {
        chatStore.providers.contains { !ChatStore.models(of: $0).isEmpty }
    }

    var body: some View {
        PopupMenu(label: label) {
            if let followChat {
                Button("跟随闪问", action: followChat)
                Divider()
            }
            if hasAnyModel {
                ForEach(chatStore.providers) { p in
                    let ms = ChatStore.models(of: p)
                    if !ms.isEmpty {
                        Section(p.name.isEmpty ? "未命名" : p.name) {
                            ForEach(ms, id: \.self) { m in Button(m) { onPick(p, m) } }
                        }
                    }
                }
            } else if chatStore.providers.isEmpty {
                Button("去添加账号…") { settings.pendingSection = SettingsSection.models.rawValue }
            } else {
                Button("账号里还没有模型，去获取…") { settings.pendingSection = SettingsSection.models.rawValue }
            }
        }
    }
}
