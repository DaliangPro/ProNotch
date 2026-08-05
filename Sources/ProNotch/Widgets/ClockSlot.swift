import Foundation

/// 刘海侧栏时钟槽位的时区选项（大梁老师 2026-08-04）。
///
/// 只给常用城市，不列系统那一百多个时区——这是他拍板的口径：
/// 侧栏时钟是「瞄一眼对方那边几点」，翻长列表反而慢。
/// 想要的城市不在表里再补，加一行的事。
///
/// 标识符用 IANA 名（`Asia/Shanghai`）而非 GMT 偏移：夏令时由系统跟着走，
/// 写死偏移的话纽约每年会错两次。
enum ClockZone: String, CaseIterable, Identifiable {
    /// 跟随系统当前时区。默认值——不配也能用
    case system
    case shanghai
    case hongKong
    case tokyo
    case singapore
    case sydney
    case dubai
    case london
    case paris
    case newYork
    case chicago
    case losAngeles

    var id: String { rawValue }

    /// 设置里显示的名字。带城市名而非「UTC+8」——后者要心算
    var title: String {
        switch self {
        case .system:      return "跟随系统"
        case .shanghai:    return "北京 / 上海"
        case .hongKong:    return "香港"
        case .tokyo:       return "东京"
        case .singapore:   return "新加坡"
        case .sydney:      return "悉尼"
        case .dubai:       return "迪拜"
        case .london:      return "伦敦"
        case .paris:       return "巴黎"
        case .newYork:     return "纽约"
        case .chicago:     return "芝加哥"
        case .losAngeles:  return "洛杉矶"
        }
    }

    /// IANA 时区标识符。`system` 返回 nil ＝ 用 `TimeZone.current`
    var identifier: String? {
        switch self {
        case .system:      return nil
        case .shanghai:    return "Asia/Shanghai"
        case .hongKong:    return "Asia/Hong_Kong"
        case .tokyo:       return "Asia/Tokyo"
        case .singapore:   return "Asia/Singapore"
        case .sydney:      return "Australia/Sydney"
        case .dubai:       return "Asia/Dubai"
        case .london:      return "Europe/London"
        case .paris:       return "Europe/Paris"
        case .newYork:     return "America/New_York"
        case .chicago:     return "America/Chicago"
        case .losAngeles:  return "America/Los_Angeles"
        }
    }

    /// 解析成 `TimeZone`。标识符失效（系统时区库变动）时退回当前时区，
    /// 而不是显示一个错的时间——宁可显示本地时间也不能显示错误时间
    var timeZone: TimeZone {
        guard let identifier, let zone = TimeZone(identifier: identifier) else {
            return .current
        }
        return zone
    }

    /// 组件页时钟卡的默认城市：本地 + 三个跨时区常见协作地。
    /// 不放满 12 个——卡上一屏放得下四五个，默认给个能用的起点，其余由用户加
    static let defaultCardZones: [ClockZone] = [.system, .newYork, .london, .tokyo]

    /// 存进 UserDefaults 的字符串反解；认不出就回默认值（老档案、手改配置都走这条）
    static func from(_ raw: String?) -> ClockZone {
        guard let raw, let zone = ClockZone(rawValue: raw) else { return .system }
        return zone
    }
}

/// 侧栏时钟的显示文本（纯函数，可测）。
///
/// 只显时间不带时区缩写（大梁老师拍板）：侧栏单侧仅 56pt，
/// 加缩写就得压字号，而他要的是一眼能读。想知道是哪个区，设置里看
enum ClockFormatter {
    /// `HH:mm` 24 小时制，前导零补齐——数字宽度恒定，秒针跳动时不会左右抖
    static func text(for date: Date, zone: TimeZone, use24Hour: Bool = true) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = parts.minute ?? 0
        guard var hour = parts.hour else { return "--:--" }
        if !use24Hour {
            // 12 小时制：0 点显示 12，13 点显示 1
            hour = hour % 12
            if hour == 0 { hour = 12 }
            return String(format: "%d:%02d", hour, minute)
        }
        return String(format: "%02d:%02d", hour, minute)
    }
}
