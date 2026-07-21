import Foundation
import CommonCrypto
import SQLite3

/// 从 Claude 桌面端（Electron/Chromium）读取并解密 claude.ai 会话 cookie。
/// Chromium 在 macOS 用「<App> Safe Storage」钥匙串密码派生 AES 密钥（PBKDF2-SHA1/1003/saltysalt），
/// AES-128-CBC(IV=16空格) 加密 cookie 值，v10/v11 前缀 + 新版 32 字节 host 校验头。
/// 首次读取钥匙串会弹一次系统授权框（用户点「始终允许」后不再打扰）——这是本机自己的凭据。
enum CCDCookieReader {
    struct Cookies { var sessionKey: String; var cfClearance: String? }

    /// 一行加密 cookie。`hostKey` 必须一起带出来：新版 Chromium 的完整性头
    /// 哈希的是这一行自己的 host_key（`.claude.ai` 带前导点），不是我们查询时用的域名
    struct EncryptedCookie: Equatable {
        let name: String
        let hostKey: String
        let value: Data
    }

    enum Failure: Error, Equatable {
        case missingDatabase
        case sqlite(String)

        var message: String {
            switch self {
            case .missingDatabase: return "未找到 Claude 桌面端的 Cookies 库"
            case .sqlite(let detail): return "读取 Cookies 库失败：\(detail)"
            }
        }
    }

    /// 读 CCD 的 claude.ai sessionKey（+ cf_clearance，过 Cloudflare 用）。任一步失败返回 nil
    static func claudeAICookies() -> Cookies? {
        guard let key = safeStorageKey() else { return nil }
        let cookiesDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cookies")
        let rows: [EncryptedCookie]
        do {
            rows = try withSnapshot(of: cookiesDB) { try readEncryptedCookies($0, host: "claude.ai") }
        } catch let failure as Failure {
            // 只记失败原因，绝不记 cookie 值
            print("[ProNotch] \(failure.message)")
            return nil
        } catch {
            print("[ProNotch] 读取 Cookies 库失败：\(error.localizedDescription)")
            return nil
        }
        func value(_ name: String) -> String? {
            guard let row = rows.first(where: { $0.name == name }) else { return nil }
            return decrypt(row.value, key: key, host: row.hostKey)
        }
        guard let sk = value("sessionKey"), !sk.isEmpty else { return nil }
        return Cookies(sessionKey: sk, cfClearance: value("cf_clearance"))
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

    // MARK: - 解密

    /// AES-128-CBC 解密，IV=16 空格；去 v10/v11 前缀，再按 host 核对完整性头
    static func decrypt(_ blob: Data, key: Data, host: String) -> String? {
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
        let plain = stripHostHash(outData, host: host)
        return String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }

    /// 新版 Chromium 在明文前面加 32 字节 `SHA256(host_key)` 完整性头。
    ///
    /// 病灶：原实现只看长度——`count > 32` 就无条件砍掉前 32 字节。
    /// 旧版数据库没有这个头，任何超过 32 字节的旧 cookie 都会被砍掉开头 32 个字符，
    /// 拿到一段残值，然后在别处以「登录失效」的面目出现，排查方向全错。
    ///
    /// 对策：只有前 32 字节确实等于 `SHA256(host)` 才剥；对不上就原样保留
    static func stripHostHash(_ plaintext: Data, host: String) -> Data {
        guard plaintext.count > 32 else { return plaintext }
        guard plaintext.prefix(32) == sha256(Data(host.utf8)) else { return plaintext }
        return plaintext.dropFirst(32)
    }

    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    // MARK: - 一致快照

    /// 用 SQLite backup API 把源库拷成一份一致快照，交给 `body` 读，结束即清理。
    ///
    /// 病灶：原实现只 `copyItem` 主库文件。CCD 跑着的时候是 WAL 模式，
    /// 刚写进去的 cookie 还在 `-wal` 里没合并——复制主库等于拿到一份旧数据，
    /// 而且主库自身可能正处于半写状态，三个文件之间没有任何一致性保证。
    ///
    /// 对策：backup API 全程持有源库的读事务，拷出来的必然是某个一致时点的完整快照，
    /// WAL 里未合并的页也算在内。快照落在独立临时目录（0700），`defer` 保证删干净
    static func withSnapshot<T>(of source: URL, _ body: (URL) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.missingDatabase }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pn-ccd-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // 无论 body 成败、抛错还是提前 return，快照都得跟着这一层作用域一起消失
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Cookies")

        var src: OpaquePointer?
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let detail = src.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开源库"
            sqlite3_close(src)
            throw Failure.sqlite(detail)
        }
        defer { sqlite3_close(src) }

        var dst: OpaquePointer?
        guard sqlite3_open_v2(target.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let detail = dst.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建快照库"
            sqlite3_close(dst)
            throw Failure.sqlite(detail)
        }
        defer { sqlite3_close(dst) }

        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(dst)))
        }
        // -1 = 一次拷完，中途不放锁，也就没有「拷到一半源库变了」这回事
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw Failure.sqlite("快照复制未完成（\(step)）") }
        guard finish == SQLITE_OK else { throw Failure.sqlite("快照收尾失败（\(finish)）") }

        // backup 会把源库的 journal_mode 一并带过来。快照若还是 WAL，
        // 只读连接就得去创建 -shm——它没有写权限，直接开不了库。
        // 落地成单文件的 DELETE 模式，读取端才能保持严格只读
        sqlite3_exec(dst, "PRAGMA journal_mode=DELETE", nil, nil, nil)

        return try body(target)
    }

    /// 用 libsqlite3 读 cookies 表里指定 host 的加密值（只读）
    static func readEncryptedCookies(_ url: URL, host: String) throws -> [EncryptedCookie] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开快照库"
            sqlite3_close(db)
            throw Failure.sqlite(detail)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        // 精确域名或其子域；原来的 LIKE '%' || ? 会把 notclaude.ai 也算进来
        let sql = "SELECT name, host_key, encrypted_value FROM cookies "
            + "WHERE host_key = ?1 OR host_key LIKE '%.' || ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var rows: [EncryptedCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0),
                  let hostPtr = sqlite3_column_text(stmt, 1),
                  let bytes = sqlite3_column_blob(stmt, 2) else { continue }
            rows.append(EncryptedCookie(name: String(cString: namePtr),
                                        hostKey: String(cString: hostPtr),
                                        value: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))))
        }
        return rows
    }
}
