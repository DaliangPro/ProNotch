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

    // MARK: - 预警类型多选过滤（2.0 设置）

    func test类型没勾的事件当不存在_让位给勾了的大风() {
        // 雷暴取消勾选：同小时 80 km/h 阵风（勾着大风）顶上——没勾的不该挡住勾了的
        let hit = WeatherAlertScan.firstHit(
            times: times, codes: [2, 95, 2, 2, 2], gusts: [10, 80, 12, 11, 10], probs: nil,
            fromIndex: 0, withinHours: 3, alerted: [], types: [.gale])
        XCTAssertEqual(hit?.kind, "9 级大风")
    }

    func test只勾大雨时大雪不报() {
        let hit = WeatherAlertScan.firstHit(
            times: times, codes: [2, 75, 65, 2, 2], gusts: nil, probs: nil,
            fromIndex: 0, withinHours: 3, alerted: [], types: [.heavyRain])
        XCTAssertEqual(hit?.kind, "大雨", "18 时大雪没勾要跳过，19 时大雨照报")
        XCTAssertEqual(hit?.hoursAhead, 2)
    }

    func test空类型集不扫() {
        let hit = WeatherAlertScan.firstHit(
            times: times, codes: [2, 95, 2, 2, 2], gusts: [10, 80, 12, 11, 10], probs: nil,
            fromIndex: 0, withinHours: 3, alerted: [], types: [])
        XCTAssertNil(hit, "总开关关闭（空集）时什么都不报")
    }

    func test恶劣码到类型映射口径() {
        XCTAssertEqual(WeatherAlertType.from(code: 65), .heavyRain)
        XCTAssertEqual(WeatherAlertType.from(code: 82), .heavyRain)
        XCTAssertEqual(WeatherAlertType.from(code: 66), .freezingRain)
        XCTAssertEqual(WeatherAlertType.from(code: 75), .heavySnow)
        XCTAssertEqual(WeatherAlertType.from(code: 86), .heavySnow)
        XCTAssertEqual(WeatherAlertType.from(code: 99), .thunderstorm)
        XCTAssertNil(WeatherAlertType.from(code: 61), "小雨不算恶劣")
        XCTAssertNil(WeatherAlertType.from(code: 0))
    }
}

/// 预警设置的 UserDefaults 口径（总开关折叠进生效集：关 = 空集）
final class WeatherAlertTypeSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WeatherAlertType.masterKey)
        UserDefaults.standard.removeObject(forKey: WeatherAlertType.typesKey)
        super.tearDown()
    }

    func test无存值默认五类全开() {
        XCTAssertEqual(WeatherAlertType.enabledSet(), Set(WeatherAlertType.allCases))
    }

    func test总开关关闭时生效集为空() {
        UserDefaults.standard.set(false, forKey: WeatherAlertType.masterKey)
        UserDefaults.standard.set(["heavyRain"], forKey: WeatherAlertType.typesKey)
        XCTAssertEqual(WeatherAlertType.enabledSet(), [], "类型勾选保留但总开关优先")
    }

    func test类型存值读回_未知值忽略() {
        UserDefaults.standard.set(["heavyRain", "gale", "tornado-future"],
                                  forKey: WeatherAlertType.typesKey)
        XCTAssertEqual(WeatherAlertType.enabledSet(), [.heavyRain, .gale])
    }

    func test空数组表示全清而非兜底全开() {
        UserDefaults.standard.set([String](), forKey: WeatherAlertType.typesKey)
        XCTAssertEqual(WeatherAlertType.enabledSet(), [])
    }
}
