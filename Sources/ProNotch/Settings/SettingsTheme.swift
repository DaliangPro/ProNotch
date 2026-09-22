import SwiftUI

/// 设置窗配色：纯中性灰黑，R = G = B，不带任何色相（大梁老师 2026-09-22 定）。
///
/// 走过的弯路：冷黑灰偏蓝 → 取 Claude 桌面端暖灰（色相 60 度）发绿 → 色相挪到 30 度又偏红。
/// 灰阶只要带一点色相，在他屏幕上就看得出来，所以干脆不带；明度沿用暖灰那版的层级。
/// 强调色（开关、滑块、弹层主按钮、录快捷键）跟随系统强调色，不自定义；
/// 自定义彩色只留错误/破坏性与连接正常两种。Agent 品牌点与颜色行是内容色，不算界面色。
enum SettingsTheme {
    /// 窗口底
    static let bg = Color(hex: "#262626")
    /// 侧栏：比窗口底深一档
    static let sidebar = Color(hex: "#1F1F1F")
    /// 卡片、弹层：比窗口底亮一档
    static let card = Color(hex: "#303030")
    /// 最深一档
    static let notchStrip = Color(hex: "#141414")
    /// 分割线：比卡片亮一档
    static let divider = Color(hex: "#3C3C3C")
    /// 正文与操作文字
    static let text = Color(hex: "#FAFAFA")
    /// 次级文字
    static let textSecondary = Color(hex: "#C0C0C0")
    /// 说明文字、未点亮项
    static let textMuted = Color(hex: "#9A9A9A")
    /// 强调：系统设置 → 外观 → 强调色，用户换了这里跟着换
    static let accent = Color(nsColor: .controlAccentColor)
    /// 错误 / 破坏性
    static let danger = Color(hex: "#DD5353")
    /// 连接正常
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
