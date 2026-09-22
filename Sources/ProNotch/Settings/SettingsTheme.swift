import SwiftUI

/// 设置窗配色：直接取 Claude 桌面端深色主题的变量（大梁老师 2026-09-22 定「参考 Claude Code 桌面端」），
/// 色值从 /Applications/Claude.app 的 app.asar 里读出的 HSL 换算而来。
///
/// 要点是暖灰而非冷灰。Claude 原值色相 60 度（红 = 绿 > 蓝），在大梁老师的屏幕上看着发绿；
/// 2026-09-22 把色相挪到 30 度（红 > 绿 > 蓝），明度不变，暖而不绿。
/// 此前两版冷黑灰怎么调深都不像，根因是色相不对。
/// 彩色只留三种语义：强调（开关、当前项、弹层主按钮）、错误/破坏性、连接正常；
/// Agent 品牌点与颜色行是内容色，不算界面色。
enum SettingsTheme {
    /// bg-100：窗口底（Claude 原值 #262624）
    static let bg = Color(hex: "#282624")
    /// bg-200：侧栏（原 #1F1E1D）
    static let sidebar = Color(hex: "#211E1C")
    /// bg-000：卡片、弹层（原 #30302E）
    static let card = Color(hex: "#33302E")
    /// bg-300：最深一档（原 #141413）
    static let notchStrip = Color(hex: "#161413")
    /// 分割线：比卡片亮一档
    static let divider = Color(hex: "#3F3B38")
    /// text-000：正文与操作文字
    static let text = Color(hex: "#FAF9F5")
    /// text-200：次级文字（原 #C2C0B6）
    static let textSecondary = Color(hex: "#C4BFB8")
    /// text-400：说明文字、未点亮项（原 #9C9A92）
    static let textMuted = Color(hex: "#9E9A94")
    /// accent-brand：陶土橙
    static let accent = Color(hex: "#D97757")
    /// danger-100
    static let danger = Color(hex: "#DD5353")
    /// success-100
    static let success = Color(hex: "#65BB30")

    /// 侧栏当前项
    static let sidebarSelected = Color.white.opacity(0.08)
    /// 选片 / 分段控件点亮
    static let fillOn = Color.white.opacity(0.18)
    /// 磁贴点亮（磁贴直接落在窗口底上，比卡片里的选片再亮一点才看得出）
    static let tileOn = Color.white.opacity(0.14)
    /// 未点亮
    static let fillOff = Color.white.opacity(0.04)
    /// 分段控件底、输入框底
    static let segmentBg = Color.white.opacity(0.06)
    /// 开关关闭态轨道
    static let switchOff = Color.white.opacity(0.2)
}
