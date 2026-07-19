import CoreLocation
import Foundation

/// 逐时预报（未来 6 小时，含当前整点）
struct HourForecast: Identifiable {
    let hourLabel: String   // 「17时」
    let temp: Double
    let code: Int
    var id: String { hourLabel }
    var symbol: String { WeatherNow.symbol(for: code) }
}

/// 逐天预报（今起 5 天）
struct DayForecast: Identifiable {
    let dayLabel: String    // 今天 / 明天 / 周日
    let code: Int
    let tMax: Double
    let tMin: Double
    let precipProb: Int     // 当日最大降水概率 %
    var id: String { dayLabel }
    var symbol: String { WeatherNow.symbol(for: code) }
}

/// 当前天气（Open-Meteo 免 key 数据 + WMO 天气码本地映射）
struct WeatherNow {
    let temperature: Double      // 当前气温 ℃
    let apparent: Double         // 体感 ℃
    let humidity: Int            // 相对湿度 %
    let windSpeed: Double        // 风速 km/h
    let code: Int                // WMO weather code
    let todayMax: Double
    let todayMin: Double
    let city: String             // 反地理编码城市名（可空串）
    let precipProb: Int          // 当前小时降水概率 %
    let hourly: [HourForecast]   // 未来 6 小时
    let days: [DayForecast]      // 今起 5 天
    let sunrise: String          // 「05:14」
    let sunset: String
    let fetchedAt: Date

    var symbol: String { Self.symbol(for: code) }
    var text: String { Self.text(for: code) }

    /// WMO code → SF Symbol（收起态 slot 与组件卡共用）
    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func text(for code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大致晴朗"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51...57: return "毛毛雨"
        case 61, 80: return "小雨"
        case 63, 81: return "中雨"
        case 65, 82: return "大雨"
        case 66, 67: return "冻雨"
        case 71, 85: return "小雪"
        case 73: return "中雪"
        case 75, 77, 86: return "大雪"
        case 95: return "雷阵雨"
        case 96...99: return "雷暴冰雹"
        default: return "多云"
        }
    }
}

/// 天气数据源：CoreLocation 系统定位（大梁老师选定）+ Open-Meteo。
/// 定位成功后位置缓存 1 小时；天气 15 分钟节流；权限被拒给设置引导文案
@MainActor
final class WeatherStore: NSObject, ObservableObject {
    @Published private(set) var now: WeatherNow?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false

    private let manager = CLLocationManager()
    private var cachedLocation: CLLocation?
    private var locatedAt: Date = .distantPast
    private var lastFetch: Date = .distantPast
    /// 收到授权后是否有等待中的刷新请求（首次授权弹框期间的 refresh 不能丢）
    private var pendingAfterAuth = false
    /// 演示模式（-snapshotPanel 离屏渲染）：不定位不联网，refresh 直接短路
    private var demoMode = false

    /// 离屏渲染用演示数据：填一份固定天气，后续 refresh 全部短路
    /// （避免渲染实例触发系统定位授权弹框）
    func loadDemoWeather() {
        demoMode = true
        now = WeatherNow(
            temperature: 33, apparent: 36, humidity: 68, windSpeed: 12,
            code: 2, todayMax: 35, todayMin: 27, city: "杭州", precipProb: 12,
            hourly: [
                HourForecast(hourLabel: "17时", temp: 34, code: 2),
                HourForecast(hourLabel: "18时", temp: 33, code: 2),
                HourForecast(hourLabel: "19时", temp: 32, code: 3),
                HourForecast(hourLabel: "20时", temp: 31, code: 3),
                HourForecast(hourLabel: "21时", temp: 30, code: 61),
                HourForecast(hourLabel: "22时", temp: 29, code: 3),
            ],
            days: [
                DayForecast(dayLabel: "今天", code: 2, tMax: 35, tMin: 27, precipProb: 10),
                DayForecast(dayLabel: "明天", code: 61, tMax: 33, tMin: 26, precipProb: 55),
                DayForecast(dayLabel: "周日", code: 3, tMax: 34, tMin: 27, precipProb: 20),
                DayForecast(dayLabel: "周一", code: 0, tMax: 36, tMin: 28, precipProb: 0),
                DayForecast(dayLabel: "周二", code: 95, tMax: 31, tMin: 25, precipProb: 80),
            ],
            sunrise: "05:14", sunset: "18:52", fetchedAt: Date())
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // 城市级精度足够，省电
    }

    /// 刷新（15 分钟节流，force 忽略）。位置 1 小时内复用，超时重新定位
    func refresh(force: Bool = false) {
        guard !demoMode else { return }
        guard force || Date().timeIntervalSince(lastFetch) > 900 else { return }
        if let loc = cachedLocation, Date().timeIntervalSince(locatedAt) < 3600 {
            fetch(at: loc)
        } else {
            requestLocation()
        }
    }

    private func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingAfterAuth = true
            refreshing = true
            manager.requestWhenInUseAuthorization()   // 授权回调里续接定位
        case .denied, .restricted:
            error = "定位权限未开启：系统设置 → 隐私与安全性 → 定位服务 中允许 ProNotch"
            refreshing = false
        default:
            refreshing = true
            manager.requestLocation()
        }
    }

    // MARK: - 定位回调续接（delegate 线程 → 主线程）

    fileprivate func handleAuthChange(_ status: CLAuthorizationStatus) {
        guard pendingAfterAuth else { return }
        switch status {
        case .denied, .restricted:
            pendingAfterAuth = false
            refreshing = false
            error = "定位权限未开启：系统设置 → 隐私与安全性 → 定位服务 中允许 ProNotch"
        case .notDetermined:
            break   // 弹框还开着，等用户选
        default:
            pendingAfterAuth = false
            manager.requestLocation()
        }
    }

    fileprivate func handleLocation(_ location: CLLocation) {
        cachedLocation = location
        locatedAt = Date()
        fetch(at: location)
    }

    fileprivate func handleLocationFailure(_ message: String) {
        // 有旧位置就降级用（天气对位置不敏感），完全没有才报错
        if let loc = cachedLocation {
            fetch(at: loc)
        } else {
            refreshing = false
            error = "定位失败: \(message)"
        }
    }

    // MARK: - 拉天气

    private func fetch(at location: CLLocation) {
        refreshing = true
        error = nil
        lastFetch = Date()
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        Task { [weak self] in
            do {
                var comp = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                comp.queryItems = [
                    URLQueryItem(name: "latitude", value: String(format: "%.4f", lat)),
                    URLQueryItem(name: "longitude", value: String(format: "%.4f", lon)),
                    URLQueryItem(name: "current",
                                 value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
                    URLQueryItem(name: "hourly",
                                 value: "temperature_2m,weather_code,precipitation_probability"),
                    URLQueryItem(name: "daily",
                                 value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max,sunrise,sunset"),
                    URLQueryItem(name: "timezone", value: "auto"),
                    URLQueryItem(name: "forecast_days", value: "5"),
                ]
                let (data, _) = try await URLSession.shared.data(from: comp.url!)
                let resp = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
                // 城市名反编码失败不阻塞天气显示
                let city = (try? await CLGeocoder().reverseGeocodeLocation(
                    location, preferredLocale: Locale(identifier: "zh_CN")))?
                    .first.flatMap { $0.locality ?? $0.administrativeArea } ?? ""
                await MainActor.run { self?.apply(resp, city: city) }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.refreshing = false
                    // 已有旧数据就静默保留（下个周期再试），首次失败才提示
                    if self.now == nil { self.error = "天气获取失败: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func apply(_ resp: OpenMeteoResponse, city: String) {
        refreshing = false
        // timezone=auto 返回本地时区时间串，字典序比较即可定位「当前整点」
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let nowStr = fmt.string(from: Date())
        let startIdx = max(0, (resp.hourly.time.firstIndex { $0 >= nowStr } ?? 0) - 1)
        var hours: [HourForecast] = []
        for i in startIdx..<min(startIdx + 6, resp.hourly.time.count) {
            hours.append(HourForecast(
                hourLabel: resp.hourly.time[i].suffix(5).prefix(2) + "时",
                temp: resp.hourly.temperature_2m[i],
                code: resp.hourly.weather_code[i]))
        }
        let precipNow = resp.hourly.precipitation_probability?[safe: startIdx] ?? 0

        // 逐天：今天/明天 + 之后按周几；日期串转 zh_CN 周几
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        let weekFmt = DateFormatter()
        weekFmt.locale = Locale(identifier: "zh_CN")
        weekFmt.dateFormat = "EEE"
        var days: [DayForecast] = []
        for i in 0..<resp.daily.time.count {
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

        now = WeatherNow(temperature: resp.current.temperature_2m,
                         apparent: resp.current.apparent_temperature,
                         humidity: resp.current.relative_humidity_2m,
                         windSpeed: resp.current.wind_speed_10m,
                         code: resp.current.weather_code,
                         todayMax: resp.daily.temperature_2m_max.first ?? resp.current.temperature_2m,
                         todayMin: resp.daily.temperature_2m_min.first ?? resp.current.temperature_2m,
                         city: city,
                         precipProb: precipNow,
                         hourly: hours,
                         days: days,
                         sunrise: String((resp.daily.sunrise?.first ?? "").suffix(5)),
                         sunset: String((resp.daily.sunset?.first ?? "").suffix(5)),
                         fetchedAt: Date())
    }
}

extension WeatherStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.handleAuthChange(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.handleLocation(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.handleLocationFailure(msg) }
    }
}

/// Open-Meteo 响应（只解需要的字段；可选字段容忍接口缺列）
private struct OpenMeteoResponse: Decodable {
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

private extension Array {
    /// 越界安全取值（接口列长不齐时兜底）
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
