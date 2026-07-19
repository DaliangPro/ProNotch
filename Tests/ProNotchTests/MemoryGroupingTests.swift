import XCTest
@testable import ProNotch

/// 内存排行按 App 聚合的回归护栏：Helper 归并宿主、嵌套取最外层、非 App 不归并
final class MemoryGroupingTests: XCTestCase {
    func testHelper深路径归并到宿主App() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/"
            + "Google Chrome Framework.framework/Versions/141.0/Helpers/"
            + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(MemoryGrouping.appBundlePath(of: helper), "/Applications/Google Chrome.app")
    }

    func test主进程返回自身bundle() {
        XCTAssertEqual(MemoryGrouping.appBundlePath(of: "/Applications/Safari.app/Contents/MacOS/Safari"),
                       "/Applications/Safari.app")
    }

    func test嵌套app取最外层() {
        let sim = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
        XCTAssertEqual(MemoryGrouping.appBundlePath(of: sim), "/Applications/Xcode.app")
    }

    func test非App进程返回空() {
        XCTAssertNil(MemoryGrouping.appBundlePath(of: "/usr/bin/zsh"))
        XCTAssertNil(MemoryGrouping.appBundlePath(of: "/opt/homebrew/bin/node"))
    }

    func test点app必须是完整目录名后缀() {
        // 「.appstuff」目录不是 .app bundle；末段可执行文件名本身也不参与匹配
        XCTAssertNil(MemoryGrouping.appBundlePath(of: "/opt/my.appstuff/bin/tool"))
        XCTAssertNil(MemoryGrouping.appBundlePath(of: "/usr/local/bin/foo.app"))
    }
}
