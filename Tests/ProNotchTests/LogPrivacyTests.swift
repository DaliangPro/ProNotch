import XCTest
@testable import ProNotch

/// 日志不再把用户资料写进系统日志。
///
/// 病灶：全项目原先用 `print` 记日志，里面躺着用户的搜索词、改写后的查询、
/// 搜索结果标题与 URL、自建端点地址、`/Users/<用户名>/…` 全路径。
/// print 写 stdout，被系统日志收走后永久明文留存——用户不知道，也无从关闭。
final class LogPrivacyTests: XCTestCase {

    // MARK: - 端点收窄

    func test端点只留协议与主机() {
        XCTAssertEqual(LogRedaction.endpoint(URL(string: "https://api.example.com/v1/chat/completions")),
                       "https://api.example.com")
    }

    func test端点丢掉query_里面常直接躺着key() {
        let url = URL(string: "https://api.example.com/v1/chat?api_key=sk-abcdef123456&user=daliang")
        let text = LogRedaction.endpoint(url)
        XCTAssertEqual(text, "https://api.example.com")
        XCTAssertFalse(text.contains("sk-"), "key 一旦进日志就等于泄漏")
        XCTAssertFalse(text.contains("daliang"))
    }

    func test端点丢掉URL里的用户名密码() {
        let text = LogRedaction.endpoint(URL(string: "https://user:pass@api.example.com/v1"))
        XCTAssertFalse(text.contains("user"))
        XCTAssertFalse(text.contains("pass"))
        XCTAssertTrue(text.hasSuffix("api.example.com"))
    }

    func test非默认端口保留_排障要用() {
        XCTAssertEqual(LogRedaction.endpoint(URL(string: "http://192.168.1.9:11434/v1/chat")),
                       "http://192.168.1.9:11434")
        XCTAssertEqual(LogRedaction.endpoint(URL(string: "https://api.example.com:443/v1")),
                       "https://api.example.com", "默认端口没有信息量")
    }

    func test无效地址不崩也不外泄() {
        XCTAssertEqual(LogRedaction.endpoint(nil), "无效地址")
        XCTAssertEqual(LogRedaction.endpoint(URL(string: "file:///Users/daliang/secret.txt")),
                       "无效地址", "file: 没有 host，不能退化成打印整条路径")
    }

    // MARK: - 路径收窄

    func test路径只留文件名() {
        XCTAssertEqual(
            LogRedaction.lastComponent("/Users/daliang/Library/Application Support/ProNotch/chat.json"),
            "chat.json")
        XCTAssertFalse(
            LogRedaction.lastComponent("/Users/daliang/Documents/客户名单.csv").contains("daliang"),
            "用户名本身就是身份信息")
    }

    func test空路径不返回空串() {
        XCTAssertEqual(LogRedaction.lastComponent(""), "(空路径)")
        XCTAssertEqual(LogRedaction.lastComponent("/"), "(空路径)")
    }

    // MARK: - 错误收窄

    func test错误只留domain与code() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260,
                            userInfo: [NSFilePathErrorKey: "/Users/daliang/私密目录/a.json",
                                       NSLocalizedDescriptionKey: "打不开 /Users/daliang/私密目录/a.json"])
        let text = LogRedaction.code(error)
        XCTAssertEqual(text, "\(NSCocoaErrorDomain)(260)")
        XCTAssertFalse(text.contains("daliang"), "localizedDescription 常把整条路径带出来")
        XCTAssertFalse(text.contains("私密目录"))
    }

    func test网络错误保留可排障的码() {
        XCTAssertEqual(LogRedaction.code(URLError(.timedOut)),
                       "\(URLError.errorDomain)(\(URLError.Code.timedOut.rawValue))")
    }

    // MARK: - 全仓守卫

    private var sourceFiles: [(name: String, text: String)] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources")
            let names = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
                .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
            return try names.map {
                ($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8))
            }
        }
    }

    func test全仓不再有print调用() throws {
        let files = try sourceFiles
        XCTAssertGreaterThan(files.count, 20, "没扫到源码的话这条测试等于空转")

        for (name, text) in files {
            // 排除 footprint( 这类词中命中
            var idx = text.startIndex
            while let r = text.range(of: "print(", range: idx..<text.endIndex) {
                let ok: Bool
                if r.lowerBound == text.startIndex {
                    ok = false
                } else {
                    let prev = text[text.index(before: r.lowerBound)]
                    ok = prev.isLetter || prev.isNumber || prev == "_" || prev == "."
                }
                XCTAssertTrue(ok, "\(name) 又出现 print——它写的是 stdout，会被系统日志明文收走")
                idx = r.upperBound
            }
        }
    }

    func test日志调用里不出现Key与Cookie插值() throws {
        // 任务书明确：DEBUG 诊断也不许打印 Key 和 cookie
        let banned = ["apiKey", "braveKey", "cookie", "Cookie", "sessionKey", "secret", "password"]
        for (name, text) in try sourceFiles {
            for line in text.split(separator: "\n") where line.contains("AppLog.") {
                for word in banned {
                    XCTAssertFalse(line.contains("\\(" + word),
                                   "\(name) 把 \(word) 插进了日志：\(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    func test日志分类都挂在同一个subsystem下() {
        XCTAssertFalse(AppLog.subsystem.isEmpty)
        // 有了统一 subsystem，用户和我们才能一条命令看全/关全：
        // log stream --predicate 'subsystem == "…"'
        XCTAssertTrue(AppLog.subsystem.contains("ProNotch") || AppLog.subsystem.contains("pronotch"),
                      "实得：\(AppLog.subsystem)")
    }
}
