import Foundation

/// 钥匙串读写：API Key 等敏感信息不落明文配置文件。
/// 通用密码条目，service 固定为应用标识，account 区分具体字段。
///
/// 实际读写委托给 `SystemKeychain`（见 KeychainAccess.swift）——这里只保留全局便捷入口，
/// 让 ChatStore 等调用方不必自己持有实例；迁移逻辑走 `KeychainMigrator`，可注入 fake 测失败路径
enum KeychainStore {
    static let service = "com.daliangpro.ProNotch"
    /// 应用更名前（NotchHub 时代）的 service
    static let legacyService = "com.jiliang.NotchHub"
    /// 曾经存在旧 service 下、需要跟着应用改名一起搬家的账户
    static let legacyAccounts = ["chatAPIKey", "chatTavilyKey"]

    private static let backend: KeychainAccessing = SystemKeychain()

    static func read(_ account: String) -> String? {
        switch backend.read(account, service: service) {
        case .success(let value): return value
        case .failure: return nil
        }
    }

    /// 写入（空字符串视为删除）
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return delete(account) }
        if case .success = backend.save(value, account: account, service: service) { return true }
        return false
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        if case .success = backend.delete(account, service: service) { return true }
        return false
    }

    /// 应用更名遗留：把旧 service 下的条目事务式搬到当前 service。
    /// 返回结构化结果——调用方要据此决定「迁移完成」标记能不能落盘
    @discardableResult
    static func migrateLegacyService() -> KeychainMigrationReport {
        let report = KeychainMigrator(keychain: backend, currentService: service)
            .migrateLegacyService(accounts: legacyAccounts, from: legacyService)
        // 只记账户名与结果，绝不打印 Key 内容
        if !report.migrated.isEmpty {
            AppLog.keychain.info("钥匙串条目已迁移到新应用标识: \(report.migrated.joined(separator: ", "), privacy: .public)")
        }
        for (account, error) in report.failed {
            AppLog.keychain.error("钥匙串条目 \(account, privacy: .public) 迁移失败（旧值已保留，下次启动重试）: \(LogRedaction.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
        return report
    }
}
