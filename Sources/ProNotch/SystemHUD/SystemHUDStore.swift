import Combine
import SwiftUI

/// 音量 / 亮度提示的中枢：接管媒体键 → 自己改值 → 驱动刘海里那张 HUD 卡。
///
/// 设计口径是**1:1 顶替系统 HUD**，不是「多一个提示」：
/// - 只有按键盘那几颗键才弹（与系统一致）。用控制中心拖音量条系统本来就不弹，
///   我们也不弹——否则用户会觉得刘海比以前更吵。
/// - 这台设备调不动（HDMI 电视没有音量、合盖时没有内置屏亮度）就**不接管**，
///   按键原样交回系统，让它弹自己那个禁止标志。假装接管却什么都没发生，
///   用户只会以为 ProNotch 坏了。
/// - 两个通道各有开关，各管各的键。只开音量时亮度键完全不经过我们。
@MainActor
final class SystemHUDStore: ObservableObject {

    enum Channel {
        case volume, brightness

        var isVolume: Bool { self == .volume }
    }

    /// 当前要显示的一帧。nil＝卡不在场
    struct Reading: Equatable {
        let channel: Channel
        /// 0…1
        let value: Double
        let muted: Bool

        /// 进度条实际画到几成。静音一律画成 0——静音时系统仍记着原音量，
        /// 照实画会出现「喇叭划掉了、条却是满的」
        var fill: Double { min(1, max(0, muted ? 0 : value)) }

        /// 右侧那个数字
        var percent: Int { Int((fill * 100).rounded()) }

        /// 档位图标，与系统 HUD 同口径：静音是划掉的喇叭，
        /// 音量按 0 / 低 / 中 / 高分四档波纹，亮度按半分两档。
        /// 放在这儿而不是视图里，是为了能单测——这套阈值改错了肉眼很难发现
        var symbolName: String {
            guard channel.isVolume else {
                return fill >= 0.5 ? "sun.max.fill" : "sun.min.fill"
            }
            if fill <= 0 { return "speaker.slash.fill" }
            if fill < 1.0 / 3 { return "speaker.wave.1.fill" }
            if fill < 2.0 / 3 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    @Published private(set) var reading: Reading?

    /// 提示停留多久。系统 OSD 大约是 1.5 秒，照抄它——
    /// 连按时每次都重置，最后一次按完再从头计时
    static let dwell: TimeInterval = 1.5

    private let tap = MediaKeyTap()
    private var hideTask: Task<Void, Never>?
    private var settingsObserver: Any?

    /// 只读镜像，供设置页显示「已接管 / 未接管」
    var isIntercepting: Bool { tap.isRunning }

    /// 「刘海已经被别的大卡占着了吗」。天气预警、Agent 拍板卡与 HUD 都从刘海同一处长出来，
    /// 同时在场会叠成一团。此时**不接管**：按键交回系统，用户看见的是屏幕中间那块方块——
    /// 不好看，但比「按了没反应」强得多。由 AppDelegate 接上两个 Store，
    /// 免得 Store 之间互相持有（见 AppDelegate）
    var otherCardShowing: (() -> Bool)?

    init() {
        tap.handler = { [weak self] key, fine in
            self?.handle(key: key, fine: fine) ?? false
        }
    }

    /// 按当前设置装载或卸载拦截，并挂上设置变更监听
    func start() {
        applySettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .proNotchSystemHUDSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
    }

    func stop() {
        tap.stop()
        hideTask?.cancel()
        hideTask = nil
        reading = nil
    }

    /// 两个通道全关就真卸载 tap——按键彻底交回系统，不留一个空转的事件 tap 在那儿
    /// 白白过一遍所有媒体键事件
    private func applySettings() {
        let d = UserDefaults.standard
        let wanted = d.bool(forKey: PrefKey.volumeHUDEnabled) || d.bool(forKey: PrefKey.brightnessHUDEnabled)
        if wanted {
            guard AXPermission.ensure() else {
                // 没权限就别装：装不上还留着开关是开的，用户会以为生效了
                AppLog.systemHUD.error("缺辅助功能权限，HUD 接管未生效")
                return
            }
            tap.start()
        } else {
            tap.stop()
            hideTask?.cancel()
            reading = nil
        }
    }

    // MARK: - 按键处理

    /// 返回 true＝已接管（事件被吞）。返回 false 的每一条都必须是
    /// 「我们确实什么都没做」，否则系统会在我们改完值之后再改一次
    private func handle(key: MediaKeyTap.Key, fine: Bool) -> Bool {
        guard otherCardShowing?() != true else { return false }
        let d = UserDefaults.standard
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard d.bool(forKey: PrefKey.volumeHUDEnabled) else { return false }
            return handleVolume(key: key, fine: fine)
        case .brightnessUp, .brightnessDown:
            guard d.bool(forKey: PrefKey.brightnessHUDEnabled) else { return false }
            return handleBrightness(up: key == .brightnessUp, fine: fine)
        }
    }

    private func handleVolume(key: MediaKeyTap.Key, fine: Bool) -> Bool {
        let result: VolumeController.Reading
        if key == .mute {
            result = VolumeController.toggleMute()
        } else {
            let stepSize = fine ? VolumeController.fineStep : VolumeController.step
            result = VolumeController.nudge(by: key == .volumeUp ? stepSize : -stepSize)
        }
        guard result.available else { return false }   // 没有音量控制的设备：交回系统
        present(Reading(channel: .volume, value: result.volume, muted: result.muted))
        return true
    }

    private func handleBrightness(up: Bool, fine: Bool) -> Bool {
        let stepSize = fine ? BrightnessController.fineStep : BrightnessController.step
        let result = BrightnessController.nudge(by: up ? stepSize : -stepSize)
        guard result.available else { return false }   // 合盖/纯外接：交回系统
        present(Reading(channel: .brightness, value: result.brightness, muted: false))
        return true
    }

    // MARK: - 展示

    /// 换值不重播出场动画：连按音量键时卡应当稳稳停在那儿只有条在动，
    /// 每次都重播「长出来」会抖成一团
    private func present(_ new: Reading) {
        reading = new
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.dwell))
            guard !Task.isCancelled else { return }
            self?.reading = nil
        }
    }

    /// 离屏渲染 / 设置页预览用：直接摆一帧上去，不碰真实音量亮度
    func preview(_ reading: Reading?) {
        hideTask?.cancel()
        self.reading = reading
    }
}
