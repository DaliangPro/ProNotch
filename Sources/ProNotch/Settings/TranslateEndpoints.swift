import Foundation

/// 翻译接口的一套配置。
///
/// Key 不落这里（体积小但仍属敏感），存钥匙串，账号见 `keychainAccount`；
/// 首套沿用旧账号 `translateAPIKey` 兼容历史数据——迁移时一个字节都不用搬，
/// 也就不必在启动路径上碰钥匙串（碰了就会多弹一次授权框）
struct TranslateEndpoint: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: String
    var model: String
    var keychainAccount: String
}

/// 翻译多套配置的存档、迁移与增删。
///
/// 病灶：翻译的接口原本只有 `translateBaseURL` / `translateModel` 两个字符串，
/// 换一个服务商就把上一个盖掉，想切回去只能照着记忆重新敲一遍地址、Key 和模型名
/// （大梁老师 2026-08-17 反馈）。闪问那边早就是多套胶囊切换，这里补齐同一套能力。
///
/// 与闪问的多套**各存各的**：翻译常用便宜快的小模型，闪问用强模型，
/// 混在一张列表里只会让两边的切换器都多出自己用不上的条目。
enum TranslateEndpointStore {
    static let listKey = "translateEndpoints"
    static let currentKey = "translateCurrentEndpointID"
    /// 单套时代的钥匙串账号，迁移后归第一套所有
    static let legacyAccount = "translateAPIKey"

    /// 读出全部配置。无存档则拿单套时代的地址/模型迁成第一套（不碰钥匙串）
    static func load(from defaults: UserDefaults,
                     legacyBaseURL: String, legacyModel: String) -> [TranslateEndpoint] {
        if let data = defaults.data(forKey: listKey),
           let list = try? JSONDecoder().decode([TranslateEndpoint].self, from: data),
           !list.isEmpty {
            return list
        }
        return [TranslateEndpoint(name: inferName(from: legacyBaseURL),
                                  baseURL: legacyBaseURL, model: legacyModel,
                                  keychainAccount: legacyAccount)]
    }

    /// 当前选中那套的 id。存档里的 id 已失效（比如被删过）就退回第一套
    static func currentID(from defaults: UserDefaults, in list: [TranslateEndpoint]) -> UUID? {
        if let raw = defaults.string(forKey: currentKey), let uid = UUID(uuidString: raw),
           list.contains(where: { $0.id == uid }) {
            return uid
        }
        return list.first?.id
    }

    static func persist(_ list: [TranslateEndpoint], current: UUID?, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: listKey)
        }
        defaults.set(current?.uuidString ?? "", forKey: currentKey)
    }

    /// 新增一套用的钥匙串账号：与首套的旧账号区分开，各套的 Key 互不覆盖
    static func newAccount() -> String { "\(legacyAccount)-\(UUID().uuidString)" }

    /// 某套配置的 Key 该存到／读自哪个账号。
    ///
    /// **写 Key 与读 Key 必须都问这里。** 2026-08-17 实测踩坑：写走当前套的账号、
    /// 读却硬编码成 `translateAPIKey`，于是新建的那套填了正确的 Key、连通性测试也过，
    /// 一翻译还是报鉴权失败——翻译取到的始终是第一套那个旧 Key。
    /// 闪问当年栽过同一个跟头，这里再栽一次纯属自找。
    static func account(for id: UUID?, in list: [TranslateEndpoint]) -> String {
        list.first { $0.id == id }?.keychainAccount ?? legacyAccount
    }

    /// 从域名猜配置名：api.deepseek.com → Deepseek；空地址则「默认」
    static func inferName(from url: String) -> String {
        let host = URLComponents(string: url)?.host ?? URL(string: url)?.host ?? ""
        let parts = host.split(separator: ".")
        if parts.count >= 2 { return parts[parts.count - 2].capitalized }
        if !host.isEmpty { return host }
        return url.isEmpty ? "默认" : "自定义"
    }
}
