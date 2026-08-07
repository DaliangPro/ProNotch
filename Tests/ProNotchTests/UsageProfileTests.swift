import XCTest
import SwiftUI
@testable import ProNotch

/// 额度面板的「用量画像」（大梁老师 2026-08-07：别家菜单栏的模型选项卡数据更丰富，
/// 挑了三样做——每日柱状图、token 绝对量、最常用模型）。
///
/// 百分比只答「还能用多久」，这三样答「吃了多少、哪天吃的、谁吃的」。
/// 数据全部来自本机会话扫描，窗口固定 7 天（与额度扫描同宽，不额外增加扫描量）。
@MainActor
final class UsageProfileTests: XCTestCase {

    private let today = SessionUsage.Profile.dayKey(Date())
    private var yesterday: String { SessionUsage.Profile.dayKey(Date().addingTimeInterval(-86400)) }

    // MARK: - 数据

    func test合并各会话的天桶与模型桶() {
        let a = SessionUsage.Scanned(id: "a", tokens: 30, url: URL(fileURLWithPath: "/a"),
                                     daily: [today: 10, yesterday: 20], byModel: ["k3": 30])
        let b = SessionUsage.Scanned(id: "b", tokens: 5, url: URL(fileURLWithPath: "/b"),
                                     daily: [today: 5], byModel: ["k3": 2, "k2": 3])
        let p = SessionUsage.Profile.merge([a, b])
        XCTAssertEqual(p.today, 15, "同一天分散在多个会话里，必须加起来")
        XCTAssertEqual(p.total, 35)
        XCTAssertEqual(p.byModel, ["k3": 32, "k2": 3])
    }

    /// 「近 7 天」必须真的只算 7 天：扫描是按文件 mtime 放行的，一个 7 天内动过的
    /// 长会话会把它几个月前的天桶一起带进来，全加起来就会比柱状图之和大一截
    func test近7天合计不含窗口外的历史() {
        var p = SessionUsage.Profile()
        p.daily = [today: 10, yesterday: 5, "2020-01-01": 9_999]
        XCTAssertEqual(p.total, 15, "窗口外的历史天桶不许计入「近 7 天」")
        XCTAssertEqual(p.total, p.series(days: SessionUsage.Profile.windowDays).reduce(0) { $0 + $1.tokens },
                       "数字必须等于柱状图上那几根之和，否则用户一加就发现对不上")
    }

    /// 没跑的日子要是 0，不能是「缺一根柱子」——柱子少一根会让相邻两天看起来是连着的
    func test趋势序列补齐空档且末位是今天() {
        var p = SessionUsage.Profile()
        p.daily = [today: 7, yesterday: 3]
        let s = p.series(days: 7)
        XCTAssertEqual(s.count, 7)
        XCTAssertEqual(s.last?.day, today, "最后一根必须是今天，柱状图是从左到右推进的")
        XCTAssertEqual(s.last?.tokens, 7)
        XCTAssertEqual(s[s.count - 2].tokens, 3)
        XCTAssertEqual(s[0].tokens, 0, "七天前没跑就该是 0")
    }

    /// 并列时若按字典顺序随机取，面板每刷新一次模型名就跳一次
    func test最常用模型并列时稳定不跳() {
        var p = SessionUsage.Profile()
        p.byModel = ["zeta": 100, "alpha": 100, "mid": 99]
        XCTAssertEqual(p.topModel, "alpha")
        XCTAssertNil(SessionUsage.Profile().topModel, "没数据时不该硬挑一个")
    }

    func test模型短名只砍厂商前缀与日期后缀() {
        XCTAssertEqual(SessionUsage.Profile.shortModel("claude-sonnet-4-5-20250929"), "sonnet-4-5")
        XCTAssertEqual(SessionUsage.Profile.shortModel("gpt-5.6-sol"), "gpt-5.6-sol", "本来就短的不许动，砍了认不出")
        XCTAssertEqual(SessionUsage.Profile.shortModel("grok-4.5-build"), "grok-4.5-build")
        XCTAssertEqual(SessionUsage.Profile.shortModel("k3"), "k3")
        XCTAssertEqual(SessionUsage.Profile.shortModel("claude-20250929"), "claude-20250929",
                       "砍完只剩空的话，宁可原样显示")
    }

    func testtoken缩写到三位有效数字() {
        XCTAssertEqual(SessionUsage.Profile.formatTokens(0), "0")
        XCTAssertEqual(SessionUsage.Profile.formatTokens(999), "999")
        XCTAssertEqual(SessionUsage.Profile.formatTokens(24_500), "24.5K")
        XCTAssertEqual(SessionUsage.Profile.formatTokens(1_100_000), "1.1M")
        XCTAssertEqual(SessionUsage.Profile.formatTokens(2_900_000_000), "2.9B")
    }

    // MARK: - 版式（面板内容宽固定 288pt = 320 − 左右各 16）

    /// 一天都没跑的家不该在面板上留一块空白
    func test没有数据时整块不占位() {
        XCTAssertEqual(blockHeight(SessionUsage.Profile()), 0, accuracy: 0.01)
    }

    /// 长模型名必须截断而不是换行——换行会把这块撑高，底下的开关跟着往下跑
    func test超长模型名不把版式撑高() {
        let short = blockHeight(profile(model: "k3"))
        let long = blockHeight(profile(model: "claude-sonnet-4-5-20250929-preview-experimental-long"))
        XCTAssertGreaterThan(short, 0)
        XCTAssertEqual(short, long, accuracy: 0.01, "长模型名应被截断，不该让这块变高")
    }

    /// 柱状图是归一化的：吃 1M 和吃 1B，图形高度必须一样，只有数字变
    func test柱状图高度不随绝对值变化() {
        XCTAssertEqual(blockHeight(profile(scale: 1)), blockHeight(profile(scale: 1_000_000)), accuracy: 0.01)
    }

    // MARK: - 工具

    private func profile(model: String = "k3", scale: Int = 1000) -> SessionUsage.Profile {
        var p = SessionUsage.Profile()
        p.daily = [today: 3 * scale, yesterday: scale]
        p.byModel = [model: 4 * scale]
        return p
    }

    private func blockHeight(_ p: SessionUsage.Profile) -> CGFloat {
        let host = NSHostingView(rootView: UsageProfileBlock(profile: p, tint: .cyan).frame(width: 288))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
