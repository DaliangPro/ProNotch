import XCTest
@testable import ProNotch

/// 「显示屏幕」筛选口径（NotchGeometry.pick 纯函数）。
/// 约定：列表首项是主屏（与 NSScreen.screens 一致），其余为副屏
final class NotchScreenModeTests: XCTestCase {
    private let dual = ["主屏", "副屏"]
    private let triple = ["主屏", "副屏A", "副屏B"]
    private let single = ["主屏"]

    func test全部屏幕原样返回() {
        XCTAssertEqual(NotchGeometry.pick(dual, mode: .all), dual)
        XCTAssertEqual(NotchGeometry.pick(triple, mode: .all), triple)
    }

    func test仅主屏只留首项() {
        XCTAssertEqual(NotchGeometry.pick(dual, mode: .primary), ["主屏"])
        XCTAssertEqual(NotchGeometry.pick(triple, mode: .primary), ["主屏"])
    }

    func test仅副屏留下除主屏外全部() {
        XCTAssertEqual(NotchGeometry.pick(dual, mode: .secondary), ["副屏"])
        XCTAssertEqual(NotchGeometry.pick(triple, mode: .secondary), ["副屏A", "副屏B"],
                       "三屏时两块副屏都要有，不是只取一块")
    }

    /// 拔掉外接屏后若严格执行「仅副屏」，刘海会整个消失——用户只会当成 App 坏了，
    /// 且没有任何提示能让人联想到是这个设置。故退回主屏
    func test仅副屏但只剩一块屏时退回主屏() {
        XCTAssertEqual(NotchGeometry.pick(single, mode: .secondary), ["主屏"])
    }

    func test无屏幕时返回空() {
        XCTAssertEqual(NotchGeometry.pick([String](), mode: .all), [])
        XCTAssertEqual(NotchGeometry.pick([String](), mode: .secondary), [])
    }

    // MARK: - 镜像去重（dedupeMirrored）

    /// 镜像显示时 NSScreen.screens 返回多块 frame 相同的屏，逐块建窗会让刘海在同一像素叠一层
    ///（右侧关闭只留内存环时表现为「两个内存环叠在一起」）。同 frame 只留第一块
    func test镜像同frame只留一块() {
        let a = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let mirrored = [("内建", a), ("镜像副本", a)]
        let kept = NotchGeometry.dedupeMirrored(mirrored, frame: { $0.1 })
        XCTAssertEqual(kept.map(\.0), ["内建"], "镜像重复的第二块该被去掉，避免刘海叠一层")
    }

    /// 非镜像的多屏 frame 各不相同，一块都不能少
    func test扩展屏frame不同全保留() {
        let builtin = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let extended = [("内建", builtin), ("外接", external)]
        let kept = NotchGeometry.dedupeMirrored(extended, frame: { $0.1 })
        XCTAssertEqual(kept.map(\.0), ["内建", "外接"], "扩展屏各自独立，不该被误去重")
    }

    func test去重保序且首块优先() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 100, y: 0, width: 100, height: 100)
        let items = [("1", a), ("2", b), ("3", a), ("4", b)]
        let kept = NotchGeometry.dedupeMirrored(items, frame: { $0.1 })
        XCTAssertEqual(kept.map(\.0), ["1", "2"], "重复项按首次出现保留、顺序不变")
    }
}
