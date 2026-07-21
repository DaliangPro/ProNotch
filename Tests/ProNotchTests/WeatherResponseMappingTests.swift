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
        sunset: [String]?? = .some(nil)
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
                         sunset: sunset ?? nil))
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
        XCTAssertEqual(mapped.now.hourly.count, 6, "逐时固定给 6 小时")
        XCTAssertEqual(mapped.now.days.map(\.code), [1, 2, 3])
        // 逐时的温度必须是原数组里连续的一段，且起点就是 startIndex（时区随机器变，只校验对齐关系）
        let temps = [20.0, 21, 22, 23, 24, 25, 26, 27]
        XCTAssertEqual(mapped.now.hourly.map(\.temp),
                       Array(temps[mapped.startIndex..<(mapped.startIndex + 6)]))
        XCTAssertTrue(mapped.now.hourly.allSatisfy { $0.hourLabel.hasSuffix("时") })
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
