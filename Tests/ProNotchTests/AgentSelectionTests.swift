import XCTest
@testable import ProNotch

/// Agent 勾选集与本地检测：额度/监控台按家过滤的核心口径
final class AgentSelectionTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentKind.selectionKey)
        UserDefaults.standard.removeObject(forKey: AgentKind.knownKey)
        super.tearDown()
    }

    func test无勾选记录时按全开兜底() {
        UserDefaults.standard.removeObject(forKey: AgentKind.selectionKey)
        XCTAssertEqual(AgentKind.enabledSet(), Set(AgentKind.allCases),
                       "首启迁移前（老版本升级瞬间）读取必须全开，行为与旧版一致")
    }

    func test勾选集写入后按存值读回() {
        UserDefaults.standard.set(["claude", "grok"], forKey: AgentKind.selectionKey)
        XCTAssertEqual(AgentKind.enabledSet(), [.claude, .grok])
    }

    func test空数组表示全不勾而非兜底全开() {
        UserDefaults.standard.set([String](), forKey: AgentKind.selectionKey)
        XCTAssertEqual(AgentKind.enabledSet(), [], "用户主动全部取消 ≠ 未迁移，不得回退全开")
    }

    func test未知家名被忽略不崩溃() {
        UserDefaults.standard.set(["claude", "gemini-future"], forKey: AgentKind.selectionKey)
        XCTAssertEqual(AgentKind.enabledSet(), [.claude],
                       "降版本/手改 plist 出现未知 rawValue 时静默忽略")
    }

    func test本地检测覆盖全部家且字段自洽() {
        let results = AgentProbe.detect()
        XCTAssertEqual(results.map(\.kind), AgentKind.allCases, "检测结果逐家一行、顺序稳定")
        for r in results where !r.installed {
            XCTAssertNil(r.lastActive, "未安装的家不应有活跃时间")
        }
    }

    // MARK: - 能力矩阵（界面按此诚实渲染：不支持的能力不显示、不假装）

    func test能力矩阵与产品口径一致() {
        // 会话监控台：只有装了本地 CLI 且会话可解析的家
        XCTAssertTrue(AgentKind.claude.supportsSessions)
        XCTAssertTrue(AgentKind.codex.supportsSessions)
        XCTAssertTrue(AgentKind.kimi.supportsSessions)
        XCTAssertFalse(AgentKind.grok.supportsSessions)
        // 额度：四家全支持（Kimi 走 CLI 内置 managed-usage 同款接口）
        for kind in AgentKind.allCases {
            XCTAssertTrue(kind.supportsQuota, "\(kind) 应支持额度查询")
        }
        // 完成钩子：四家全有（Claude Stop / Codex notify / Grok hooks 目录 / Kimi config.toml）
        XCTAssertEqual(AgentKind.allCases.filter(\.supportsGlow), AgentKind.allCases)
    }

    // MARK: - 升级出新家的增量补勾（mergeNewlyDetected 纯函数）

    func test新家已安装才补勾() {
        let (enabled, known) = AgentKind.mergeNewlyDetected(
            current: [.claude], known: [.claude, .codex, .grok],
            detectedInstalled: [.claude, .kimi])
        XCTAssertEqual(enabled, [.claude, .kimi], "没见过且已安装的 Kimi 补勾一次")
        XCTAssertEqual(known, Set(AgentKind.allCases), "合并后全部家标记为已见过")
    }

    func test新家未安装不补勾() {
        let (enabled, _) = AgentKind.mergeNewlyDetected(
            current: [.claude], known: [.claude, .codex, .grok],
            detectedInstalled: [.claude])
        XCTAssertEqual(enabled, [.claude], "没装 KimiCode 就不该冒出勾选")
    }

    func test用户取消过的老家不复活() {
        let (enabled, _) = AgentKind.mergeNewlyDetected(
            current: [], known: Set(AgentKind.allCases),
            detectedInstalled: [.claude, .codex])
        XCTAssertEqual(enabled, [], "见过的家即使检测到已安装，也尊重用户的取消")
    }
}

/// Kimi 用量接口响应解析（fixture 取自 2026-07-19 真实响应，字段结构与官方 CLI 解析器对齐）
final class KimiQuotaParseTests: XCTestCase {
    private let fixture: [String: Any] = [
        "user": ["userId": "co63xxx", "region": "REGION_CN",
                 "membership": ["level": "LEVEL_INTERMEDIATE"]],
        "usage": ["limit": "100", "used": "32", "remaining": "68",
                  "resetTime": "2026-07-23T15:30:47.920838Z"],
        "limits": [[
            "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
            "detail": ["limit": "100", "used": "3", "remaining": "97",
                       "resetTime": "2026-07-19T18:30:47.920838Z"],
        ]],
        "parallel": ["limit": "20"],
    ]

    func test真实响应解析() {
        let q = KimiQuotaLoader.parse(fixture)
        XCTAssertEqual(q?.plan, "Allegretto",
                       "LEVEL_INTERMEDIATE = Allegretto 套餐（大梁老师账号核实的官方档位名）")
        XCTAssertEqual(q?.primary?.windowMinutes, 300, "5 小时滚动窗做主窗")
        XCTAssertEqual(q?.primary?.usedPercent, 3, "字符串数值 \"3\"/\"100\" 要能算成百分比")
        XCTAssertEqual(q?.secondary?.windowMinutes, 10080, "usage 总量行是周窗")
        XCTAssertEqual(q?.secondary?.usedPercent, 32)
        XCTAssertNotNil(q?.secondary?.resetsAt, "6 位微秒的 resetTime 必须能解析")
    }

    func test微秒时间戳截断解析() {
        let d = KimiQuotaLoader.parseResetTime("2026-07-23T15:30:47.920838Z")
        XCTAssertEqual(d?.timeIntervalSince1970 ?? 0, 1_784_820_647.92, accuracy: 0.01)
        XCTAssertNotNil(KimiQuotaLoader.parseResetTime("2026-07-23T15:30:47Z"), "无小数也要能解")
    }

    func testUsed缺失用remaining补() {
        let obj: [String: Any] = ["usage": ["limit": 100, "remaining": 40]]
        XCTAssertEqual(KimiQuotaLoader.parse(obj)?.primary?.usedPercent, 60,
                       "used 缺失时按 limit−remaining 补出，且数字型数值也要能收")
    }

    func test结构不识别返回nil() {
        XCTAssertNil(KimiQuotaLoader.parse(["user": ["userId": "x"]]))
        XCTAssertNil(KimiQuotaLoader.parse(["usage": ["limit": "0", "used": "0"]]),
                     "limit 为 0 视为无效窗口，不渲染除零的假数据")
    }
}
