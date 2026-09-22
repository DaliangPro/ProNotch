import SwiftUI

/// 接口池列表：闪问页与翻译页共用同一个组件、同一种样子（大梁老师 2026-09-22 要求两页统一）。
/// 一行一套：圆点定当前、名字、域名，右侧「编辑」开共用弹层；标题右「新增」。
/// 翻译模式多一行「同闪问」在最上面——翻译默认跟着闪问当前那套走
struct ProviderListSection: View {
    enum Mode { case chat, translate }
    let mode: Mode

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var chatStore: ChatStore

    @State private var endpointSheet = false
    /// 翻译模式下编辑 / 新建要经过 ChatStore 的当前套：记下闪问原本那套，关了弹层切回去
    @State private var chatProviderToRestore: UUID?

    var body: some View {
        SettingsSectionHeader(text: "接口") {
            TextButton(title: "新增") { addProvider() }
        }
        SettingsCard {
            if mode == .translate {
                followRow
                if !chatStore.providers.isEmpty { CardDivider() }
            }
            ForEach(Array(chatStore.providers.enumerated()), id: \.element.id) { i, p in
                if i > 0 { CardDivider() }
                providerRow(p)
            }
        }
        .sheet(isPresented: $endpointSheet, onDismiss: restoreChatProvider) { ChatEndpointSheet() }
    }

    // MARK: - 行

    /// 翻译模式首行：跟闪问当前那套
    private var followRow: some View {
        let on = settings.translateUseChatAPI || translateProvider == nil
        return Button { settings.translateUseChatAPI = true } label: {
            HStack(spacing: 10) {
                radio(on)
                Text("同闪问").font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundColor(SettingsTheme.text)
                Text(chatProviderName).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private func providerRow(_ p: APIProvider) -> some View {
        let on = isSelected(p)
        return HStack(spacing: 12) {
            Button { select(p) } label: {
                HStack(spacing: 10) {
                    radio(on)
                    Text(p.name.isEmpty ? "未命名" : p.name)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundColor(SettingsTheme.text)
                    Text(host(of: p.baseURL)).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if mode == .chat, p.id == chatStore.currentProviderID { connectivityLabel }
            TextButton(title: "编辑") { edit(p) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func radio(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 14))
            .foregroundColor(on ? SettingsTheme.accent : SettingsTheme.textMuted)
    }

    @ViewBuilder private var connectivityLabel: some View {
        switch chatStore.connectivity {
        case .unknown: EmptyView()
        case .checking: Text("检测中…").font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
        case .ok: Text("连接正常").font(.system(size: 12)).foregroundColor(SettingsTheme.success)
        case .failed: Text("连接失败").font(.system(size: 12)).foregroundColor(SettingsTheme.danger)
        }
    }

    // MARK: - 状态

    /// 翻译单独指定的那套（指定的已被删则视为没指定）
    private var translateProvider: APIProvider? {
        guard !settings.translateUseChatAPI else { return nil }
        return chatStore.providers.first { $0.id == settings.translateProviderID }
    }

    private var chatProviderName: String {
        let name = chatStore.providers.first { $0.id == chatStore.currentProviderID }?.name ?? ""
        return name.isEmpty ? "未命名" : name
    }

    private func isSelected(_ p: APIProvider) -> Bool {
        switch mode {
        case .chat: return p.id == chatStore.currentProviderID
        case .translate: return translateProvider?.id == p.id
        }
    }

    private func host(of url: String) -> String {
        URLComponents(string: url)?.host ?? URL(string: url)?.host ?? url
    }

    // MARK: - 动作

    private func select(_ p: APIProvider) {
        switch mode {
        case .chat:
            chatStore.activateProvider(p.id)
        case .translate:
            settings.translateUseChatAPI = false
            settings.translateProviderID = p.id
        }
    }

    /// 编辑只能编辑 ChatStore 的当前套：不是当前就先切过去，翻译模式关了弹层再切回闪问原来那套
    private func edit(_ p: APIProvider) {
        if p.id != chatStore.currentProviderID {
            if mode == .translate { chatProviderToRestore = chatStore.currentProviderID }
            chatStore.activateProvider(p.id)
        }
        endpointSheet = true
    }

    private func addProvider() {
        if mode == .translate { chatProviderToRestore = chatStore.currentProviderID }
        chatStore.addProvider()
        if mode == .translate {
            settings.translateUseChatAPI = false
            settings.translateProviderID = chatStore.currentProviderID
        }
        endpointSheet = true
    }

    private func restoreChatProvider() {
        guard let prev = chatProviderToRestore else { return }
        chatProviderToRestore = nil
        if chatStore.providers.contains(where: { $0.id == prev }) { chatStore.activateProvider(prev) }
    }
}
