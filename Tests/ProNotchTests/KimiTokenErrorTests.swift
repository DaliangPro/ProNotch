import XCTest
@testable import ProNotch

/// token 刷新失败的归因分流。
/// 由来：原先非 200 一律报「登录已过期，在终端重新 kimi login」——限流和服务端故障
/// 重登多少次都是红的，用户登完还红只会以为是 ProNotch 坏了
final class KimiTokenErrorTests: XCTestCase {
    private func err(_ code: Int, _ json: String = "{}") -> String {
        KimiQuotaLoader.tokenError(code: code, body: Data(json.utf8))
    }

    /// 实测过的真过期：400 + invalid_grant，这时候才该让用户去终端重登
    func test真过期才叫用户重新登录() {
        let s = err(400, #"{"error":"invalid_grant","error_description":"The provided authorization grant is invalid"}"#)
        XCTAssertTrue(s.contains("kimi login"), "400 invalid_grant 是凭证问题，应引导重登")
    }

    func test凭证类状态码都归到重新登录() {
        for code in [400, 401, 403] {
            XCTAssertTrue(err(code).contains("kimi login"), "\(code) 应引导重登")
        }
    }

    func test限流不许说成登录过期() {
        let s = err(429)
        XCTAssertFalse(s.contains("kimi login"), "429 是频率问题，重登无用，不能引导去终端")
        XCTAssertTrue(s.contains("限流"))
    }

    func test服务端故障不许说成登录过期() {
        for code in [500, 502, 503] {
            let s = err(code)
            XCTAssertFalse(s.contains("kimi login"), "\(code) 是人家服务器的事，重登无用")
            XCTAssertTrue(s.contains("\(code)"), "把状态码报出来才好排查")
        }
    }

    /// 200 却走到这里 = 拿不出 access_token，是数据结构问题，不是登录问题
    func test返回200但结构不对不算登录过期() {
        let s = err(200, #"{"token_type":"Bearer"}"#)
        XCTAssertFalse(s.contains("kimi login"))
        XCTAssertTrue(s.contains("数据结构"))
    }

    /// 认不出的码别硬扣「登录过期」的帽子：有 error 字段就报它，没有就报码
    func test未知状态码如实报出() {
        XCTAssertTrue(err(418, #"{"error":"teapot"}"#).contains("teapot"))
        XCTAssertTrue(err(418).contains("418"))
    }
}
