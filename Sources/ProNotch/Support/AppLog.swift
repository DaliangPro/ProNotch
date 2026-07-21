import Foundation
import os

/// 统一日志出口。
///
/// 病灶：全项目原先用 `print` 记日志，而这些日志里躺着用户的搜索词、改写后的查询、
/// 搜索结果标题与 URL、自建端点地址、文件路径（`/Users/<用户名>/…` 本身就是身份信息）。
/// `print` 写的是 stdout，被系统日志收走后**永久明文留存**，
/// 任何能读日志的进程、任何一份 sysdiagnose 都看得到——用户不知道，也无从关闭。
///
/// 对策：换成 `os.Logger`。它的字符串插值默认就是 private（导出时显示 `<private>`），
/// 数值默认 public。于是：
/// - 敏感值不写，或让它保持默认 private；
/// - 计数、状态码、阶段、布尔这类诊断必需的信息显式标 `.public`，排障能力不降级。
///
/// 查看日志：`log stream --predicate 'subsystem == "com.daliang.ProNotch"' --level debug`
enum AppLog {

    /// 写死而非取 `Bundle.main.bundleIdentifier`：宿主换了（测试跑在 xctest 里、
    /// 离屏渲染实例、将来可能的扩展）subsystem 就跟着变，
    /// `log stream --predicate` 那条命令便时灵时不灵
    static let subsystem = "com.daliangpro.ProNotch"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let screenshot = Logger(subsystem: subsystem, category: "screenshot")
    static let quickActions = Logger(subsystem: subsystem, category: "quick-actions")
    static let glow = Logger(subsystem: subsystem, category: "glow")
    static let usage = Logger(subsystem: subsystem, category: "usage")
    static let widgets = Logger(subsystem: subsystem, category: "widgets")
    static let launcher = Logger(subsystem: subsystem, category: "launcher")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let debugTools = Logger(subsystem: subsystem, category: "debug-tools")
}

/// 「还想留点线索，但原值不能进日志」时的收窄工具。
///
/// 这几个函数的产物是**可以标 public 的**——它们已经把身份信息摘干净了
enum LogRedaction {

    /// 端点只留 scheme + host（+ 非默认端口）。
    /// path 常带部署标识，query 里更是经常直接躺着 key
    static func endpoint(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host else {
            return "无效地址"
        }
        let defaultPort = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        if let port = url.port, !defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// 路径只留最后一段。`/Users/<用户名>/Documents/…` 里，用户名和目录结构
    /// 都是身份信息，而排障真正要看的是「哪个文件」
    static func lastComponent(_ path: String) -> String {
        // 根目录的 lastPathComponent 是 "/" 本身，不是空串
        let name = (path as NSString).lastPathComponent
        return (name.isEmpty || name == "/") ? "(空路径)" : name
    }

    /// 错误只留 domain + code。localizedDescription 经常把完整 URL、
    /// 文件路径、甚至请求正文原样塞进去
    static func code(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)(\(ns.code))"
    }
}
