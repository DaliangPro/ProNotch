import XCTest
@testable import ProNotch

/// Codex 额度窗口解析：接口给几个窗就显示几个，窗口按时长排。
/// fixture 形状取自本机真实数据：Plus 的 rollout 记录（primary 300 分钟 + secondary 10080 分钟）、
/// 2026-09-16 Pro 账号 wham/usage 实测响应（只有周窗，secondary_window 为 null）
final class CodexQuotaParseTests: XCTestCase {
    private func window(_ seconds: Int, used: Double) -> [String: Any] {
        ["used_percent": used, "limit_window_seconds": seconds,
         "reset_after_seconds": 3600, "reset_at": 1_789_818_663]
    }

    func testPlus两个窗都显示且5小时窗在前() {
        let json: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": ["primary_window": window(18000, used: 28),
                           "secondary_window": window(604_800, used: 22)],
        ]
        let q = CodexQuotaLoader.parse(json)
        XCTAssertEqual(q?.plan, "Plus")
        XCTAssertEqual(q?.primary?.windowMinutes, 300, "Plus 的 5 小时窗必须显示出来")
        XCTAssertEqual(q?.primary?.usedPercent, 28)
        XCTAssertEqual(q?.secondary?.windowMinutes, 10080)
        XCTAssertEqual(q?.longestWindow?.usedPercent, 22, "收起态取周额度，不是 5 小时窗")
    }

    func test接口两窗对调也按时长归位() {
        let json: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": ["primary_window": window(604_800, used: 22),
                           "secondary_window": window(18000, used: 28)],
        ]
        let q = CodexQuotaLoader.parse(json)
        XCTAssertEqual(q?.primary?.windowMinutes, 300)
        XCTAssertEqual(q?.longestWindow?.windowMinutes, 10080,
                       "先后对调时若照搬，5 小时窗会被当成周额度露在菜单栏上")
    }

    func testPro只有周窗() {
        let json: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": ["primary_window": window(604_800, used: 64),
                           "secondary_window": NSNull()],
        ]
        let q = CodexQuotaLoader.parse(json)
        XCTAssertEqual(q?.plan, "Pro")
        XCTAssertEqual(q?.primary?.windowMinutes, 10080)
        XCTAssertNil(q?.secondary, "接口没给 5 小时窗就不显示，不按套餐名硬造")
        XCTAssertEqual(q?.longestWindow?.usedPercent, 64)
    }

    func test套餐名() {
        XCTAssertEqual(CodexQuotaLoader.planName("prolite"), "Pro Lite")
        XCTAssertEqual(CodexQuotaLoader.planName("enterprise"), "enterprise", "没见过的原样露出，不猜")
    }

    func test没有rate_limit段返回nil() {
        XCTAssertNil(CodexQuotaLoader.parse(["plan_type": "plus"]))
        XCTAssertNil(CodexQuotaLoader.parse(["rate_limit": [String: Any]()])?.primary,
                     "有段无窗时 primary 为 nil，由调用方报「没返回任何额度窗口」")
    }
}

/// 菜单栏收起态一律取周额度（大梁老师 2026-09-16 定）
final class QuotaLongestWindowTests: XCTestCase {
    private func w(_ minutes: Int, _ used: Double) -> QuotaWindow {
        QuotaWindow(usedPercent: used, usedTokens: nil, resetsAt: nil, windowMinutes: minutes, isEstimate: false)
    }

    func test两窗取周窗() {
        let q = ServiceQuota(primary: w(300, 90), secondary: w(10080, 30))
        XCTAssertEqual(q.longestWindow?.usedPercent, 30, "Claude / Kimi 收起态原先露的是 5 小时窗")
    }

    func test只有一窗就取它() {
        XCTAssertEqual(ServiceQuota(primary: w(10080, 50)).longestWindow?.usedPercent, 50)
        XCTAssertNil(ServiceQuota().longestWindow)
    }
}

/// Kimi 两条凭据路线（客户端 API Key / CLI refresh_token）
final class KimiQuotaSourceTests: XCTestCase {
    /// 结构取自 Kimi 3.2.8 的 daimon-share/daimon/kimi-code-key.json（值已替换）
    func test客户端Key文件解析() {
        let json = #"{"v":2,"keys":[{"userId":"u1","apiKey":"sk-kimi-aaa","keyId":"k1"},{"userId":"u2","apiKey":""}]}"#
        XCTAssertEqual(KimiQuotaLoader.clientAPIKeys(from: Data(json.utf8)), ["sk-kimi-aaa"], "空 Key 不拿去白请求")
    }

    func test客户端Key文件损坏返回空() {
        XCTAssertEqual(KimiQuotaLoader.clientAPIKeys(from: Data("not json".utf8)), [])
        XCTAssertEqual(KimiQuotaLoader.clientAPIKeys(from: Data(#"{"v":2}"#.utf8)), [])
    }

    func test有网络类失败就报它不叫人重登() {
        let failures = [
            KimiQuotaLoader.Failure(message: "Kimi 客户端登录已失效，打开 Kimi 重新登录", isAuth: true),
            KimiQuotaLoader.Failure(message: "无法连接 Kimi 认证服务", isAuth: false),
        ]
        XCTAssertEqual(KimiQuotaLoader.combinedError(failures), "无法连接 Kimi 认证服务")
    }

    func test只有一条路线失效就报那条的说法() {
        let cli = KimiQuotaLoader.Failure(message: "Kimi 登录已过期，在终端重新 kimi login", isAuth: true)
        XCTAssertEqual(KimiQuotaLoader.combinedError([cli]), cli.message)
        XCTAssertEqual(KimiQuotaLoader.combinedError([cli, cli]), cli.message, "同一句不重复拼")
    }

    func test两条路线都失效就把两个入口都说出来() {
        let s = KimiQuotaLoader.combinedError([
            KimiQuotaLoader.Failure(message: "Kimi 客户端登录已失效，打开 Kimi 重新登录", isAuth: true),
            KimiQuotaLoader.Failure(message: "Kimi 登录已过期，在终端重新 kimi login", isAuth: true),
        ])
        XCTAssertTrue(s.contains("Kimi 客户端") && s.contains("kimi login"))
    }

    func test只装客户端也算已安装() {
        XCTAssertTrue(AgentKind.kimi.installMarkers.contains(KimiQuotaLoader.clientDataDir))
        XCTAssertEqual(AgentKind.codex.installMarkers, [AgentKind.codex.homeDir])
    }
}
