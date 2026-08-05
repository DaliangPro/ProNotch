import XCTest
@testable import ProNotch

/// 刘海侧栏时钟槽位（大梁老师 2026-08-04）。
/// 侧栏只显 HH:mm，时区在设置里从常用城市里选
final class ClockSlotTests: XCTestCase {

    /// 固定时刻做基准：2026-08-04 12:00:00 UTC
    private let moment = Date(timeIntervalSince1970: 1785844800)

    func test时区各自算各自的钟点() {
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: TimeZone(identifier: "UTC")!), "12:00")
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: TimeZone(identifier: "Asia/Shanghai")!), "20:00")
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: TimeZone(identifier: "Asia/Tokyo")!), "21:00")
    }

    /// 纽约夏令时（8 月 UTC-4）：写死偏移会错，必须靠系统时区库
    func test夏令时由系统时区库处理() {
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: TimeZone(identifier: "America/New_York")!), "08:00")
        // 同一时区的冬季时刻（2026-01-04 12:00 UTC）应是 UTC-5
        let winter = Date(timeIntervalSince1970: 1767528000)
        XCTAssertEqual(ClockFormatter.text(for: winter, zone: TimeZone(identifier: "America/New_York")!), "07:00")
    }

    /// 前导零补齐：数字宽度恒定，分钟跳动时整串不左右抖
    func test前导零补齐() {
        // 2026-08-04 01:05:00 UTC
        let early = Date(timeIntervalSince1970: 1785805500)
        XCTAssertEqual(ClockFormatter.text(for: early, zone: TimeZone(identifier: "UTC")!), "01:05")
    }

    /// 12 小时制的两个边界：正午显示 12（不是 0）、上海 20:00 显示 8:00
    func test十二小时制边界() {
        // 2026-08-04 12:00 UTC ＝ 正午
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: TimeZone(identifier: "UTC")!,
                                           use24Hour: false), "12:00")
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: TimeZone(identifier: "Asia/Shanghai")!,
                                           use24Hour: false), "8:00")
        // 午夜 0 点必须显示 12 而不是 0（2026-08-04 16:00 UTC ＝ 上海次日 0 点）
        let midnight = Date(timeIntervalSince1970: 1785859200)
        XCTAssertEqual(ClockFormatter.text(for: midnight, zone: TimeZone(identifier: "Asia/Shanghai")!,
                                           use24Hour: false), "12:00")
    }

    // MARK: - 时区选项

    func test跟随系统取当前时区() {
        XCTAssertNil(ClockZone.system.identifier)
        XCTAssertEqual(ClockZone.system.timeZone, TimeZone.current)
    }

    /// 每个城市的标识符都必须是系统认得的——写错一个字母就会静默退回本地时间
    func test所有城市标识符系统均可解析() {
        for zone in ClockZone.allCases where zone != .system {
            guard let id = zone.identifier else {
                return XCTFail("\(zone.title) 缺少标识符")
            }
            XCTAssertNotNil(TimeZone(identifier: id), "\(zone.title) 的 \(id) 系统不认")
        }
    }

    func test未知存档值退回跟随系统() {
        XCTAssertEqual(ClockZone.from(nil), .system)
        XCTAssertEqual(ClockZone.from("火星基地"), .system)
        XCTAssertEqual(ClockZone.from("newYork"), .newYork)
    }

    /// 内容宽度不得顶出固定框，否则会被圆角直壁裁掉（既有约束）
    func test时钟宽度不超固定框() {
        XCTAssertLessThanOrEqual(NotchSlot.clock.neededWidth, NotchSlot.fixedSideWidth)
    }

    func test时钟出现在可选槽位里() {
        XCTAssertTrue(NotchSlot.available(agents: []).contains(.clock),
                      "时钟不依赖任何 Agent，任何情况下都该可选")
    }
}
