import Foundation
import Security

/// 钥匙串操作失败的结构化原因。
///
/// 迁移逻辑要按不同失败分别处置（写失败保留旧值、读回不一致保留旧值、删旧失败仍算失败但新值已在），
/// 所以不能像原先那样统一退化成 `Bool`——一个 false 说不清是"没写进去"还是"写进去了但删不掉"。
enum KeychainError: Error, Equatable {
    /// Security framework 返回的非成功状态码
    case status(OSStatus)
    /// 条目存在但不是合法 UTF-8
    case invalidData
    /// 写入后读回的内容与写入值不符
    case verifyMismatch
}

/// 钥匙串读写的可注入抽象。
///
/// 迁移是"读旧 → 写新 → 读回校验 → 删旧"的多步事务，任何一步失败都不能丢 Key。
/// 这些失败路径在真钥匙串上无法稳定复现（授权弹框、ACL、SecItem 状态码都不可控），
/// 只能靠注入 fake 来测——这是本协议存在的唯一理由。
protocol KeychainAccessing: Sendable {
    /// 读取；条目不存在返回 `.success(nil)`，只有真出错才返回 `.failure`
    func read(_ account: String, service: String) -> Result<String?, KeychainError>
    func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError>
    /// 删除；条目本就不存在视为成功（幂等）
    func delete(_ account: String, service: String) -> Result<Void, KeychainError>
}

/// 生产实现：通用密码条目，走 Security framework
struct SystemKeychain: KeychainAccessing {
    func read(_ account: String, service: String) -> Result<String?, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess else { return .failure(.status(status)) }
        guard let data = item as? Data else { return .failure(.invalidData) }
        guard let value = String(data: data, encoding: .utf8) else { return .failure(.invalidData) }
        return .success(value)
    }

    func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            return addStatus == errSecSuccess ? .success(()) : .failure(.status(addStatus))
        }
        return status == errSecSuccess ? .success(()) : .failure(.status(status))
    }

    func delete(_ account: String, service: String) -> Result<Void, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return (status == errSecSuccess || status == errSecItemNotFound)
            ? .success(()) : .failure(.status(status))
    }
}
