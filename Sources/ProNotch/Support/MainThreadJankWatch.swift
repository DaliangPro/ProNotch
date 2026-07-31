import Foundation
import os

/// 主线程卡顿哨兵：一轮 runloop 超过阈值就记一条 perf 日志。
///
/// 由来（大梁老师 2026-07-31）：闪问窗口的卡顿修了几轮，每轮都靠他上机体感回报，
/// 而离屏测不出真实的排版与绘制账。装上这个之后，下一次「还是卡」
/// 可以直接从他机器的日志里拿到确切数字（多长、多频繁、什么时候），不再靠猜。
///
/// 查看：`log show --process ProNotch --predicate 'category == "perf"' --last 10m`
///
/// 只记「慢的一轮」，不采栈——采栈的开销会自己制造卡顿。
/// 真卡死（一轮永远不结束）它记不到，那种场景用 `sample` 现场抓（见排查记忆）。
enum MainThreadJankWatch {

    /// 单轮超过这个毫秒数才算一次卡顿。120Hz 一帧 8.3ms，50ms ≈ 连丢 6 帧，肉眼可感
    private static let thresholdMS: Double = 50
    /// 日志限速：最密一秒一条，拖拽风暴不至于刷屏
    private static let minLogGap: CFTimeInterval = 1

    nonisolated(unsafe) private static var observer: CFRunLoopObserver?

    @MainActor
    static func install() {
        guard observer == nil else { return }
        var turnStart: CFTimeInterval = 0
        var lastLogged: CFTimeInterval = 0
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .beforeSources {
                // 一轮里 beforeSources 会来多次，只记第一次当起点
                if turnStart == 0 { turnStart = now }
            } else {
                // beforeWaiting = 这一轮干完了，要睡了
                if turnStart > 0 {
                    let ms = (now - turnStart) * 1000
                    if ms > thresholdMS, now - lastLogged > minLogGap {
                        lastLogged = now
                        AppLog.perf.info("主线程一轮 \(Int(ms), privacy: .public)ms")
                    }
                }
                turnStart = 0
            }
        }
        guard let obs else { return }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }
}
