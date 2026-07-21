import Foundation

/// Open-Meteo 响应（只解需要的字段；可选字段容忍接口缺列）
struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let relative_humidity_2m: Int
        let weather_code: Int
        let wind_speed_10m: Double
    }
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double]
        let weather_code: [Int]
        let precipitation_probability: [Int]?
        let wind_gusts_10m: [Double]?   // 恶劣天气预警的大风判据
    }
    struct Daily: Decodable {
        let time: [String]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let weather_code: [Int]?
        let precipitation_probability_max: [Int]?
        let sunrise: [String]?
        let sunset: [String]?
    }
    let current: Current
    let hourly: Hourly
    let daily: Daily
}

/// Open-Meteo 响应 → `WeatherNow` 的纯映射。
///
/// 病灶：原实现按 `hourly.time.count` 循环，却拿同一个下标去取 `temperature_2m[i]`
/// 和 `weather_code[i]`；`daily` 那边按 `daily.time.count` 循环取 `temperature_2m_max[i]`。
/// 上游只要有一列比 time 短（限流截断、字段临时下线、代理改写都可能），
/// 就是一次数组越界崩溃——而且崩在天气这种纯装饰功能上。
///
/// 对策：所有必需列取**公共最小长度**，可选列继续走安全下标；
/// 核心列空了就返回结构化错误，交调用方决定「保留旧数据」还是「显示错误」。
/// 抽成纯函数是为了能离线喂各种畸形响应，不必真发网络请求。
enum WeatherMapping {

    enum Failure: Error, Equatable {
        case emptyHourly
        case emptyDaily

        var message: String {
            switch self {
            case .emptyHourly: return "天气数据不完整（逐时预报为空）"
            case .emptyDaily:  return "天气数据不完整（逐日预报为空）"
            }
        }
    }

    /// 映射结果。除了 `WeatherNow`，还带出预警扫描要用的那几列——
    /// 它们已经按公共长度裁齐，调用方不必再自己对齐一遍
    struct Mapped {
        let now: WeatherNow
        let hourlyTimes: [String]
        let hourlyCodes: [Int]
        let hourlyGusts: [Double]?
        let hourlyProbs: [Int]?
        /// 「当前整点」在裁齐后数组里的下标，保证落在有效范围内
        let startIndex: Int
    }

    static func map(_ resp: OpenMeteoResponse, city: String, at reference: Date) throws -> Mapped {
        // 必需列取公共最小长度：任何一列短了，多出来的部分一律不碰
        let hourCount = min(resp.hourly.time.count,
                            resp.hourly.temperature_2m.count,
                            resp.hourly.weather_code.count)
        guard hourCount > 0 else { throw Failure.emptyHourly }
        let dayCount = min(resp.daily.time.count,
                           resp.daily.temperature_2m_max.count,
                           resp.daily.temperature_2m_min.count)
        guard dayCount > 0 else { throw Failure.emptyDaily }

        let times = Array(resp.hourly.time.prefix(hourCount))
        let codes = Array(resp.hourly.weather_code.prefix(hourCount))
        let temps = Array(resp.hourly.temperature_2m.prefix(hourCount))

        // timezone=auto 返回本地时区时间串，字典序比较即可定位「当前整点」
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let nowStr = fmt.string(from: reference)
        // 钳到公共范围内：firstIndex 找不到时退 0，找到末尾也不会越界
        let startIdx = min(max(0, (times.firstIndex { $0 >= nowStr } ?? 0) - 1), hourCount - 1)

        var hours: [HourForecast] = []
        for i in startIdx..<min(startIdx + 6, hourCount) {
            hours.append(HourForecast(hourLabel: times[i].suffix(5).prefix(2) + "时",
                                      temp: temps[i], code: codes[i]))
        }

        // 逐天：今天/明天 + 之后按周几；日期串转 zh_CN 周几
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        let weekFmt = DateFormatter()
        weekFmt.locale = Locale(identifier: "zh_CN")
        weekFmt.dateFormat = "EEE"
        var days: [DayForecast] = []
        for i in 0..<dayCount {
            let label: String
            switch i {
            case 0: label = "今天"
            case 1: label = "明天"
            default:
                label = dayFmt.date(from: resp.daily.time[i]).map { weekFmt.string(from: $0) }
                    ?? resp.daily.time[i]
            }
            days.append(DayForecast(
                dayLabel: label,
                code: resp.daily.weather_code?[safe: i] ?? 3,
                tMax: resp.daily.temperature_2m_max[i],
                tMin: resp.daily.temperature_2m_min[i],
                precipProb: resp.daily.precipitation_probability_max?[safe: i] ?? 0))
        }

        let now = WeatherNow(
            temperature: resp.current.temperature_2m,
            apparent: resp.current.apparent_temperature,
            humidity: resp.current.relative_humidity_2m,
            windSpeed: resp.current.wind_speed_10m,
            code: resp.current.weather_code,
            todayMax: resp.daily.temperature_2m_max[0],
            todayMin: resp.daily.temperature_2m_min[0],
            city: city,
            precipProb: resp.hourly.precipitation_probability?[safe: startIdx] ?? 0,
            hourly: hours,
            days: days,
            sunrise: String((resp.daily.sunrise?.first ?? "").suffix(5)),
            sunset: String((resp.daily.sunset?.first ?? "").suffix(5)),
            fetchedAt: reference)

        return Mapped(now: now, hourlyTimes: times, hourlyCodes: codes,
                      hourlyGusts: resp.hourly.wind_gusts_10m,
                      hourlyProbs: resp.hourly.precipitation_probability,
                      startIndex: startIdx)
    }
}

extension Array {
    /// 越界安全取值（接口列长不齐时兜底）
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
