import XCTest
@testable import ProNotch

/// 上游列长对不齐时必须安全失败，不能越界崩溃。
///
/// 病灶：原实现按 `hourly.time.count` 循环，却拿同一个下标去取 `temperature_2m[i]`
/// 与 `weather_code[i]`；`daily` 那边按 `daily.time.count` 循环取 `temperature_2m_max[i]`。
/// 上游任何一列比 time 短（限流截断、字段临时下线、中间代理改写都可能），
/// 就是一次数组越界崩溃——而且崩在天气这种纯装饰功能上，代价完全不成比例。
final class WeatherResponseMappingTests: XCTestCase {

    /// 参考时刻固定，"当前整点"的定位才可复现
    private let reference = ISO8601DateFormatter().date(from: "2026-07-21T10:30:00Z")!

    // MARK: - 构造畸形响应

    private func response(
        hourTimes: [String]? = nil,
        hourTemps: [Double]? = nil,
        hourCodes: [Int]? = nil,
        hourProbs: [Int]?? = .some(nil),
        hourGusts: [Double]?? = .some(nil),
        dayTimes: [String]? = nil,
        dayMax: [Double]? = nil,
        dayMin: [Double]? = nil,
        dayCodes: [Int]?? = .some(nil),
        sunrise: [String]?? = .some(nil),
        sunset: [String]?? = .some(nil),
        utcOffset: Int? = nil
    ) -> OpenMeteoResponse {
        OpenMeteoResponse(
            current: .init(temperature_2m: 30, apparent_temperature: 33,
                           relative_humidity_2m: 60, weather_code: 1, wind_speed_10m: 9),
            hourly: .init(time: hourTimes ?? defaultHourTimes,
                          temperature_2m: hourTemps ?? [20, 21, 22, 23, 24, 25, 26, 27],
                          weather_code: hourCodes ?? [0, 1, 2, 3, 0, 1, 2, 3],
                          precipitation_probability: hourProbs ?? nil,
                          wind_gusts_10m: hourGusts ?? nil),
            daily: .init(time: dayTimes ?? ["2026-07-21", "2026-07-22", "2026-07-23"],
                         temperature_2m_max: dayMax ?? [35, 34, 33],
                         temperature_2m_min: dayMin ?? [25, 24, 23],
                         weather_code: dayCodes ?? nil,
                         precipitation_probability_max: nil,
                         sunrise: sunrise ?? nil,
                         sunset: sunset ?? nil),
            utc_offset_seconds: utcOffset)
    }

    private let defaultHourTimes = [
        "2026-07-21T06:00", "2026-07-21T07:00", "2026-07-21T08:00", "2026-07-21T09:00",
        "2026-07-21T10:00", "2026-07-21T11:00", "2026-07-21T12:00", "2026-07-21T13:00",
    ]

    // MARK: - 完整响应

    func test完整响应输出保持现有结果() throws {
        let mapped = try WeatherMapping.map(
            response(hourProbs: [10, 20, 30, 40, 50, 60, 70, 80],
                     dayCodes: [1, 2, 3],
                     sunrise: ["2026-07-21T05:14"], sunset: ["2026-07-21T19:02"]),
            city: "深圳", at: reference)

        XCTAssertEqual(mapped.now.city, "深圳")
        XCTAssertEqual(mapped.now.temperature, 30)
        XCTAssertEqual(mapped.now.todayMax, 35)
        XCTAssertEqual(mapped.now.todayMin, 25)
        XCTAssertEqual(mapped.now.sunrise, "05:14")
        XCTAssertEqual(mapped.now.sunset, "19:02")
        XCTAssertEqual(mapped.now.days.map(\.dayLabel).prefix(2), ["今天", "明天"])
        XCTAssertEqual(mapped.now.days.count, 3)
        // 数据只有 8 个时间点，够不到 24 小时的窗口，就取到末尾为止
        XCTAssertEqual(mapped.now.hourly.count, 8 - mapped.startIndex, "数据不够时取到末尾")
        XCTAssertEqual(mapped.now.days.map(\.code), [1, 2, 3])
        // 逐时的温度必须是原数组里连续的一段，且起点就是 startIndex（时区随机器变，只校验对齐关系）
        let temps = [20.0, 21, 22, 23, 24, 25, 26, 27]
        XCTAssertEqual(mapped.now.hourly.map(\.temp), Array(temps[mapped.startIndex...]))
        XCTAssertTrue(mapped.now.hourly.allSatisfy { $0.hourLabel.hasSuffix("时") })
    }

    /// 卡上一屏只露 6 列，但要能横滑看到后面——数据得给够 24 小时，
    /// 又不能一路给到 5 天（滑不到头，也没人有那个耐心）
    func test逐时最多给到24小时() throws {
        // 造 3 天整点（时间串必须单调递增，定位当前整点靠字典序）：
        // 机器时区最远也就把起点推到 20 出头，72 个点保证窗口撑得满
        let count = 72
        let times = (0..<count).map {
            String(format: "2026-07-%02dT%02d:00", 21 + $0 / 24, $0 % 24)
        }
        let mapped = try WeatherMapping.map(
            response(hourTimes: times,
                     hourTemps: (0..<count).map { 20 + Double($0) },
                     hourCodes: Array(repeating: 1, count: count)),
            city: "", at: reference)

        XCTAssertEqual(mapped.now.hourly.count, WeatherMapping.hourlyWindow)
        XCTAssertEqual(WeatherMapping.hourlyWindow, 24)
        // 仍是从当前整点起连续的一段
        XCTAssertEqual(mapped.now.hourly.first?.temp, 20 + Double(mapped.startIndex))
    }

    // MARK: - 时区

    /// 人在西海岸、看的是深圳，逐时也得从**深圳的**当前整点排起。
    ///
    /// 病灶（2026-08-16 实测）：接口 `timezone=auto` 给的是城市当地时间串，
    /// 而定位「当前整点」时拿 `DateFormatter` 默认（＝本机）时区格式化参考时刻。
    /// 本机 PDT 显示 8/16 21:13，深圳数据从 8/17 00:00 起，一比之下没有哪个整点
    /// 早于「现在」，起点直接落回数组开头——卡上就从当地 00 时排起，
    /// 后面十几个小时全是已经过去的时段。
    ///
    /// 这条用例不依赖跑测试的机器在哪个时区：无论本机是 PDT 还是 UTC，
    /// 错误实现都算不出 12，只有真按 `utc_offset_seconds` 换算才对得上。
    func test城市时区与本机不同时_定位到城市当地的当前整点() throws {
        let east8 = 8 * 3600
        // 当地 8/17 全天 24 个整点
        let times = (0..<24).map { String(format: "2026-08-17T%02d:00", $0) }
        // UTC 04:13 ＝ 东八区 12:13，当地当前整点是 12:00，下标 12
        let utcNoon = ISO8601DateFormatter().date(from: "2026-08-17T04:13:00Z")!

        let mapped = try WeatherMapping.map(
            response(hourTimes: times,
                     hourTemps: (0..<24).map { 20 + Double($0) },
                     hourCodes: Array(repeating: 1, count: 24),
                     utcOffset: east8),
            city: "深圳", at: utcNoon)

        XCTAssertEqual(mapped.startIndex, 12, "没按城市时区换算，起点会落回当地 00 时")
        XCTAssertEqual(mapped.now.hourly.first?.hourLabel, "12时")
        // 第一格的绝对时刻就是当地 12:00（＝ UTC 04:00）
        XCTAssertEqual(mapped.now.hourly.first?.hourStart,
                       ISO8601DateFormatter().date(from: "2026-08-17T04:00:00Z"))
    }

    /// 接口没给偏移量（字段下线或代理改写）时退回本机时区，照常出数不崩
    func test缺时区偏移时退回本机时区() throws {
        let mapped = try WeatherMapping.map(response(), city: "", at: reference)
        XCTAssertFalse(mapped.now.hourly.isEmpty)
        XCTAssertTrue((0..<mapped.hourlyTimes.count).contains(mapped.startIndex))
    }

    /// 每格都带绝对时刻，界面才能按「过没过去」自己往前走
    func test逐时每格都带得出整点时刻() throws {
        let mapped = try WeatherMapping.map(response(utcOffset: 0), city: "", at: reference)
        let stamps = mapped.now.hourly.map(\.hourStart)
        XCTAssertEqual(Set(stamps).count, stamps.count, "整点时刻重复，ForEach 的 id 会撞")
        XCTAssertEqual(stamps, stamps.sorted(), "整点必须递增")
    }

    // MARK: - 列长不齐

    func testTime比temperature长_按公共长度裁齐不越界() throws {
        let mapped = try WeatherMapping.map(
            response(hourTemps: [20, 21, 22]),   // time 有 8 项，温度只有 3 项
            city: "", at: reference)

        XCTAssertEqual(mapped.hourlyTimes.count, 3, "多出来的时间点一律不碰")
        XCTAssertEqual(mapped.hourlyCodes.count, 3)
        XCTAssertLessThan(mapped.startIndex, 3, "当前下标必须落在公共范围内")
        XCTAssertLessThanOrEqual(mapped.now.hourly.count, 3)
    }

    func testTime比weatherCode长_同样裁齐() throws {
        let mapped = try WeatherMapping.map(
            response(hourCodes: [0, 1]), city: "", at: reference)
        XCTAssertEqual(mapped.hourlyCodes.count, 2)
        XCTAssertEqual(mapped.now.hourly.count, 2)
    }

    func testWeatherCode为空_返回结构化错误而不是崩溃() {
        XCTAssertThrowsError(try WeatherMapping.map(
            response(hourCodes: []), city: "", at: reference)) { error in
            XCTAssertEqual(error as? WeatherMapping.Failure, .emptyHourly)
        }
    }

    func test逐时time为空_返回结构化错误() {
        XCTAssertThrowsError(try WeatherMapping.map(
            response(hourTimes: []), city: "", at: reference)) { error in
            XCTAssertEqual(error as? WeatherMapping.Failure, .emptyHourly)
        }
    }

    func testDaily的max与min长度不同_按短的那个来() throws {
        let mapped = try WeatherMapping.map(
            response(dayMax: [35, 34, 33], dayMin: [25]),   // min 只有 1 项
            city: "", at: reference)
        XCTAssertEqual(mapped.now.days.count, 1, "min 只有一天，就只输出一天")
        XCTAssertEqual(mapped.now.todayMin, 25)
    }

    func testDaily为空_返回结构化错误() {
        XCTAssertThrowsError(try WeatherMapping.map(
            response(dayMax: []), city: "", at: reference)) { error in
            XCTAssertEqual(error as? WeatherMapping.Failure, .emptyDaily)
        }
    }

    // MARK: - 可选列缺失

    func testSunrise与sunset缺失_退成空串不影响其余数据() throws {
        let mapped = try WeatherMapping.map(response(), city: "", at: reference)
        XCTAssertEqual(mapped.now.sunrise, "")
        XCTAssertEqual(mapped.now.sunset, "")
        XCTAssertFalse(mapped.now.days.isEmpty, "缺可选列不该拖垮整份数据")
    }

    func testDaily的weatherCode缺失_退默认码() throws {
        let mapped = try WeatherMapping.map(response(dayCodes: .some(nil)), city: "", at: reference)
        XCTAssertEqual(mapped.now.days.map(\.code), [3, 3, 3])
    }

    func test降水概率列比逐时短_当前小时取不到就退0() throws {
        let mapped = try WeatherMapping.map(
            response(hourProbs: [11]), city: "", at: reference)
        // 当前整点下标 > 0，probs 只有 1 项，安全下标取空 → 0
        XCTAssertEqual(mapped.now.precipProb, mapped.startIndex == 0 ? 11 : 0)
    }

    // MARK: - 当前下标

    func test当前整点定位在最后一格时不越界() throws {
        let late = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        let mapped = try WeatherMapping.map(response(), city: "", at: late)
        XCTAssertTrue((0..<mapped.hourlyTimes.count).contains(mapped.startIndex),
                      "参考时刻晚于所有数据点时也得落在范围内：\(mapped.startIndex)")
    }

    func test只有一个数据点时下标为0() throws {
        let mapped = try WeatherMapping.map(
            response(hourTimes: ["2026-07-21T10:00"], hourTemps: [20], hourCodes: [1]),
            city: "", at: reference)
        XCTAssertEqual(mapped.startIndex, 0)
        XCTAssertEqual(mapped.now.hourly.count, 1)
    }
}
