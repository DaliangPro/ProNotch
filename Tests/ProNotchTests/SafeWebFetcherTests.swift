import XCTest
@testable import ProNotch

/// 联网搜索抓正文的安全边界。
///
/// 抓取目标 URL 完全由搜索引擎结果决定，等于"外部内容能指挥本机发请求"。
/// 不加约束时，一条排名靠前的恶意结果就能让 ProNotch 去读 http://127.0.0.1:11434、
/// 局域网路由器后台或云元数据接口，再把响应当搜索结果送进模型上下文。
final class SafeWebFetcherTests: XCTestCase {

    // MARK: - 假 DNS / 假传输层

    private struct FixedResolver: DNSResolving {
        var table: [String: [String]]
        func addresses(for host: String) -> [String] { table[host.lowercased()] ?? [] }
    }

    /// 按需产出的假传输层：只有消费方真的要下一块时才切出去，
    /// 这样 `delivered` 才等于"实际被读掉的字节数"。
    /// 若一次性把整个 body 灌进 stream，无论上限是否生效计数都一样，测了等于没测
    private struct StubTransport: WebTransporting, @unchecked Sendable {
        var status = 200
        var contentType: String? = "text/html; charset=utf-8"
        var body: Data
        var chunkSize = 64 * 1024

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _delivered = 0
            var delivered: Int { lock.lock(); defer { lock.unlock() }; return _delivered }
            func take(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }
                let start = _delivered; _delivered += n; return start }
        }
        let counter = Counter()

        func chunks(for request: URLRequest) async throws -> (URLResponse, AsyncThrowingStream<Data, Error>) {
            var headers: [String: String] = [:]
            if let contentType { headers["Content-Type"] = contentType }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: headers)!
            let payload = body
            let size = chunkSize
            let counter = self.counter
            let stream = AsyncThrowingStream<Data, Error> {
                let offset = counter.take(0)
                guard offset < payload.count else { return nil }
                let end = min(offset + size, payload.count)
                _ = counter.take(end - offset)
                return payload.subdata(in: offset..<end)
            }
            return (response, stream)
        }
    }

    private func html(repeating unit: String, times: Int) -> Data {
        Data(("<html><body>" + String(repeating: unit, count: times) + "</body></html>").utf8)
    }

    private func fetcher(hosts: [String: [String]] = ["safe.example.com": ["93.184.216.34"]],
                         transport: WebTransporting,
                         maxBytes: Int = SafeWebFetcher.maxBytes) -> SafeWebFetcher {
        SafeWebFetcher(resolver: FixedResolver(table: hosts), transport: transport, maxBytes: maxBytes)
    }

    // MARK: - 地址判定

    func testIP判定_内网各段全部拦下() {
        let blocked = [
            "127.0.0.1", "127.1.2.3",          // 环回整段
            "0.0.0.0",                          // 未指定
            "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.1",  // 私有
            "169.254.169.254",                  // 云元数据，SSRF 头号目标
            "100.64.0.1",                       // CGNAT
            "224.0.0.1", "239.255.255.250",     // 组播
            "::1", "::", "fe80::1", "fd00::1", "fc00::1", "ff02::1",
            "::ffff:127.0.0.1",                 // IPv4 映射绕法
        ]
        for address in blocked {
            XCTAssertTrue(IPAddressPolicy.isBlocked(address), "应拦下 \(address)")
        }
    }

    func testIP判定_公网地址放行() {
        for address in ["93.184.216.34", "8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.0.1",
                        "100.63.255.255", "100.128.0.1", "2606:2800:220:1:248:1893:25c8:1946"] {
            XCTAssertFalse(IPAddressPolicy.isBlocked(address), "应放行 \(address)")
        }
    }

    func test拒绝_IP字面量指向本机() async {
        let f = fetcher(transport: StubTransport(body: Data()))
        for raw in ["http://127.0.0.1:11434/api/tags",
                    "http://192.168.1.1/admin",
                    "http://169.254.169.254/latest/meta-data/",
                    "http://[::1]:8080/"] {
            XCTAssertThrowsError(try f.validate(URL(string: raw)!), raw) { error in
                guard case SafeWebFetcher.FetchError.blockedHost = error else {
                    return XCTFail("\(raw) 应因主机被拒，实际 \(error)")
                }
            }
        }
    }

    func test拒绝_域名解析到内网() {
        // 主机名黑名单挡不住这种：域名本身人畜无害，A 记录指回本机
        let f = fetcher(hosts: ["evil.example.com": ["127.0.0.1"]],
                        transport: StubTransport(body: Data()))
        XCTAssertThrowsError(try f.validate(URL(string: "https://evil.example.com/x")!))
    }

    func test拒绝_域名解析出多条_只要有一条内网就整体拒绝() {
        // DNS 轮询：一条公网一条内网，随机命中，"部分安全"等于不安全
        let f = fetcher(hosts: ["mixed.example.com": ["93.184.216.34", "10.0.0.5"]],
                        transport: StubTransport(body: Data()))
        XCTAssertThrowsError(try f.validate(URL(string: "https://mixed.example.com/x")!))
    }

    func test拒绝_非HTTP协议与带用户信息() {
        let f = fetcher(transport: StubTransport(body: Data()))
        XCTAssertThrowsError(try f.validate(URL(string: "file:///etc/passwd")!))
        XCTAssertThrowsError(try f.validate(URL(string: "ftp://safe.example.com/x")!))
        XCTAssertThrowsError(try f.validate(URL(string: "https://u:p@safe.example.com/x")!))
    }

    func test拒绝_域名解析不出结果() {
        let f = fetcher(hosts: [:], transport: StubTransport(body: Data()))
        XCTAssertThrowsError(try f.validate(URL(string: "https://unknown.example.com/x")!))
    }

    func test放行_正常公网域名() {
        let f = fetcher(transport: StubTransport(body: Data()))
        XCTAssertNoThrow(try f.validate(URL(string: "https://safe.example.com/article")!))
    }

    // MARK: - 响应大小上限

    func test超过字节上限_停止读取且不把剩下的读完() async throws {
        // 2 MB 响应，上限 128 KB：应当只消费到上限那一块就跳出
        let transport = StubTransport(body: html(repeating: "内容内容内容内容内容", times: 70_000),
                                      chunkSize: 32 * 1024)
        XCTAssertGreaterThan(transport.body.count, 1_000_000)
        let f = fetcher(transport: transport, maxBytes: 128 * 1024)
        let text = try await f.fetchText(url: URL(string: "https://safe.example.com/big")!, cap: 1500)

        XCTAssertLessThanOrEqual(text.count, 1500)
        XCTAssertLessThan(transport.counter.delivered, transport.body.count,
                          "整个响应都被读完了，说明上限没生效")
        XCTAssertLessThanOrEqual(transport.counter.delivered, 128 * 1024 + 32 * 1024,
                                 "最多允许多读一整块")
    }

    func test正文按cap截断() async throws {
        let transport = StubTransport(body: html(repeating: "这是一段正文。", times: 2000))
        let f = fetcher(transport: transport)
        let text = try await f.fetchText(url: URL(string: "https://safe.example.com/a")!, cap: 300)
        XCTAssertEqual(text.count, 300)
    }

    // MARK: - 内容类型与状态码

    func test拒绝_非文本内容类型() async {
        for type in ["image/png", "application/pdf", "application/octet-stream", "video/mp4"] {
            let transport = StubTransport(contentType: type, body: html(repeating: "x", times: 500))
            let f = fetcher(transport: transport)
            do {
                _ = try await f.fetchText(url: URL(string: "https://safe.example.com/f")!, cap: 1500)
                XCTFail("\(type) 应被拒绝")
            } catch let error as SafeWebFetcher.FetchError {
                XCTAssertEqual(error, .unsupportedContentType(type))
            } catch {
                XCTFail("\(type) 错误类型不对：\(error)")
            }
        }
    }

    func test放行_白名单内容类型() async throws {
        for type in ["text/html; charset=utf-8", "text/plain", "application/xhtml+xml"] {
            let transport = StubTransport(contentType: type,
                                          body: html(repeating: "有效正文内容。", times: 200))
            let f = fetcher(transport: transport)
            let text = try await f.fetchText(url: URL(string: "https://safe.example.com/f")!, cap: 1500)
            XCTAssertFalse(text.isEmpty, "\(type) 应可抓取")
        }
    }

    func test拒绝_非2xx状态码() async {
        let transport = StubTransport(status: 403, body: html(repeating: "x", times: 500))
        let f = fetcher(transport: transport)
        do {
            _ = try await f.fetchText(url: URL(string: "https://safe.example.com/f")!, cap: 1500)
            XCTFail("403 应被拒绝")
        } catch let error as SafeWebFetcher.FetchError {
            XCTAssertEqual(error, .badStatus(403))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 抓取失败只降级，不打断对话

    func test抓取失败_WebSearch降级为nil而不抛错() async {
        let f = fetcher(hosts: ["evil.example.com": ["127.0.0.1"]],
                        transport: StubTransport(body: Data()))
        let text = await WebSearch.fetchPageText(url: "https://evil.example.com/x", fetcher: f)
        XCTAssertNil(text, "抓取被拒应静默降级为保留搜索摘要")
    }
}
