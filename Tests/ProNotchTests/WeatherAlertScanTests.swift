import XCTest
@testable import ProNotch

/// 恶劣天气预警扫描的回归护栏：判据（WMO 码 + 阵风阈值）、只看未来、
/// 3 小时窗口边界、已报去重、同小时恶劣码优先于大风
final class WeatherAlertScanTests: XCTestCase {
    /// 逐时时间轴：17 时为当前小时（fromIndex 0），之后每格 +1 小时
    private let times = ["2026-07-18T17:00", "2026-07-18T18:00", "2026-07-18T19:00",
                         "2026-07-18T20:00", "2026-07-18T21:00"]

    private func scan(codes: [Int], gusts: [Double]? = nil, probs: [Int]? = nil,
                      alerted: Set<String> = []) -> WeatherAlertScan.Hit? {
        WeatherAlertScan.firstHit(times: times, codes: codes, gusts: gusts, probs: probs,
                                  fromIndex: 0, withinHours: 3, alerted: alerted)
    }

    func test雷暴在两小时后命中() {
        let hit = scan(codes: [2, 3, 95, 3, 3], probs: [0, 10, 85, 20, 0])
        XCTAssertEqual(hit?.hoursAhead, 2)
        XCTAssertEqual(hit?.kind, "雷阵雨")
        XCTAssertEqual(hit?.fingerprint, "2026-07-18T19:00|雷阵雨")
        XCTAssertEqual(hit?.detail, "降水概率 85%")
        XCTAssertEqual(hit?.symbol, "cloud.bolt.rain.fill")
    }

    func test窗口外第四小时不报() {
        XCTAssertNil(scan(codes: [2, 3, 3, 3, 95]))
    }

    func test当前小时正在下的不报() {
        // 眼下的恶劣天气自己看得见，预警只管「未来」
        XCTAssertNil(scan(codes: [95, 2, 2, 2, 2]))
    }

    func test已报过的跳过_后续新事件仍报() {
        let alerted: Set<String> = ["2026-07-18T18:00|大雨"]
        XCTAssertNil(scan(codes: [2, 65, 2, 2, 2], alerted: alerted))
        // 18 时大雨已报、20 时大雪没报过 → 返回大雪
        let hit = scan(codes: [2, 65, 2, 75, 2], alerted: alerted)
        XCTAssertEqual(hit?.kind, "大雪")
        XCTAssertEqual(hit?.hoursAhead, 3)
    }

    func test阵风达六级报大风_未达不报() {
        // 6 级线（≥ 39 km/h，大梁老师定）：45 → 6 级命中；35（5 级）不报
        let hit = scan(codes: [2, 2, 2, 2, 2], gusts: [10, 45, 12, 11, 10])
        XCTAssertEqual(hit?.kind, "6 级大风")
        XCTAssertEqual(hit?.detail, "阵风 45 km/h")
        XCTAssertEqual(hit?.fingerprint, "2026-07-18T18:00|大风")
        XCTAssertNil(scan(codes: [2, 2, 2, 2, 2], gusts: [10, 35, 12, 11, 10]))
    }

    func test同一小时恶劣码优先于大风() {
        let hit = scan(codes: [2, 95, 2, 2, 2], gusts: [10, 80, 12, 11, 10])
        XCTAssertEqual(hit?.kind, "雷阵雨")
    }

    func test无恶劣天气返回空() {
        XCTAssertNil(scan(codes: [0, 1, 2, 3, 61], probs: [0, 0, 20, 30, 40]))
    }

    func test蒲福风级换算边界() {
        XCTAssertEqual(WeatherAlertScan.beaufort(61.9), 7)
        XCTAssertEqual(WeatherAlertScan.beaufort(62), 8)
        XCTAssertEqual(WeatherAlertScan.beaufort(74.9), 8)
        XCTAssertEqual(WeatherAlertScan.beaufort(120), 12)
    }

    func test降水概率缺列时详情留空() {
        let hit = scan(codes: [2, 65, 2, 2, 2])
        XCTAssertEqual(hit?.detail, "")
    }
}
