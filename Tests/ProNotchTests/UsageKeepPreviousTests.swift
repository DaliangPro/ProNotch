import XCTest
@testable import ProNotch

/// 「这一轮没问到额度」时该怎么办。
///
/// 由来（2026-07-28 大梁老师实测）：Codex 额度会莫名跳回一个老数字——手动刷新能改对、
/// 过一会儿又变回去。根因是问不到官方端点时会去翻 `~/.codex/sessions` 里最后一条记录，
/// 而那是**上次用 Codex 时**写的，隔夜就成了 18 小时前的 72%，可额度当天早上早已重置为 0。
///
/// 拿旧数据顶上这件事本身就是错的。现在只有两种结果：问到就更新，问不到就什么都不做。
/// 这里钉住的就是「什么都不做」——既不能清空（界面退回转圈，看着像坏了），
/// 也不能拿别处的旧数据补位。
@MainActor
final class UsageKeepPreviousTests: XCTestCase {

    private func quota(_ pct: Double) -> ServiceQuota {
        ServiceQuota(primary: QuotaWindow(usedPercent: pct, usedTokens: nil, resetsAt: nil,
                                          windowMinutes: 10080, isEstimate: false),
                     dataAt: Date())
    }

    private func pct(_ q: ServiceQuota?) -> Double? { q?.primary?.usedPercent }

    /// 核心回归：勾了这家、但这轮没问到，界面上的数字必须原样留着
    func test没问到就保持上一轮的数字() {
        let kept = UsageStore.merged(nil, previous: quota(0), enabled: true)
        XCTAssertEqual(pct(kept), 0, "没问到不该动界面上已有的数字")
    }

    /// 尤其不能清成 nil——额度卡会退回转圈，用户会以为功能坏了
    func test没问到时不许清空() {
        XCTAssertNotNil(UsageStore.merged(nil, previous: quota(42), enabled: true))
    }

    /// 问到了就换上新的，哪怕新数字比旧的小（额度重置就是这种情形：72% → 0%）
    func test问到就换上新数字() {
        let updated = UsageStore.merged(quota(0), previous: quota(72), enabled: true)
        XCTAssertEqual(pct(updated), 0)
    }

    /// 取消勾选优先级最高：这家整个从界面消失，旧数字不许留着
    func test取消勾选就清空() {
        XCTAssertNil(UsageStore.merged(quota(50), previous: quota(50), enabled: false))
        XCTAssertNil(UsageStore.merged(nil, previous: quota(50), enabled: false))
    }

    /// 刚启动就没网：本来就没有上一轮，保持 nil（界面转圈等第一次成功），
    /// 而不是凭空造一个数字出来
    func test首次就没问到保持空() {
        XCTAssertNil(UsageStore.merged(nil, previous: nil, enabled: true))
    }

    /// 带错误的结果算「问到了」——凭据坏了要让用户看见，不能被旧数字盖住。
    /// 「未登录 / 登录已过期」是他得动手的事，静默保持只会让他一直看着个过期数字
    func test凭据类错误要顶掉旧数字() {
        let broken = ServiceQuota(error: "Codex 登录已过期，在终端重新 codex login")
        let r = UsageStore.merged(broken, previous: quota(30), enabled: true)
        XCTAssertNil(pct(r), "错误状态不该还挂着旧百分比")
        XCTAssertNotNil(r?.error)
    }
}
