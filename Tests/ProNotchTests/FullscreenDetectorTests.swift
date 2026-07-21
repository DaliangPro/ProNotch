import XCTest
import CoreGraphics
@testable import ProNotch

/// 全屏检测判据的回归护栏（FullscreenDetector.hasFullscreen 纯函数）：
/// 识别抬升层放映幕布、排除自家窗口防误判、整屏容差、层级/透明度过滤。
/// 修复背景：Keynote 放映幕布挂在 layer>0，旧判据只认 layer==0 → 漏检。
final class FullscreenDetectorTests: XCTestCase {
    /// 目标屏（CGWindow 坐标系，左上原点）
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let selfPID = 4321   // 假定「自家」进程号
    private let dockPID = 1234   // 程序坞：每屏一个整屏背景窗，同样要排除
    private let notifPID = 5678  // 通知中心：弹通知时整屏铺开，同样要排除
    private let otherPID = 9999  // 别家进程

    private func win(pid: Int, layer: Int, alpha: Double, bounds: CGRect) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
    }

    private func detect(_ windows: [[String: Any]]) -> Bool {
        FullscreenDetector.hasFullscreen(in: windows, target: screen,
                                         excludingPIDs: [selfPID, dockPID, notifPID])
    }

    func test别家普通层整屏窗算全屏() {
        XCTAssertTrue(detect([win(pid: otherPID, layer: 0, alpha: 1, bounds: screen)]))
    }

    func test别家抬升层整屏幕布算全屏() {
        // Keynote 放映幕布挂在抬升层（layer>0），放宽判据后应识别为全屏
        XCTAssertTrue(detect([win(pid: otherPID, layer: 25, alpha: 1, bounds: screen)]))
    }

    func test自家整屏窗被排除() {
        // 自家全屏光晕窗也整屏等大，若不排除会把自己误判成「别的全屏应用」而永久隐藏刘海
        XCTAssertFalse(detect([win(pid: selfPID, layer: 25, alpha: 1, bounds: screen)]))
    }

    func test程序坞整屏背景窗被排除() {
        // 实测：副屏上程序坞挂着一个与整屏严丝合缝的窗（layer 20），不排除就会让副屏刘海
        // 永久隐藏——现象是「副屏根本没有刘海」，看不出与全屏检测有关
        XCTAssertFalse(detect([win(pid: dockPID, layer: 20, alpha: 1, bounds: screen)]))
    }

    func test通知中心整屏宿主窗被排除() {
        // 实测（2026-07-20）：来一条通知时，通知中心在主屏铺开 layer 21 / alpha 1.0 的
        // 整屏窗，约 4 秒后消失。不排除就会被当成全屏应用 → 刘海隐藏、通知过去又自己回来，
        // 现象是「正打着字刘海突然没了」，且只在恰好来通知时复现，极难抓
        XCTAssertFalse(detect([win(pid: notifPID, layer: 21, alpha: 1, bounds: screen)]))
    }

    /// 反向断言：证明上面那条排除是必需的——同一个窗不排除时确实会被判成全屏。
    /// 若判据将来收窄到认不出它，这条会失败，提醒排除名单可以相应精简
    func test通知中心不排除时确实会被误判() {
        let notifWindow = win(pid: notifPID, layer: 21, alpha: 1, bounds: screen)
        XCTAssertTrue(FullscreenDetector.hasFullscreen(in: [notifWindow], target: screen,
                                                       excludingPIDs: [selfPID, dockPID]),
                      "通知中心的整屏窗本就命中判据，所以必须显式排除")
    }

    func test非整屏窗不算全屏() {
        let small = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertFalse(detect([win(pid: otherPID, layer: 0, alpha: 1, bounds: small)]))
    }

    func test透明度过低不算() {
        XCTAssertFalse(detect([win(pid: otherPID, layer: 0, alpha: 0.0, bounds: screen)]))
    }

    func test负层桌面元素不算() {
        // layer<0（桌面壁纸/图标层）即便整屏也不是覆盖式全屏
        XCTAssertFalse(detect([win(pid: otherPID, layer: -1, alpha: 1, bounds: screen)]))
    }

    func test整屏容差内命中_容差外不命中() {
        // 宽差 3pt（≤4 容差）算铺满
        let within = CGRect(x: 0, y: 0, width: 1509, height: 982)
        XCTAssertTrue(detect([win(pid: otherPID, layer: 0, alpha: 1, bounds: within)]))
        // 宽差 10pt 超容差 → 不是全屏
        let outside = CGRect(x: 0, y: 0, width: 1502, height: 982)
        XCTAssertFalse(detect([win(pid: otherPID, layer: 0, alpha: 1, bounds: outside)]))
    }

    func test空窗口列表不算全屏() {
        XCTAssertFalse(detect([]))
    }

    func test多窗混合命中任一整屏别家窗() {
        let small = CGRect(x: 100, y: 100, width: 800, height: 600)
        let windows = [
            win(pid: selfPID, layer: 25, alpha: 1, bounds: screen),   // 自家整屏 → 排除
            win(pid: otherPID, layer: 0, alpha: 1, bounds: small),    // 别家小窗 → 不算
            win(pid: otherPID, layer: 3, alpha: 1, bounds: screen),   // 别家整屏抬升层 → 命中
        ]
        XCTAssertTrue(detect(windows))
    }
}
