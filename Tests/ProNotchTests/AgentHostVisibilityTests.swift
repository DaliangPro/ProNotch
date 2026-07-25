import XCTest
import CoreGraphics
@testable import ProNotch

/// 「宿主的窗口是不是真压在最上层」判据的回归护栏（`AgentHostVisibility.ownsTopWindow` 纯函数）。
///
/// 这条判据是「前台不打扰」收窄后的另一半：宿主 == 最前台还不够，窗口得真在眼前。
/// 判错的两个方向代价不对等——多弹一张卡只是打扰，把该弹的卡吞掉则是「它明明在等我却毫无提示」，
/// 所以拿不准时一律按「不在眼前」算（返回 false → 照常弹）。
final class AgentHostVisibilityTests: XCTestCase {
    private let hostPID = 43793    // 宿主（如 Claude 桌面版，实测窗口归主进程）
    private let otherPID = 9679    // 别家 App

    private func win(pid: Int, layer: Int = 0, alpha: Double = 1,
                     size: CGSize = CGSize(width: 1280, height: 800)) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(origin: .zero, size: size)
                .dictionaryRepresentation as NSDictionary,
        ]
    }

    /// `windows` 按 CGWindowList 的顺序传（由前到后）
    private func owns(_ windows: [[String: Any]]) -> Bool {
        AgentHostVisibility.ownsTopWindow(pids: [hostPID], in: windows)
    }

    func test宿主的窗在最前时算在眼前() {
        XCTAssertTrue(owns([win(pid: hostPID), win(pid: otherPID)]))
    }

    /// 宿主还在最前台（菜单栏还是它），但别家的窗压在它上面：这时候看不见那个授权框
    func test别家的窗压在上面时不算在眼前() {
        XCTAssertFalse(owns([win(pid: otherPID), win(pid: hostPID)]))
    }

    /// 全最小化 / 窗口都在别的桌面上：`.optionOnScreenOnly` 拿到的列表里一扇都没有
    func test屏上没有真窗时不算在眼前() {
        XCTAssertFalse(owns([]))
    }

    /// 菜单栏、程序坞、控制中心、悬浮面板与自家刘海窗层级都在 20 以上，
    /// 它们常年压在所有窗上面，不排掉就永远判成「宿主不在眼前」——收窄等于把规则废掉
    func test抬升层的系统窗与自家刘海窗不参与判定() {
        XCTAssertTrue(owns([win(pid: otherPID, layer: 27),        // 自家刘海窗
                            win(pid: otherPID, layer: 25),        // 控制中心
                            win(pid: hostPID)]))
    }

    /// 实测 Claude 桌面版常年挂着 2560×30 这类细条窗：它在屏上，却不代表窗口摊在眼前
    func test细条窗不算一扇真窗() {
        XCTAssertFalse(owns([win(pid: hostPID, size: CGSize(width: 2560, height: 30))]))
        // 细条在前、别家的真窗在后：最上面那扇真窗是别家的，仍算不在眼前
        XCTAssertFalse(owns([win(pid: hostPID, size: CGSize(width: 2560, height: 30)),
                             win(pid: otherPID)]))
    }

    func test透明残窗不算一扇真窗() {
        XCTAssertTrue(owns([win(pid: otherPID, alpha: 0), win(pid: hostPID)]))
    }

    /// 一家 App 可能开着多个实例，判定要认全部进程
    func test多实例的任一进程都算宿主() {
        let second = hostPID + 1
        XCTAssertTrue(AgentHostVisibility.ownsTopWindow(pids: [hostPID, second],
                                                        in: [win(pid: second)]))
    }

    /// 字段缺失的窗（列表里偶有）不能让整条判定崩在那儿，往后接着看下一扇
    func test字段缺失的窗被跳过() {
        let broken: [String: Any] = [kCGWindowOwnerPID as String: otherPID]
        XCTAssertTrue(owns([broken, win(pid: hostPID)]))
    }
}
