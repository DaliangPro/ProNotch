import Foundation

/// HTTP 传输层抽象：把 `URLSession.shared` 从 ChatStore 里挪出来，好在测试里观察真实发出的请求。
///
/// Provider 隔离的核心断言是"切走之后发出的请求仍带着 A 的 URL/Key/模型"——
/// 这件事只能通过截获请求本身来验证，看不到请求就只能靠肉眼读代码。
protocol HTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    /// SSE 流式请求：按行返回。非 200 时正文同样按行给出，由调用方拼错误信息
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)
}

/// 生产实现：URLSession
struct URLSessionTransport: HTTPTransporting {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let pump = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 调用方取消（点"停止"）时连带断掉底层连接，不留悬空请求
            continuation.onTermination = { _ in pump.cancel() }
        }
        return (stream, response)
    }
}

/// ChatStore 的系统依赖边界。
///
/// 只收四样真正的外部世界：配置存储、钥匙串、网络、会话落盘路径。
/// 生产默认值由 `.production` 提供，调用方一律不传；测试传入内存实现，
/// 从而不碰用户的真实 UserDefaults、钥匙串和聊天记录文件。
struct ChatEnvironment {
    var defaults: UserDefaults
    var keychain: KeychainAccessing
    var keychainService: String
    var transport: HTTPTransporting
    var conversationsURL: URL
    /// 明文 Key 迁移读取的持久化域（生产为 bundle id）
    var plaintextDomain: String?

    static var production: ChatEnvironment {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ChatEnvironment(
            defaults: .standard,
            keychain: SystemKeychain(),
            keychainService: KeychainStore.service,
            transport: URLSessionTransport(),
            conversationsURL: base.appendingPathComponent("ProNotch/chat-conversations.json"),
            plaintextDomain: Bundle.main.bundleIdentifier)
    }

    // MARK: - 钥匙串便捷读写（都走注入的实现）

    func readKey(_ account: String) -> String {
        switch keychain.read(account, service: keychainService) {
        case .success(let value): return value ?? ""
        case .failure: return ""
        }
    }

    func saveKey(_ value: String, account: String) {
        if value.isEmpty {
            _ = keychain.delete(account, service: keychainService)
        } else {
            _ = keychain.save(value, account: account, service: keychainService)
        }
    }

    func deleteKey(_ account: String) {
        _ = keychain.delete(account, service: keychainService)
    }

    /// 后台任务里读 Key 用的最小可 Sendable 切片。
    /// 后台闭包只捕获它，不整份捕获 env——UserDefaults 不是 Sendable，整份捕获会把
    /// 一个跨线程可变对象拖进并发域
    var keychainSlice: KeychainSlice { KeychainSlice(keychain: keychain, service: keychainService) }

    struct KeychainSlice: Sendable {
        let keychain: KeychainAccessing
        let service: String

        func read(_ account: String) -> String {
            switch keychain.read(account, service: service) {
            case .success(let value): return value ?? ""
            case .failure: return ""
            }
        }
    }
}
