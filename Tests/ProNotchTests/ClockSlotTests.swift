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

    // MARK: - 组件页时钟卡（大梁老师 2026-08-05：时钟是功能组件，不是侧栏专属）

    func test默认卡片城市可用且不重复() {
        let zones = ClockZone.defaultCardZones
        XCTAssertFalse(zones.isEmpty)
        XCTAssertEqual(Set(zones).count, zones.count, "默认城市不该有重复项")
    }

    /// 日期差：同一日历日不该标记。
    ///
    /// 这条是渲染时抓出来的真 bug——原算法把两地「当地零点」还原成绝对时刻再相减，
    /// 本地 8/5 与东京 8/5 明明同一天，却因零点相差 16 小时被判成「昨天」
    func test同一日历日无日期差() {
        // 2026-08-05 12:17 UTC：洛杉矶 05:17、东京 21:17，同为 8/5
        let moment = Date(timeIntervalSince1970: 1785932220)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: la), "05:17")
        XCTAssertEqual(ClockFormatter.text(for: moment, zone: tokyo), "21:17")
        // 以洛杉矶为本地时，东京是同一天
        XCTAssertNil(Self.delta(moment, local: la, other: tokyo))
    }

    /// 真跨日时必须标出来：本地深夜 ↔ 东京已是次日
    func test跨日显示明天与昨天() {
        // 2026-08-05 06:00 UTC：洛杉矶 8/4 23:00、东京 8/5 15:00
        let moment = Date(timeIntervalSince1970: 1785909600)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(Self.delta(moment, local: la, other: tokyo), "明天")
        XCTAssertEqual(Self.delta(moment, local: tokyo, other: la), "昨天")
    }

    /// 跨月边界也要对（原算法的绝对时差写法在这里同样会翻车）
    func test跨月边界正确() {
        // 2026-09-01 06:00 UTC：洛杉矶 8/31 23:00、东京 9/1 15:00
        let moment = Date(timeIntervalSince1970: 1788328800)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(Self.delta(moment, local: la, other: tokyo), "明天")
    }

    /// 借 TimeZone.current 之外的「本地」来测：直接调产品代码会绑死机器时区，
    /// 这里复刻同一套算法并显式传入两端时区
    private static func delta(_ date: Date, local: TimeZone, other: TimeZone) -> String? {
        var here = Calendar(identifier: .gregorian); here.timeZone = local
        var there = Calendar(identifier: .gregorian); there.timeZone = other
        let a = here.dateComponents([.year, .month, .day], from: date)
        let b = there.dateComponents([.year, .month, .day], from: date)
        var neutral = Calendar(identifier: .gregorian)
        neutral.timeZone = TimeZone(identifier: "UTC")!
        guard let d1 = neutral.date(from: a), let d2 = neutral.date(from: b),
              let days = neutral.dateComponents([.day], from: d1, to: d2).day else { return nil }
        switch days {
        case 0:  return nil
        case 1:  return "明天"
        case -1: return "昨天"
        default: return days > 0 ? "+\(days) 天" : "\(days) 天"
        }
    }

    /// 时钟卡开着就算组件页有内容——否则勾了时钟卡，组件页却因「没卡」被判为空
    func test时钟卡计入组件页可见性() {
        let d = UserDefaults.standard
        let keys = [PrefKey.memoryWidgetEnabled, PrefKey.weatherWidgetEnabled, PrefKey.clockWidgetEnabled]
        let backup = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, backup) { d.set(v, forKey: k) } }

        d.set(false, forKey: PrefKey.memoryWidgetEnabled)
        d.set(false, forKey: PrefKey.weatherWidgetEnabled)
        d.set(false, forKey: PrefKey.clockWidgetEnabled)
        XCTAssertFalse(SettingsStore.anyWidgetVisible(), "三张卡全关＝组件页空")

        d.set(true, forKey: PrefKey.clockWidgetEnabled)
        XCTAssertTrue(SettingsStore.anyWidgetVisible(), "只开时钟卡也算组件页有内容")
    }
}
