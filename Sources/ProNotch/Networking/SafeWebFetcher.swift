import Foundation

/// IP 地址的安全分类：判断一个地址是否指向"内网/本机"这类不该被外部输入牵着去访问的目标。
///
/// 联网搜索会把搜索引擎返回的 URL 直接拿去抓正文。这些 URL 完全由外部内容决定——
/// 只要有人能让某个词条排到前三，就能让 ProNotch 去访问 http://127.0.0.1:11434、
/// http://192.168.1.1/admin 或云环境的 169.254.169.254 元数据接口，
/// 再把返回内容当作"搜索结果"喂进模型上下文，等于把用户内网当侦察工具用。
enum IPAddressPolicy {
    /// 是否属于禁止访问的范围：环回、私有、链路本地、CGNAT、组播、未指定、IPv6 ULA/链路本地
    static func isBlocked(_ address: String) -> Bool {
        var raw = address.lowercased()
        if raw.hasPrefix("["), raw.hasSuffix("]") { raw = String(raw.dropFirst().dropLast()) }
        if let zone = raw.firstIndex(of: "%") { raw = String(raw[raw.startIndex..<zone]) }
        if raw.contains(":") { return isBlockedIPv6(raw) }
        return isBlockedIPv4(raw)
    }

    /// 纯 IP 字面量才返回四段/冒号形式；域名返回 nil
    static func isIPLiteral(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.contains(":") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isBlockedIPv4(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return true }
        let (a, b) = (parts[0], parts[1])
        if a == 0 { return true }                                  // 0.0.0.0/8 未指定
        if a == 10 { return true }                                 // 私有
        if a == 127 { return true }                                // 环回
        if a == 169, b == 254 { return true }                      // 链路本地（含云元数据 169.254.169.254）
        if a == 172, (16...31).contains(b) { return true }         // 私有
        if a == 192, b == 168 { return true }                      // 私有
        if a == 100, (64...127).contains(b) { return true }        // CGNAT
        if a >= 224 { return true }                                // 组播与保留段
        return false
    }

    private static func isBlockedIPv6(_ raw: String) -> Bool {
        if raw == "::" || raw == "::1" { return true }             // 未指定 / 环回
        if raw.hasPrefix("fe8") || raw.hasPrefix("fe9")
            || raw.hasPrefix("fea") || raw.hasPrefix("feb") { return true }   // fe80::/10 链路本地
        if raw.hasPrefix("fc") || raw.hasPrefix("fd") { return true }         // fc00::/7 唯一本地
        if raw.hasPrefix("ff") { return true }                                // ff00::/8 组播
        // ::ffff:127.0.0.1 这类 IPv4 映射地址，按其 IPv4 部分判定
        if let mapped = raw.split(separator: ":").last, mapped.contains(".") {
            return isBlockedIPv4(String(mapped))
        }
        return false
    }
}

/// DNS 解析抽象：域名要在抓取前解析出真实地址再判定，
/// 否则 evil.example.com → A 记录 127.0.0.1 这种绕法直接穿过所有主机名黑名单
protocol DNSResolving: Sendable {
    func addresses(for host: String) -> [String]
}

struct SystemDNSResolver: DNSResolving {
    func addresses(for host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let head = info else { return [] }
        defer { freeaddrinfo(head) }
        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, socklen_t(current.pointee.ai_addrlen),
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buffer))
            }
            node = current.pointee.ai_next
        }
        return out
    }
}

/// 抓网页正文用的字节流传输层（可注入，便于测上限与内容类型）
protocol WebTransporting: Sendable {
    func chunks(for request: URLRequest) async throws -> (URLResponse, AsyncThrowingStream<Data, Error>)
}

/// 带安全策略的网页正文抓取。
///
/// 相比原先直接 `URLSession.shared.data(for:)`，这里多了四道闸：
/// 目标地址校验（含 DNS 结果）、重定向逐跳复检、响应大小硬上限、内容类型白名单。
struct SafeWebFetcher {
    enum FetchError: LocalizedError, Equatable {
        case blockedScheme(String)
        case blockedHost(String)
        case badStatus(Int)
        case unsupportedContentType(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .blockedScheme(let s):        return "不支持的协议 \(s)"
            case .blockedHost(let h):          return "拒绝抓取内网或本机地址 \(h)"
            case .badStatus(let code):         return "网页返回 \(code)"
            case .unsupportedContentType(let t): return "非文本内容 \(t)"
            case .tooLarge:                    return "网页超出大小上限"
            }
        }
    }

    /// 单页原始响应上限：正文提取后还要再受 WebSearch.perResultCap 约束，
    /// 这里挡的是"下载阶段"——不设限时一个几百 MB 的文件能把内存吃穿
    static let maxBytes = 512 * 1024
    /// 只有这三类才值得当正文抓；其余（图片、PDF、二进制）保留搜索摘要
    static let allowedContentTypes = ["text/html", "application/xhtml+xml", "text/plain"]

    let resolver: DNSResolving
    let transport: WebTransporting
    let maxBytes: Int

    init(resolver: DNSResolving = SystemDNSResolver(),
         transport: WebTransporting? = nil,
         maxBytes: Int = SafeWebFetcher.maxBytes) {
        self.resolver = resolver
        self.maxBytes = maxBytes
        self.transport = transport ?? URLSessionWebTransport(resolver: resolver, maxBytes: maxBytes)
    }

    /// 目标是否允许抓取：协议、用户信息、IP 字面量、DNS 解析结果逐项判
    func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else { throw FetchError.blockedScheme("(空)") }
        guard scheme == "https" || scheme == "http" else { throw FetchError.blockedScheme(scheme) }
        guard url.user == nil, url.password == nil else { throw FetchError.blockedHost("(带用户信息)") }
        guard let host = url.host, !host.isEmpty else { throw FetchError.blockedHost("(空)") }

        if IPAddressPolicy.isIPLiteral(host) {
            guard !IPAddressPolicy.isBlocked(host) else { throw FetchError.blockedHost(host) }
            return
        }
        // 域名先解析：只要有任何一条记录落在内网，整体拒绝（DNS 轮询绕过防不住"部分安全"）
        let addresses = resolver.addresses(for: host)
        guard !addresses.isEmpty else { throw FetchError.blockedHost(host) }
        guard !addresses.contains(where: IPAddressPolicy.isBlocked) else {
            throw FetchError.blockedHost(host)
        }
    }

    /// 抓取并提取正文。任何失败都只是"这条没抓到"，由调用方降级为搜索摘要
    func fetchText(url: URL, cap: Int) async throws -> String {
        try validate(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(WebSearch.userAgent, forHTTPHeaderField: "User-Agent")
        let (response, stream) = try await transport.chunks(for: request)

        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw FetchError.badStatus(http.statusCode)
            }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            // 缺 Content-Type 时按 HTML 处理（很多老站不发这个头），有则必须在白名单里
            if !type.isEmpty, !Self.allowedContentTypes.contains(type.lowercased()) {
                throw FetchError.unsupportedContentType(type)
            }
        }

        var data = Data()
        for try await chunk in stream {
            data.append(chunk)
            if data.count >= maxBytes {
                data = data.prefix(maxBytes)   // 到顶即停，不把剩下的读完
                break
            }
        }
        guard let html = String(data: data, encoding: .utf8) else { return "" }
        let text = WebSearch.htmlToText(html)
        guard text.count > 200 else { return "" }   // 太短说明是壳页面，不如保留搜索摘要
        return String(text.prefix(cap))
    }
}

/// 重定向复检委托。
///
/// 重定向必须自己接管——只校验首个 URL 是没用的：
/// 攻击者给一个正常的公网地址、由服务端 302 到 127.0.0.1 即可绕过全部前置检查。
/// 只持有一个不可变的 resolver，无可变状态
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let validator: SafeWebFetcher

    init(resolver: DNSResolving) {
        // 只用它的 validate，传输层不参与，故此处的 transport 永不被调用
        self.validator = SafeWebFetcher(resolver: resolver, transport: NeverTransport())
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? validator.validate(url)) != nil else {
            completionHandler(nil)   // 跳转目标不安全：就地掐断，不跟过去
            return
        }
        completionHandler(request)
    }
}

/// 占位传输层：给只做校验的场合用，被调用即说明用错了
private struct NeverTransport: WebTransporting {
    func chunks(for request: URLRequest) async throws -> (URLResponse, AsyncThrowingStream<Data, Error>) {
        throw SafeWebFetcher.FetchError.blockedScheme("(仅校验)")
    }
}

/// 生产实现：URLSession + 重定向逐跳复检 + 下载阶段自身封顶。
///
/// 自身封顶不是和 `SafeWebFetcher.maxBytes` 重复——`AsyncThrowingStream` 默认无界缓冲，
/// 泵读的速度不受消费方约束。只靠消费方 break 的话，几百 MB 的响应在取消生效前
/// 已经进了内存。所以泵自己也必须在到顶时收手。
struct URLSessionWebTransport: WebTransporting {
    private let session: URLSession
    private let maxBytes: Int

    init(resolver: DNSResolving, maxBytes: Int = SafeWebFetcher.maxBytes) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        // URLSession 会强引用 delegate，无需自己保管
        self.session = URLSession(configuration: config,
                                  delegate: RedirectGuard(resolver: resolver),
                                  delegateQueue: nil)
        self.maxBytes = maxBytes
    }

    func chunks(for request: URLRequest) async throws -> (URLResponse, AsyncThrowingStream<Data, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let cap = maxBytes
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let pump = Task {
                do {
                    var buffer = Data()
                    var total = 0
                    for try await byte in bytes {
                        buffer.append(byte)
                        total += 1
                        if buffer.count >= 16 * 1024 {
                            continuation.yield(buffer)
                            buffer = Data()
                        }
                        if total >= cap { break }   // 到顶收手，不再拉取剩余响应
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        return (response, stream)
    }
}
