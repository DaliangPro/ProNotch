import Foundation

/// 一轮迁移的结构化结果。
///
/// 迁移完成标记（`didMigrateFromNotchHub`）只能在**没有失败项**时落盘：
/// 原先无论钥匙串搬没搬成都无条件置 true，一次失败就永久放弃重试，用户的 Key 从此找不回来。
struct KeychainMigrationReport: Equatable {
    /// 成功搬到新位置并已删除旧值的账户
    var migrated: [String] = []
    /// 无需迁移（新位置已有值，或旧位置本就没有）
    var skipped: [String] = []
    /// 失败账户及原因——旧值一律原地保留
    var failed: [String: KeychainError] = [:]

    /// 全部"成功或无需迁移"才算完成
    var isComplete: Bool { failed.isEmpty }
}

/// 事务式钥匙串迁移。
///
/// 每个条目严格执行「读旧 → 写新 → 从新位置读回 → 内容比对 → 删旧」，
/// 任一步失败都停在该步、保留旧值并记录失败。原先的写法是 `save(...)` 之后
/// 无视返回值直接 `SecItemDelete` 旧条目——写失败（钥匙串锁定、ACL 拒绝、磁盘满）
/// 时旧 Key 照删不误，用户的 API Key 就此消失且无从恢复。
struct KeychainMigrator {
    let keychain: KeychainAccessing
    let currentService: String

    init(keychain: KeychainAccessing = SystemKeychain(),
         currentService: String = KeychainStore.service) {
        self.keychain = keychain
        self.currentService = currentService
    }

    /// 应用更名遗留：把旧 service（NotchHub 时代）下的条目搬到当前 service
    func migrateLegacyService(accounts: [String], from legacyService: String) -> KeychainMigrationReport {
        var report = KeychainMigrationReport()
        for account in accounts {
            switch migrateOne(account: account, from: legacyService, to: currentService) {
            case .success(let moved):
                if moved { report.migrated.append(account) } else { report.skipped.append(account) }
            case .failure(let error):
                report.failed[account] = error
            }
        }
        return report
    }

    /// 历史版本把 Key 明文存在 UserDefaults：搬进钥匙串，**读回校验一致后**才抹掉明文。
    ///
    /// 读的是持久化域而非 `string(forKey:)`——后者会把测试参数域（`-chatAPIKey xxx`）
    /// 的临时值也当成待迁移的历史明文。
    func migratePlaintextKeys(_ accounts: [String],
                              in defaults: UserDefaults,
                              domain: String) -> KeychainMigrationReport {
        var report = KeychainMigrationReport()
        guard let persisted = defaults.persistentDomain(forName: domain) else {
            report.skipped = accounts
            return report
        }
        for account in accounts {
            guard let legacy = persisted[account] as? String, !legacy.isEmpty else {
                report.skipped.append(account)
                continue
            }
            switch writeAndVerify(legacy, account: account, service: currentService) {
            case .success:
                defaults.removeObject(forKey: account)
                report.migrated.append(account)
            case .failure(let error):
                report.failed[account] = error   // 明文原样保留，下次启动继续重试
            }
        }
        return report
    }

    // MARK: - 私有

    /// 单条目事务迁移；返回值 true 表示真搬了，false 表示无需搬
    private func migrateOne(account: String,
                            from source: String,
                            to destination: String) -> Result<Bool, KeychainError> {
        // 新位置已有值：不覆盖用户当前在用的 Key
        switch keychain.read(account, service: destination) {
        case .failure(let error): return .failure(error)
        case .success(let existing): if existing?.isEmpty == false { return .success(false) }
        }
        let legacy: String
        switch keychain.read(account, service: source) {
        case .failure(let error): return .failure(error)
        case .success(let value):
            guard let value, !value.isEmpty else { return .success(false) }
            legacy = value
        }
        if case .failure(let error) = writeAndVerify(legacy, account: account, service: destination) {
            return .failure(error)
        }
        // 新值已确认可读，此时删旧才是安全的
        if case .failure(let error) = keychain.delete(account, service: source) {
            return .failure(error)
        }
        return .success(true)
    }

    /// 写入并立刻从同一位置读回比对——只有内容完全一致才算写成功
    private func writeAndVerify(_ value: String,
                                account: String,
                                service: String) -> Result<Void, KeychainError> {
        if case .failure(let error) = keychain.save(value, account: account, service: service) {
            return .failure(error)
        }
        switch keychain.read(account, service: service) {
        case .failure(let error): return .failure(error)
        case .success(let readback):
            guard readback == value else { return .failure(.verifyMismatch) }
            return .success(())
        }
    }
}
