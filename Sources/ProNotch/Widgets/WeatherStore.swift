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
        case 66, 67: return "cloud.sleet.fill"   // 冻雨与普通雨区分（预警卡一眼可辨）
        case 61...65: return "cloud.rain.fill"
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

/// 恶劣天气预警事件（刘海横幅显示用，大梁老师定的核心功能）
struct WeatherAlert: Equatable {
    let symbol: String   // SF Symbol
    let title: String    // 「2 小时后大雨」
    let detail: String   // 「降水概率 85%」/「阵风 65 km/h」，可空
}

/// 恶劣天气预警类型（设置页多选）：与扫描判定口径一一对应，
/// 五类 = 四组恶劣 WMO 码 + 大风阵风阈值
enum WeatherAlertType: String, CaseIterable {
    case heavyRain, freezingRain, heavySnow, thunderstorm, gale

    var displayName: String {
        switch self {
        case .heavyRain: return "大雨"
        case .freezingRain: return "冻雨"
        case .heavySnow: return "大雪"
        case .thunderstorm: return "雷暴"
        case .gale: return "大风"
        }
    }

    /// 恶劣 WMO 码 → 预警类型（大雨 65/82、冻雨 66/67、大雪 75/86、雷暴冰雹 95-99）；
    /// 非恶劣码返回 nil。大风不走天气码，由阵风阈值单独判定
    static func from(code: Int) -> WeatherAlertType? {
        switch code {
        case 65, 82: return .heavyRain
        case 66, 67: return .freezingRain
        case 75, 86: return .heavySnow
        case 95...99: return .thunderstorm
        default: return nil
        }
    }

    static let masterKey = "weatherAlertsEnabled"
    static let typesKey = "weatherAlertTypes"

    /// 当前生效的预警类型：总开关关 = 空集。WeatherStore 扫描时直接读，
    /// 不依赖 SettingsStore 实例（与 AgentKind.enabledSet 同一套口径）
    static func enabledSet() -> Set<WeatherAlertType> {
        guard UserDefaults.standard.object(forKey: masterKey) as? Bool ?? true else { return [] }
        guard let raw = UserDefaults.standard.stringArray(forKey: typesKey) else { return Set(allCases) }
        return Set(raw.compactMap(WeatherAlertType.init(rawValue:)))
    }
}

/// 恶劣天气扫描（纯函数，单测覆盖）：从当前小时的下一小时起扫未来 N 小时，
/// 返回第一条还没报过的恶劣事件；nil = 无恶劣天气或都报过了
enum WeatherAlertScan {
    struct Hit: Equatable {
        let fingerprint: String   // 「2026-07-18T20:00|大雨」——同小时同类型只报一次
        let hoursAhead: Int
        let kind: String          // 大雨 / 大雪 / 雷阵雨 / 8 级大风…
        let symbol: String
        let detail: String
    }

    /// 大风预警阈值：阵风 ≥ 39 km/h（蒲福 6 级下限，撑伞困难、迎风吃力——
    /// 大梁老师定的 6 级线，8 级太高等真报警就晚了）
    static let gustThreshold: Double = 39

    /// 阵风 km/h → 蒲福风级（各级下限：8 级 = 62-74 km/h）
    static func beaufort(_ kmh: Double) -> Int {
        let bounds: [Double] = [1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118]
        return bounds.filter { kmh >= $0 }.count
    }

    /// 只扫「未来」(fromIndex+1 起)：当前小时正在发生的自己看得见，预警没意义。
    /// 一小时最多算一条事件，恶劣天气码优先于大风。
    /// types = 设置页勾选的预警类型：类型没勾的事件当不存在（同小时让位给勾了的大风）
    static func firstHit(times: [String], codes: [Int], gusts: [Double]?, probs: [Int]?,
                         fromIndex: Int, withinHours: Int, alerted: Set<String>,
                         types: Set<WeatherAlertType> = Set(WeatherAlertType.allCases)) -> Hit? {
        guard withinHours > 0, !types.isEmpty else { return nil }
        for offset in 1...withinHours {
            let i = fromIndex + offset
            guard i >= 0, i < times.count, i < codes.count else { break }
            if let type = WeatherAlertType.from(code: codes[i]), types.contains(type) {
                let kind = WeatherNow.text(for: codes[i])
                guard !alerted.contains("\(times[i])|\(kind)") else { continue }
                let prob = probs?[safe: i] ?? 0
                return Hit(fingerprint: "\(times[i])|\(kind)", hoursAhead: offset, kind: kind,
                           symbol: WeatherNow.symbol(for: codes[i]),
                           detail: prob > 0 ? "降水概率 \(prob)%" : "")
            }
            if types.contains(.gale), let g = gusts?[safe: i], g >= gustThreshold {
                guard !alerted.contains("\(times[i])|大风") else { continue }
                return Hit(fingerprint: "\(times[i])|大风", hoursAhead: offset,
                           kind: "\(beaufort(g)) 级大风", symbol: "wind",
                           detail: "阵风 \(Int(g.rounded())) km/h")
            }
        }
        return nil
    }
}

/// 天气数据源：CoreLocation 系统定位（大梁老师选定）+ Open-Meteo。
/// 定位成功后位置缓存 1 小时；天气 15 分钟节流；权限被拒给设置引导文案
@MainActor
final class WeatherStore: NSObject, ObservableObject {
    @Published private(set) var now: WeatherNow?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    /// 当前待展示的恶劣天气预警；非 nil 时刘海弹出大卡，8 秒后自动清空
    @Published private(set) var alert: WeatherAlert?
    /// 右上角天气标联动（大梁老师定）：窗口内只要有恶劣事件就非 nil（与弹卡去重无关），
    /// 收起态天气 slot 据此换脸；事件出窗后随扫描自动还原
    @Published private(set) var upcomingSevere: WeatherAlert?
    /// 最近一次真实扫描的联动结果；预览结束后据此还原天气标
    private var scannedSevere: WeatherAlert?
    /// 预览进行中（设置页触发）：结束时天气标要还原成真实扫描结果
    private var isPreviewing = false

    /// 预警提前量：扫未来 3 小时（大梁老师定）
    static let alertLookaheadHours = 3
    private let alertedKey = "weatherAlertedEvents"
    /// 自动缩回令牌：新预警会重置计时，旧的定时清空不再生效
    private var alertDismissToken = UUID()

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
        // 预警卡形态核查：-demoWeatherAlert [大雨|冻雨|大雪|雷暴|大风]
        // 附带对应演示预警（collapsed.png 可见），不带类型默认雷暴
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-demoWeatherAlert") {
            let label = args[safe: i + 1] ?? ""
            let a = (Self.previewAlerts.first { $0.label == label } ?? Self.previewAlerts[3]).alert
            alert = a
            upcomingSevere = a   // 右上角天气标联动一并核查
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // 城市级精度足够，省电
        // 设置页改动预警开关/类型 → 立即按新口径清态或重扫
        NotificationCenter.default.addObserver(
            forName: .proNotchWeatherAlertSettingsChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAlertSettingsChange() }
        }
    }

    /// 预警设置变化：全关（总开关或类型清空）→ 清掉在展示的预警；
    /// 开着 → 强刷一次按新类型口径重扫（改类型立即生效，不等 15 分钟节流）
    private func applyAlertSettingsChange() {
        guard !demoMode else { return }
        if WeatherAlertType.enabledSet().isEmpty {
            alertDismissToken = UUID()   // 在途的 8 秒自动收卡一并作废
            isPreviewing = false
            alert = nil
            upcomingSevere = nil
            scannedSevere = nil
        } else {
            refresh(force: true)
        }
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

    /// 预警兜底刷新（AppDelegate 定时器调）：两侧功能区都没配天气时也保证数据定期落地。
    /// 只在已授权定位时静默刷——绝不在后台弹授权框，授权由用户首次打开天气功能触发
    func refreshIfAuthorized() {
        guard manager.authorizationStatus == .authorizedAlways else { return }
        refresh()
    }

    // MARK: - 恶劣天气预警

    /// 数据落地后扫未来 3 小时：命中未报过的恶劣事件 → 弹大卡并记入已报名单
    private func checkSevereWeather(times: [String], codes: [Int],
                                    gusts: [Double]?, probs: [Int]?, fromIndex: Int) {
        // 预警设置口径：总开关关 = 空集 → 清态跳扫（天气数据照常落地，大卡/槽位不受影响）
        let types = WeatherAlertType.enabledSet()
        guard !types.isEmpty else {
            scannedSevere = nil
            if !isPreviewing { upcomingSevere = nil }
            return
        }
        // 右上角天气标联动：忽略「弹没弹过卡」的去重，窗口内有事件就亮预警态
        scannedSevere = WeatherAlertScan.firstHit(
            times: times, codes: codes, gusts: gusts, probs: probs,
            fromIndex: fromIndex, withinHours: Self.alertLookaheadHours, alerted: [], types: types)
            .map { WeatherAlert(symbol: $0.symbol, title: "\($0.hoursAhead) 小时后\($0.kind)",
                                detail: $0.detail) }
        if !isPreviewing { upcomingSevere = scannedSevere }

        // 已报名单剪枝：过点的事件清掉，名单不随时间无限膨胀
        let nowHour = times[safe: fromIndex] ?? ""
        var alerted = Set((UserDefaults.standard.stringArray(forKey: alertedKey) ?? [])
            .filter { String($0.split(separator: "|").first ?? "") >= nowHour })
        let hit = WeatherAlertScan.firstHit(
            times: times, codes: codes, gusts: gusts, probs: probs,
            fromIndex: fromIndex, withinHours: Self.alertLookaheadHours, alerted: alerted,
            types: types)
        if let hit {
            alerted.insert(hit.fingerprint)
            presentAlert(WeatherAlert(symbol: hit.symbol,
                                      title: "\(hit.hoursAhead) 小时后\(hit.kind)",
                                      detail: hit.detail))
        }
        UserDefaults.standard.set(Array(alerted), forKey: alertedKey)
    }

    /// 弹出大卡并排定 8 秒自动缩回；新预警重置计时
    private func presentAlert(_ a: WeatherAlert) {
        alert = a
        let token = UUID()
        alertDismissToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.alertDismissToken == token else { return }
            self.dismissAlert()
        }
    }

    /// 收卡：卡被点击（跳组件页）、8 秒超时或设置页「停止」都走这里；
    /// 预览态顺带把右上角天气标还原成真实扫描结果
    func dismissAlert() {
        alert = nil
        if isPreviewing {
            isPreviewing = false
            upcomingSevere = scannedSevere
        }
    }

    /// 设置页「预览提醒效果」的五种样例（大梁老师要求逐个可预览），
    /// 图标与文案和真实预警同一套生成口径
    static let previewAlerts: [(label: String, alert: WeatherAlert)] = [
        ("大雨", WeatherAlert(symbol: WeatherNow.symbol(for: 82), title: "2 小时后大雨", detail: "降水概率 85%")),
        ("冻雨", WeatherAlert(symbol: WeatherNow.symbol(for: 66), title: "1 小时后冻雨", detail: "降水概率 70%")),
        ("大雪", WeatherAlert(symbol: WeatherNow.symbol(for: 86), title: "3 小时后大雪", detail: "降水概率 90%")),
        ("雷暴", WeatherAlert(symbol: WeatherNow.symbol(for: 95), title: "2 小时后雷阵雨", detail: "降水概率 85%")),
        ("大风", WeatherAlert(symbol: "wind", title: "2 小时后 7 级大风", detail: "阵风 55 km/h")),
    ]

    /// 设置页预览：走真实弹出链路看视觉与动画（含右上角天气标联动），不写入已报名单
    func preview(_ a: WeatherAlert) {
        isPreviewing = true
        upcomingSevere = a
        presentAlert(a)
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
                                 value: "temperature_2m,weather_code,precipitation_probability,wind_gusts_10m"),
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

        // 恶劣天气预警（大梁老师定的核心功能）：每次数据落地扫一遍未来 3 小时
        checkSevereWeather(times: resp.hourly.time, codes: resp.hourly.weather_code,
                           gusts: resp.hourly.wind_gusts_10m,
                           probs: resp.hourly.precipitation_probability, fromIndex: startIdx)

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

private extension Array {
    /// 越界安全取值（接口列长不齐时兜底）
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
