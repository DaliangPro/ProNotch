import Foundation
import CommonCrypto
import SQLite3

/// 从 Claude 桌面端（Electron/Chromium）读取并解密 claude.ai 会话 cookie。
/// Chromium 在 macOS 用「<App> Safe Storage」钥匙串密码派生 AES 密钥（PBKDF2-SHA1/1003/saltysalt），
/// AES-128-CBC(IV=16空格) 加密 cookie 值，v10/v11 前缀 + 新版 32 字节 host 校验头。
/// 首次读取钥匙串会弹一次系统授权框（用户点「始终允许」后不再打扰）——这是本机自己的凭据。
enum CCDCookieReader {
    struct Cookies { var sessionKey: String; var cfClearance: String? }

    /// 读 CCD 的 claude.ai sessionKey（+ cf_clearance，过 Cloudflare 用）。任一步失败返回 nil
    static func claudeAICookies() -> Cookies? {
        guard let key = safeStorageKey() else { return nil }
        let cookiesDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cookies")
        guard FileManager.default.fileExists(atPath: cookiesDB.path) else { return nil }
        // 复制到临时位置读，避开 CCD 运行时的文件锁（含 -wal/-journal）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pn-ccd-cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.copyItem(at: cookiesDB, to: tmp)) != nil else { return nil }
        let enc = readEncryptedCookies(tmp.path, host: "claude.ai")
        guard let skEnc = enc["sessionKey"], let sk = decrypt(skEnc, key: key), !sk.isEmpty else { return nil }
        let cf = enc["cf_clearance"].flatMap { decrypt($0, key: key) }
        return Cookies(sessionKey: sk, cfClearance: cf)
    }

    /// 「Claude Safe Storage」钥匙串密码 → PBKDF2-SHA1(1003,16B) 派生 AES-128 密钥
    private static func safeStorageKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let pw = item as? Data else { return nil }
        let pwBytes = [UInt8](pw)
        let salt = Array("saltysalt".utf8)
        var out = [UInt8](repeating: 0, count: 16)
        let ok = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
            pwBytes.map { CChar(bitPattern: $0) }, pwBytes.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
            &out, out.count)
        return ok == kCCSuccess ? Data(out) : nil
    }

    /// AES-128-CBC 解密，IV=16 空格；去 v10/v11 前缀 + 新版 32 字节 host-hash 头
    private static func decrypt(_ blob: Data, key: Data) -> String? {
        var body = blob
        if body.count > 3, let p = String(data: body.prefix(3), encoding: .utf8), p == "v10" || p == "v11" {
            body = body.subdata(in: 3..<body.count)
        }
        guard body.count % 16 == 0, !body.isEmpty else { return nil }
        let iv = [UInt8](repeating: 0x20, count: 16)
        let keyBytes = [UInt8](key)
        let inBytes = [UInt8](body)
        let outCap = body.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outCap)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             keyBytes, keyBytes.count, iv,
                             inBytes, inBytes.count,
                             &out, outCap, &moved)
        guard status == kCCSuccess else { return nil }
        var outData = Data(out)
        outData.removeSubrange(moved..<outData.count)
        // 新版 Chromium 明文前 32 字节是 sha256(host) 完整性头，去掉才是真值
        let plain = outData.count > 32 ? outData.subdata(in: 32..<outData.count) : outData
        return String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }

    /// 用 libsqlite3 读 cookies 表里指定 host 的加密值（只读）
    private static func readEncryptedCookies(_ path: String, host: String) -> [String: Data] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key LIKE '%' || ? "
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var result: [String: Data] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)
            if let bytes = sqlite3_column_blob(stmt, 1) {
                let len = Int(sqlite3_column_bytes(stmt, 1))
                result[name] = Data(bytes: bytes, count: len)
            }
        }
        return result
    }
}
