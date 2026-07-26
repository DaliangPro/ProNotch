import XCTest
@testable import ProNotch

/// 音量 / 亮度提示做进刘海：把系统那块弹在屏幕正中的方块顶掉，改由刘海长出一条提示。
///
/// 这个功能的风险不在画面而在**接管键盘**——按键被我们吃掉之后，
/// 只要有一处判断错，用户的音量键就成了「按下去没反应」。所以这里钉三件事：
/// 键码表（写死的 ABI 常量，错一个就是吃错键）、
/// 「调不动就别接管」（读数不可用时必须放行，交回系统去弹它的禁止标志）、
/// 以及档位图标的阈值（改错了肉眼极难发现）。
@MainActor
final class SystemHUDTests: XCTestCase {

    // MARK: - 媒体键键码表

    /// IOKit `ev_keymap.h` 的 NX_KEYTYPE_* 常量在代码里是写死的五个数字。
    /// 写死没问题（二十年没变过的 ABI），但必须有一处把「哪个数字是哪颗键」钉住：
    /// 把 2（亮度+）错认成 0（音量+），表现是按亮度键在调音量
    func test五颗键的键码一一对应() {
        XCTAssertEqual(MediaKeyTap.Key(nxKeyCode: 0), .volumeUp)
        XCTAssertEqual(MediaKeyTap.Key(nxKeyCode: 1), .volumeDown)
        XCTAssertEqual(MediaKeyTap.Key(nxKeyCode: 2), .brightnessUp)
        XCTAssertEqual(MediaKeyTap.Key(nxKeyCode: 3), .brightnessDown)
        XCTAssertEqual(MediaKeyTap.Key(nxKeyCode: 7), .mute)
    }

    /// 其余媒体键（播放 16、下一首 17、上一首 18、键盘背光 21/22 等）一律不认。
    /// 认了就等于把它们也吃掉——用户会发现播放键失灵，而且完全想不到是刘海干的
    func test其余媒体键一律不接管() {
        for code: Int32 in [4, 5, 6, 8, 9, 10, 16, 17, 18, 19, 20, 21, 22, 23, -1] {
            XCTAssertNil(MediaKeyTap.Key(nxKeyCode: code), "键码 \(code) 不该被接管")
        }
    }

    // MARK: - 调不动就别接管

    /// 实测过：本机默认输出是 HDMI 电视，`kAudioDevicePropertyVolumeScalar` 属性根本不存在。
    /// 这类设备上系统自己也调不动（按音量键弹的是禁止标志），
    /// 所以「没有音量控制」必须是一等状态：`available == false` 时 Store 会返回 false 放行按键。
    /// 假装接管却什么都没发生，用户只会以为 ProNotch 坏了
    func test没有音量控制的设备读数标记为不可用() {
        XCTAssertFalse(VolumeController.Reading.unavailable.available)
        XCTAssertFalse(BrightnessController.Reading.unavailable.available)
    }

    /// 步长与系统一致：一格 1/16（6.25%），⇧⌥ 微调是四分之一格。
    /// 两个通道必须同一套手感，不然按亮度和按音量走的格子不一样大
    func test两个通道的步长一致且为系统同款十六分之一格() {
        XCTAssertEqual(VolumeController.step, 1.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(BrightnessController.step, 1.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(VolumeController.fineStep, VolumeController.step / 4, accuracy: 1e-9)
        XCTAssertEqual(BrightnessController.fineStep, BrightnessController.step / 4, accuracy: 1e-9)
    }

    // MARK: - 档位图标与进度

    func test音量图标按四档走() {
        XCTAssertEqual(volume(0).symbolName, "speaker.slash.fill")
        XCTAssertEqual(volume(0.2).symbolName, "speaker.wave.1.fill")
        XCTAssertEqual(volume(0.5).symbolName, "speaker.wave.2.fill")
        XCTAssertEqual(volume(1).symbolName, "speaker.wave.3.fill")
    }

    /// 边界压在 1/3 与 2/3 上：这两处一旦写成 <=，1/3 就会掉进低档，
    /// 表现是「明明调高了一格，喇叭波纹反而少了一根」
    func test音量档位的两个分界点() {
        XCTAssertEqual(volume(1.0 / 3 - 0.001).symbolName, "speaker.wave.1.fill")
        XCTAssertEqual(volume(1.0 / 3).symbolName, "speaker.wave.2.fill")
        XCTAssertEqual(volume(2.0 / 3 - 0.001).symbolName, "speaker.wave.2.fill")
        XCTAssertEqual(volume(2.0 / 3).symbolName, "speaker.wave.3.fill")
    }

    /// 静音时系统仍记着原音量。照实画就会出现「喇叭划掉了、进度条却是满的」——
    /// 所以静音一律按 0 画，图标也必须是划掉的喇叭
    func test静音时条画成零且图标是划掉的喇叭() {
        let r = SystemHUDStore.Reading(channel: .volume, value: 0.8, muted: true)
        XCTAssertEqual(r.fill, 0)
        XCTAssertEqual(r.percent, 0)
        XCTAssertEqual(r.symbolName, "speaker.slash.fill")
    }

    /// 亮度只分两档，且没有「静音」这回事
    func test亮度图标按半分两档() {
        XCTAssertEqual(brightness(0).symbolName, "sun.min.fill")
        XCTAssertEqual(brightness(0.49).symbolName, "sun.min.fill")
        XCTAssertEqual(brightness(0.5).symbolName, "sun.max.fill")
        XCTAssertEqual(brightness(1).symbolName, "sun.max.fill")
    }

    /// 越界值不能画出格：控制中心/别的 App 把音量写成 1.02 这种事是有的
    func test越界读数被夹回零到一() {
        XCTAssertEqual(volume(1.4).fill, 1)
        XCTAssertEqual(volume(-0.2).fill, 0)
        XCTAssertEqual(volume(1.4).percent, 100)
    }

    /// 百分比取四舍五入而不是截断：6.25% 一格，第一格截断出来是 6，
    /// 第八格 50.0 却正好整——刻度看着忽紧忽松
    func test百分比四舍五入() {
        XCTAssertEqual(volume(0.0625).percent, 6)
        XCTAssertEqual(volume(0.625).percent, 63)
        XCTAssertEqual(volume(0.996).percent, 100)
    }

    // MARK: - 展示

    /// 预览通道（设置页/离屏渲染用）只摆帧，不碰真实音量亮度
    func test预览直接摆一帧并可清空() {
        let store = SystemHUDStore()
        XCTAssertNil(store.reading)
        store.preview(volume(0.5))
        XCTAssertEqual(store.reading, volume(0.5))
        store.preview(nil)
        XCTAssertNil(store.reading)
    }

    /// 两个开关都关时 `start()` 不该装事件 tap——留一个空转的 tap 在那儿，
    /// 所有媒体键都要白白过一遍我们的回调
    func test两个开关都关时不装拦截() {
        let d = UserDefaults.standard
        let (v, b) = (d.bool(forKey: PrefKey.volumeHUDEnabled),
                      d.bool(forKey: PrefKey.brightnessHUDEnabled))
        defer {
            d.set(v, forKey: PrefKey.volumeHUDEnabled)
            d.set(b, forKey: PrefKey.brightnessHUDEnabled)
        }
        d.set(false, forKey: PrefKey.volumeHUDEnabled)
        d.set(false, forKey: PrefKey.brightnessHUDEnabled)

        let store = SystemHUDStore()
        store.start()
        XCTAssertFalse(store.isIntercepting)
        store.stop()
    }

    // MARK: -

    private func volume(_ v: Double) -> SystemHUDStore.Reading {
        SystemHUDStore.Reading(channel: .volume, value: v, muted: false)
    }

    private func brightness(_ v: Double) -> SystemHUDStore.Reading {
        SystemHUDStore.Reading(channel: .brightness, value: v, muted: false)
    }
}
