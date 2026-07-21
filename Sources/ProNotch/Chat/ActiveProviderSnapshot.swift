import Foundation

/// 当前活动 API 配置的只读快照。
///
/// 闪问支持多套 Provider，每套有自己的端点、模型和钥匙串账号。
/// 谁想"复用闪问的接口"（目前是截图原位翻译），都必须从这里取，
/// 不能自己去读 `chatBaseURL` 和固定账号 `chatAPIKey`：
/// 那两个值只在按「保存」时才写，切套不写；固定账号又永远指向第一套。
/// 两者一错位，就会拿 A 的 Key 去请求 B 的端点——轻则 401，重则把内容送错服务商。
struct ActiveProviderSnapshot: Sendable, Equatable {
    /// 配置是否可直接发请求
    enum Readiness: Sendable, Equatable {
        case ready
        /// 端点或模型还没填
        case notConfigured
        /// 端点和模型都在，但这套的 Key 还没落到钥匙串（迁移未完成 / 填了没保存）
        case keyPending
    }

    var providerID: UUID?
    var name: String = ""
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""

    var readiness: Readiness {
        guard !baseURL.isEmpty, !model.isEmpty else { return .notConfigured }
        return apiKey.isEmpty ? .keyPending : .ready
    }

    /// 从存档解析当前活动的那一套（含它自己的钥匙串账号）。
    /// 钥匙串是惰性读的——只在真正要用接口时才调，不在启动路径上多弹一次授权框
    static func load(from env: ChatEnvironment) -> ActiveProviderSnapshot {
        let defaults = env.defaults
        guard let data = defaults.data(forKey: "chatProviders"),
              let list = try? JSONDecoder().decode([APIProvider].self, from: data),
              !list.isEmpty else {
            // 还没有多套存档：退回单套时代的键，保持老用户可用
            return ActiveProviderSnapshot(
                providerID: nil,
                name: "",
                baseURL: defaults.string(forKey: PrefKey.chatBaseURL) ?? "",
                model: defaults.string(forKey: PrefKey.chatModel) ?? "",
                apiKey: env.readKey("chatAPIKey"))
        }
        let current: APIProvider
        if let raw = defaults.string(forKey: "chatCurrentProviderID"),
           let uid = UUID(uuidString: raw),
           let matched = list.first(where: { $0.id == uid }) {
            current = matched
        } else {
            current = list[0]
        }
        return ActiveProviderSnapshot(providerID: current.id,
                                      name: current.name,
                                      baseURL: current.baseURL,
                                      model: current.model,
                                      apiKey: env.readKey(current.keychainAccount))
    }
}
