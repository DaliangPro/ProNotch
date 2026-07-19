import XCTest
@testable import ProNotch

/// Agent 勾选集与本地检测：额度/监控台按家过滤的核心口径
final class AgentSelectionTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentKind.selectionKey)
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

    func testGrok不支持会话监控台() {
        XCTAssertFalse(AgentKind.grok.supportsSessions)
        XCTAssertTrue(AgentKind.claude.supportsSessions)
        XCTAssertTrue(AgentKind.codex.supportsSessions)
    }
}
