import XCTest
import CommonCrypto
import SQLite3
@testable import ProNotch

/// Cookie 读取的两处病灶：快照不一致、完整性头无条件截断。
///
/// 其一：原实现只 `copyItem` 主库文件。CCD 跑着的时候库是 WAL 模式，
/// 刚写进去的 cookie 还躺在 `-wal` 里没合并——复制主库拿到的是旧数据，
/// 三个文件之间也没有任何一致性保证。
///
/// 其二：明文只要长过 32 字节就无条件砍掉开头 32 字节。旧版数据库根本没有
/// 那个 `SHA256(host)` 完整性头，于是好端端的 cookie 被砍掉一截，
/// 最后以「登录失效」的面目出现，排查方向全错。
final class CCDCookieReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProNotchCookie-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - host hash 剥离

    func test带正确hostHash的明文被剥掉头部() {
        let host = ".claude.ai"
        let value = Data("sk-ant-sid01-abcdefghijklmnop".utf8)
        let plaintext = CCDCookieReader.sha256(Data(host.utf8)) + value

        XCTAssertEqual(CCDCookieReader.stripHostHash(plaintext, host: host), value)
    }

    func test长度大于32但hash对不上_一个字节都不许砍() {
        // 旧版数据库的明文就是裸 cookie 值，长度轻松过 32
        let legacy = Data("sessionKey-legacy-format-1234567890-abcdefghijklmnop".utf8)
        XCTAssertGreaterThan(legacy.count, 32)

        XCTAssertEqual(CCDCookieReader.stripHostHash(legacy, host: ".claude.ai"), legacy,
                       "没有完整性头的旧数据，砍掉前 32 字节就是把 cookie 弄坏")
    }

    func test换一个host则hash不匹配_同样保留完整明文() {
        let plaintext = CCDCookieReader.sha256(Data(".claude.ai".utf8)) + Data("value-here".utf8)
        XCTAssertEqual(CCDCookieReader.stripHostHash(plaintext, host: ".example.com"), plaintext,
                       "头是给别的域算的，说明这不是我们认识的格式，别动它")
    }

    func test明文不足32字节时原样返回() {
        let short = Data("abc".utf8)
        XCTAssertEqual(CCDCookieReader.stripHostHash(short, host: ".claude.ai"), short)
    }

    func test恰好32字节也不砍() {
        // 全砍掉只会得到空串，那还不如原样交出去让上层判断
        let exact = CCDCookieReader.sha256(Data(".claude.ai".utf8))
        XCTAssertEqual(CCDCookieReader.stripHostHash(exact, host: ".claude.ai"), exact)
    }

    // MARK: - 解密全程

    func test加密解密往返_带完整性头() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let host = ".claude.ai"
        let secret = "sk-ant-sid01-round-trip-value"
        let plaintext = CCDCookieReader.sha256(Data(host.utf8)) + Data(secret.utf8)
        let blob = try encrypt(plaintext, key: key)

        XCTAssertEqual(CCDCookieReader.decrypt(blob, key: key, host: host), secret)
    }

    func test加密解密往返_旧格式无完整性头() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let legacy = "sessionKey-legacy-format-1234567890-abcdefghijklmnop"
        let blob = try encrypt(Data(legacy.utf8), key: key)

        XCTAssertEqual(CCDCookieReader.decrypt(blob, key: key, host: ".claude.ai"), legacy,
                       "旧库的完整值必须原样解出来")
    }

    // MARK: - 一致快照

    func testWAL里还没合并的新cookie也能从快照读到() throws {
        let db = tempDir.appendingPathComponent("Cookies")
        let handle = try openWALDatabase(at: db)
        // 关键：不 checkpoint。这一行此刻只存在于 -wal，主库文件里没有
        try exec(handle, """
            INSERT INTO cookies (name, host_key, encrypted_value)
            VALUES ('sessionKey', '.claude.ai', x'0102030405')
            """)

        let rows = try CCDCookieReader.withSnapshot(of: db) {
            try CCDCookieReader.readEncryptedCookies($0, host: "claude.ai")
        }
        sqlite3_close(handle)

        XCTAssertEqual(rows.count, 1, "只复制主库文件的话这里会是 0 条")
        XCTAssertEqual(rows.first?.name, "sessionKey")
        XCTAssertEqual(rows.first?.hostKey, ".claude.ai", "完整性头哈希的是这一行自己的 host_key")
        XCTAssertEqual(rows.first?.value, Data([1, 2, 3, 4, 5]))
    }

    func test只复制主库文件确实读不到WAL里的行() throws {
        // 反证上一条测试考的是真问题，不是摆设
        let db = tempDir.appendingPathComponent("Cookies")
        let handle = try openWALDatabase(at: db)
        try exec(handle, """
            INSERT INTO cookies (name, host_key, encrypted_value)
            VALUES ('sessionKey', '.claude.ai', x'0102030405')
            """)

        let naive = tempDir.appendingPathComponent("naive-copy")
        try FileManager.default.copyItem(at: db, to: naive)
        let rows = (try? CCDCookieReader.readEncryptedCookies(naive, host: "claude.ai")) ?? []
        sqlite3_close(handle)

        XCTAssertTrue(rows.isEmpty, "老做法要么开不了库，要么读不到 WAL 里的行——总之丢数据")
    }

    func test临时快照目录用完即清理() throws {
        let db = tempDir.appendingPathComponent("Cookies")
        let handle = try openWALDatabase(at: db)
        sqlite3_close(handle)

        var snapshotDir: URL?
        _ = try CCDCookieReader.withSnapshot(of: db) { url -> Int in
            snapshotDir = url.deletingLastPathComponent()
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "读的时候快照得在")
            return 0
        }
        XCTAssertNotNil(snapshotDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotDir!.path),
                       "快照里是解密前的 cookie，读完必须立刻删干净")
    }

    func test闭包抛错时临时目录同样被清理() throws {
        let db = tempDir.appendingPathComponent("Cookies")
        let handle = try openWALDatabase(at: db)
        sqlite3_close(handle)

        struct Boom: Error {}
        var snapshotDir: URL?
        XCTAssertThrowsError(try CCDCookieReader.withSnapshot(of: db) { url -> Int in
            snapshotDir = url.deletingLastPathComponent()
            throw Boom()
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotDir!.path))
    }

    func test查询不匹配相似域名() throws {
        let db = tempDir.appendingPathComponent("Cookies")
        let handle = try openWALDatabase(at: db)
        try exec(handle, """
            INSERT INTO cookies (name, host_key, encrypted_value) VALUES
              ('good', '.claude.ai', x'01'),
              ('exact', 'claude.ai', x'02'),
              ('evil', 'notclaude.ai', x'03')
            """)

        let rows = try CCDCookieReader.withSnapshot(of: db) {
            try CCDCookieReader.readEncryptedCookies($0, host: "claude.ai")
        }
        sqlite3_close(handle)

        XCTAssertEqual(Set(rows.map(\.name)), ["good", "exact"],
                       "后缀匹配会把 notclaude.ai 一起捞上来")
    }

    // MARK: - 失败诊断

    func test库不存在时给出诊断而不是崩溃() {
        let missing = tempDir.appendingPathComponent("nope/Cookies")
        XCTAssertThrowsError(try CCDCookieReader.withSnapshot(of: missing) { _ in 0 }) { error in
            XCTAssertEqual(error as? CCDCookieReader.Failure, .missingDatabase)
        }
    }

    func test不是数据库的文件给出SQLite诊断且不含内容() throws {
        let junk = tempDir.appendingPathComponent("Cookies")
        try Data("这不是数据库，里面有 sk-ant-sid01-secret".utf8).write(to: junk)

        XCTAssertThrowsError(try CCDCookieReader.withSnapshot(of: junk) {
            try CCDCookieReader.readEncryptedCookies($0, host: "claude.ai")
        }) { error in
            guard let failure = error as? CCDCookieReader.Failure else {
                return XCTFail("应是结构化的 Failure，实得 \(error)")
            }
            XCTAssertFalse(failure.message.contains("sk-ant-sid01-secret"),
                           "诊断里绝不能带出库里的内容")
        }
    }

    // MARK: - 辅助

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: 16)
        let keyBytes = [UInt8](key)
        let inBytes = [UInt8](plaintext)
        var out = [UInt8](repeating: 0, count: inBytes.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding),
                             keyBytes, keyBytes.count, iv,
                             inBytes, inBytes.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw NSError(domain: "encrypt", code: Int(status)) }
        return Data("v10".utf8) + Data(out.prefix(moved))
    }

    /// 建一个 WAL 模式的 cookies 库，**故意不 checkpoint**
    private func openWALDatabase(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle = db else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: "建库失败"])
        }
        try exec(handle, "PRAGMA journal_mode=WAL")
        try exec(handle, """
            CREATE TABLE cookies (name TEXT, host_key TEXT, encrypted_value BLOB)
            """)
        return handle
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        // journal_mode 是查询语句，用 exec 跑没问题；出错才看 err
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "未知"
            sqlite3_free(err)
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
