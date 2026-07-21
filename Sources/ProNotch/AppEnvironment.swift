import SwiftUI

/// 应用级数据层：十个 Store 在启动时一次建齐、全程存活。
///
/// 它们之所以不挂在刘海窗口上，是因为换屏（接显示器、合盖）要重建窗口，
/// 而对话记录、剪贴板监听这些状态不能跟着窗口一起没。既然十个总是同进同出，
/// 就打成一个值传——此前它们是 AppDelegate 的十个独立属性，
/// 每加一个 Store 都要同步改构造函数签名和三处注入链，加漏一处编译期还发现不了。
///
/// 注：`snippets` 不进 `injecting`——常用话术只在设置窗用，刘海面板里没有它的消费者。
@MainActor
struct AppEnvironment {
    let launcher: LauncherStore
    let clipboard: ClipboardStore
    let snippets: SnippetStore
    let chat: ChatStore
    let usage: UsageStore
    let agentSessions: AgentSessionsStore
    let quickActions: QuickActionsStore
    let settings: SettingsStore
    let memory: MemoryStore
    let weather: WeatherStore
}

extension View {
    /// 把数据层一次性注入 SwiftUI 环境。
    /// 刘海窗口、展开面板快照、收起态快照三处原本各抄了一遍九行 `.environmentObject`。
    @MainActor
    func injecting(_ env: AppEnvironment) -> some View {
        environmentObject(env.launcher)
            .environmentObject(env.clipboard)
            .environmentObject(env.chat)
            .environmentObject(env.quickActions)
            .environmentObject(env.settings)
            .environmentObject(env.usage)
            .environmentObject(env.agentSessions)
            .environmentObject(env.memory)
            .environmentObject(env.weather)
    }
}
