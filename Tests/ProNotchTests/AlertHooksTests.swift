import XCTest
@testable import ProNotch

/// 完成提醒钩子的安装判定：总开关 ∧ 已监控 ∧ 勾了提醒。
/// 重点保证「总开关关再开，按家做的勾选不丢」——旧实现重开会把所有已监控家全装回
final class AlertHooksTests: XCTestCase {
    func testMasterOffInstallsNothing() {
        XCTAssertTrue(SettingsStore.hooksToInstall(glowEnabled: false,
                                                   enabled: [.claude, .codex],
                                                   alert: [.claude, .codex]).isEmpty)
    }

    func testOnlyMonitoredAndSelected() {
        let want = SettingsStore.hooksToInstall(glowEnabled: true,
                                                enabled: [.claude, .codex, .grok],
                                                alert: [.claude, .grok, .kimi])
        XCTAssertEqual(want, [.claude, .grok])
    }

    func testReenableKeepsSelection() {
        let alert: Set<AgentKind> = [.codex]
        let enabled: Set<AgentKind> = [.claude, .codex, .grok, .kimi]
        XCTAssertTrue(SettingsStore.hooksToInstall(glowEnabled: false, enabled: enabled, alert: alert).isEmpty)
        XCTAssertEqual(SettingsStore.hooksToInstall(glowEnabled: true, enabled: enabled, alert: alert), [.codex])
    }
}
