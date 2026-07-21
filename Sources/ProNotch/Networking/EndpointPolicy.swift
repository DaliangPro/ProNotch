import Foundation

/// 用户自填 API 端点的安全策略，全应用唯一一处判定。
///
/// 原先四个入口（对话、模型列表、截图翻译、设置页测试）各自只判断
/// `url.scheme?.hasPrefix("http") == true`——这条件对 `http://example.com` 同样成立，
/// 于是 Bearer Key、整段对话、OCR 出来的屏幕文字都可能以明文发到公网上，
/// 任何一跳网络设备都能原样读到。Info.plist 里的 `NSAllowsArbitraryLoads`
/// 又把系统那层兜底也关掉了。
///
/// 规则：HTTPS 一律放行；HTTP 只放行本机环回（Ollama、LM Studio 等本地模型的实际用法）。
enum EndpointPolicy {
    enum Violation: LocalizedError, Equatable {
        case missingHost
        case unsupportedScheme(String)
        case insecureRemoteHost(String)
        case embeddedCredentials

        var errorDescription: String? {
            switch self {
            case .missingHost:
                return "API 地址缺少主机名"
            case .unsupportedScheme(let scheme):
                return "不支持的协议 \(scheme)：请用 https，本机服务可用 http://localhost"
            case .insecureRemoteHost(let host):
                return "拒绝以明文 HTTP 连接 \(host)：API Key 与对话会被同网络的人看到。请改用 https（本机服务除外）"
            case .embeddedCredentials:
                return "API 地址不该带用户名密码"
            }
        }
    }

    /// 校验用户自填的 API 端点。不通过即抛错，调用方不得发出请求
    static func validateUserAPIEndpoint(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw Violation.unsupportedScheme("(空)")
        }
        guard url.user == nil, url.password == nil else { throw Violation.embeddedCredentials }
        guard let host = url.host, !host.isEmpty else { throw Violation.missingHost }
        switch scheme {
        case "https":
            return
        case "http":
            guard isLoopback(host) else { throw Violation.insecureRemoteHost(host) }
        default:
            throw Violation.unsupportedScheme(scheme)
        }
    }

    /// 是否本机环回地址。大小写、IPv6 方括号、末尾点都规范化后再比
    static func isLoopback(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" { return true }
        if h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        // IPv4 环回整段 127.0.0.0/8（127.0.0.1 之外还有人用 127.0.0.2）
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "127",
           parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
           parts.compactMap({ Int($0) }).allSatisfy({ (0...255).contains($0) }) {
            return true
        }
        return false
    }
}
