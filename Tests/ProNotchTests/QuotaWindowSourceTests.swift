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

/// Claude 用量接口解析。fixture 取自 2026-09-17 真实响应（账号信息已去掉）：
/// 官方把额度挪进了 `limits` 数组，Fable 这类限定模型的额度只在那里有，
/// 老的 `seven_day_opus` / `seven_day_sonnet` 字段全成了 null
final class ClaudeUsageParseTests: XCTestCase {
    private let live: [String: Any] = [
        "five_hour": ["utilization": 4.0, "resets_at": "2026-09-18T01:50:00.594618+00:00"],
        "seven_day": ["utilization": 29.0, "resets_at": "2026-09-19T12:00:00.594645+00:00"],
        "seven_day_opus": NSNull(), "seven_day_sonnet": NSNull(),
        "limits": [
            ["kind": "session", "group": "session", "percent": 4,
             "resets_at": "2026-09-18T01:50:00.594618+00:00", "scope": NSNull()],
            ["kind": "weekly_all", "group": "weekly", "percent": 29,
             "resets_at": "2026-09-19T12:00:00.594645+00:00", "scope": NSNull()],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 37,
             "resets_at": "2026-09-19T11:59:59.594970+00:00",
             "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]],
        ],
    ]

    func testFable额度单独列出() {
        let q = ClaudeQuotaLoader.parseUsage(live)
        XCTAssertEqual(q?.primary?.usedPercent, 4)
        XCTAssertEqual(q?.primary?.displayName, "5 小时")
        XCTAssertEqual(q?.secondary?.usedPercent, 29)
        XCTAssertEqual(q?.scopedWindows.count, 1, "Fable 那条必须单独列出来，不能并进周额度")
        XCTAssertEqual(q?.scopedWindows.first?.usedPercent, 37)
        XCTAssertEqual(q?.scopedWindows.first?.displayName, "Fable", "行首要写模型名")
        XCTAssertEqual(q?.scopedWindows.first?.windowMinutes, 10080)
        XCTAssertNotNil(q?.scopedWindows.first?.resetsAt)
    }

    /// 限定模型的额度不参与收起态与分账：菜单栏、概览看的仍是周额度
    func testFable不顶替周额度() {
        XCTAssertEqual(ClaudeQuotaLoader.parseUsage(live)?.longestWindow?.usedPercent, 29)
    }

    /// 没有 limits 的老响应照旧认两个字段
    func test老响应仍按five_hour与seven_day解析() {
        let q = ClaudeQuotaLoader.parseUsage([
            "five_hour": ["utilization": 12.0],
            "seven_day": ["utilization": 34.0, "resets_at": "2026-09-19T12:00:00Z"],
        ])
        XCTAssertEqual(q?.primary?.usedPercent, 12)
        XCTAssertEqual(q?.secondary?.usedPercent, 34)
        XCTAssertTrue(q?.scopedWindows.isEmpty ?? false)
    }

    func test认不出模型名的限定额度不显示() {
        let q = ClaudeQuotaLoader.parseUsage([
            "limits": [
                ["kind": "weekly_all", "percent": 10],
                ["kind": "weekly_scoped", "percent": 50, "scope": NSNull()],
                ["kind": "monthly_whatever", "percent": 70],
            ],
        ])
        XCTAssertEqual(q?.secondary?.usedPercent, 10)
        XCTAssertTrue(q?.scopedWindows.isEmpty ?? false, "一条没名字的百分比没法解释，不摆上去")
    }

    func test一个窗都没有时返回nil() {
        XCTAssertNil(ClaudeQuotaLoader.parseUsage(["limits": []]))
        XCTAssertNil(ClaudeQuotaLoader.parseUsage([:]))
    }
}
