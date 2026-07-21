import XCTest
@testable import ProNotch

/// 进程排行的扫描不该占着主线程，也不该自己叠自己。
///
/// 病灶：proc_listallpids 全量遍历 + 每进程一次 proc_pid_rusage 原先全跑在主线程，
/// 还挂着 3 秒定时器。开着 Chrome 和 Xcode 时进程轻松五六百个，
/// 每趟几十毫秒的卡顿就这么周期性地砸在界面上；上一趟没跑完下一趟又来了。
@MainActor
final class MemoryScanConcurrencyTests: XCTestCase {

    /// 可控扫描器：调用方说放行才返回，用来把「两趟重叠」摆成确定的场面
    private actor GateScanner: ProcessMemoryScanning {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var samples: [ProcessMemorySample]
        private(set) var scanCount = 0

        init(_ samples: [ProcessMemorySample] = []) { self.samples = samples }

        func scan() async -> [ProcessMemorySample] {
            scanCount += 1
            await withCheckedContinuation { waiters.append($0) }
            return samples
        }

        func setSamples(_ new: [ProcessMemorySample]) { samples = new }

        func release() {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }

        /// 等到确实有 n 趟扫描卡在门口，避免靠 sleep 猜时序
        func waitUntilScanned(_ n: Int) async {
            while scanCount < n { await Task.yield() }
        }
    }

    private func sample(_ key: String, _ footprint: UInt64, app: String? = nil) -> ProcessMemorySample {
        ProcessMemorySample(key: key, appPath: app, fallbackName: key, footprint: footprint)
    }

    // MARK: - 重叠刷新

    func test重叠refresh不产生两趟并发全量扫描() async {
        let scanner = GateScanner([sample("a", 100)])
        let store = MemoryStore(scanner: scanner)

        store.refreshTopProcesses()
        await scanner.waitUntilScanned(1)
        store.refreshTopProcesses()   // 定时器又到点了，但上一趟还没回来
        store.refreshTopProcesses()
        // 后两次若没被挡住，它们的 Task 会在这几轮里跑起来并把 scanCount 顶到 3
        for _ in 0..<50 { await Task.yield() }

        let count = await scanner.scanCount
        XCTAssertEqual(count, 1, "同一时刻只该有一趟全量扫描在跑")

        await scanner.release()
        await store.waitForScan()
        XCTAssertEqual(store.topProcesses.map(\.id), ["a"])
    }

    func test上一趟落地之后才允许开下一趟() async {
        let scanner = GateScanner([sample("a", 100)])
        let store = MemoryStore(scanner: scanner)

        store.refreshTopProcesses()
        await scanner.waitUntilScanned(1)
        await scanner.release()
        await store.waitForScan()

        await scanner.setSamples([sample("b", 200)])
        store.refreshTopProcesses()
        await scanner.waitUntilScanned(2)
        await scanner.release()
        await store.waitForScan()

        XCTAssertEqual(store.topProcesses.map(\.id), ["b"], "跑完一趟就该能接着跑下一趟")
    }

    // MARK: - 迟到结果

    func test迟到的旧扫描结果不覆盖新结果() async {
        let scanner = GateScanner([sample("new", 999)])
        let store = MemoryStore(scanner: scanner)

        // 先让一趟新的落地，代际推到 1
        store.refreshTopProcesses()
        await scanner.waitUntilScanned(1)
        await scanner.release()
        await store.waitForScan()
        XCTAssertEqual(store.topProcesses.map(\.id), ["new"])

        // 一趟更早出发、被 stop() 取消过、却已越过 await 的扫描现在才回来
        store.apply([sample("stale", 1)], count: 15, generation: 0)

        XCTAssertEqual(store.topProcesses.map(\.id), ["new"],
                       "旧代际的结果不能把新数据顶掉")
    }

    func test取消后的扫描结果不落地() async {
        let scanner = GateScanner([sample("cancelled", 100)])
        let store = MemoryStore(scanner: scanner)

        store.refreshTopProcesses()
        await scanner.waitUntilScanned(1)
        store.stop()                 // 窗口重建/退出
        await scanner.release()
        // stop() 已经把 scanTask 置空，waitForScan 等不到它；
        // 多让几轮，确保那趟被取消的扫描真的醒过来跑完了才断言
        for _ in 0..<50 { await Task.yield() }

        XCTAssertTrue(store.topProcesses.isEmpty, "已取消的那趟不该再改 UI")
    }

    // MARK: - 后台只出纯数据

    func test上榜的App在主线程才解析名字与图标() async {
        // 系统自带 App，路径稳定；名字与图标都得等主线程 apply 时才取
        let calculator = "/System/Applications/Calculator.app"
        let scanner = GateScanner([
            ProcessMemorySample(key: calculator, appPath: calculator,
                                fallbackName: "Calculator", footprint: 500),
            sample("/usr/sbin/some-daemon", 100),
        ])
        let store = MemoryStore(scanner: scanner)

        store.refreshTopProcesses()
        await scanner.waitUntilScanned(1)
        await scanner.release()
        await store.waitForScan()

        XCTAssertEqual(store.topProcesses.count, 2)
        XCTAssertNotNil(store.topProcesses.first?.icon, "App 条目的图标在主线程取到")
        XCTAssertFalse(store.topProcesses.first?.name.hasSuffix(".app") ?? true,
                       "取的是本地化显示名，不带扩展名")
        XCTAssertNil(store.topProcesses.last?.icon, "纯进程没有图标，视图给兜底符号")
    }

    func test只发布前N名() async {
        let scanner = GateScanner((1...20).map { sample("p\($0)", UInt64($0) * 100) })
        let store = MemoryStore(scanner: scanner)

        store.refreshTopProcesses(count: 3)
        await scanner.waitUntilScanned(1)
        await scanner.release()
        await store.waitForScan()

        XCTAssertEqual(store.topProcesses.count, 3)
    }

    // MARK: - 聚合纯函数

    func test同一App的多个Helper合并成一行() {
        let merged = MemoryGrouping.merge([
            .init(execPath: "/Applications/Chrome.app/Contents/MacOS/Chrome",
                  bsdName: "Chrome", footprint: 300),
            .init(execPath: "/Applications/Chrome.app/Contents/Frameworks/Chrome Helper.app/Contents/MacOS/Chrome Helper",
                  bsdName: "Chrome Helper", footprint: 200),
            .init(execPath: "/Applications/Chrome.app/Contents/Frameworks/Chrome Helper (GPU).app/Contents/MacOS/H",
                  bsdName: "H", footprint: 100),
        ])

        XCTAssertEqual(merged.count, 1, "三个进程同属一个 App，只该占一行")
        XCTAssertEqual(merged.first?.key, "/Applications/Chrome.app")
        XCTAssertEqual(merged.first?.footprint, 600)
    }

    func test非App的多实例按可执行路径合并() {
        let merged = MemoryGrouping.merge([
            .init(execPath: "/usr/bin/ssh", bsdName: "ssh", footprint: 50),
            .init(execPath: "/usr/bin/ssh", bsdName: "ssh", footprint: 70),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.footprint, 120)
        XCTAssertNil(merged.first?.appPath)
        XCTAssertEqual(merged.first?.fallbackName, "ssh")
    }

    func test占用为零的进程不进榜() {
        XCTAssertTrue(MemoryGrouping.merge([
            .init(execPath: "/usr/bin/idle", bsdName: "idle", footprint: 0),
        ]).isEmpty)
    }

    func test读不到可执行路径时退回BSD名() {
        let merged = MemoryGrouping.merge([
            .init(execPath: nil, bsdName: "kernel_task", footprint: 42),
        ])
        XCTAssertEqual(merged.first?.fallbackName, "kernel_task")
        XCTAssertEqual(merged.first?.key, "name:kernel_task")
    }

    func test按占用降序_并列时按键定序() {
        let merged = MemoryGrouping.merge([
            .init(execPath: "/usr/bin/b", bsdName: "b", footprint: 100),
            .init(execPath: "/usr/bin/c", bsdName: "c", footprint: 300),
            .init(execPath: "/usr/bin/a", bsdName: "a", footprint: 100),
        ])
        XCTAssertEqual(merged.map(\.key), ["/usr/bin/c", "/usr/bin/a", "/usr/bin/b"],
                       "并列不定死次序的话，字典遍历顺序会让两行来回跳")
    }
}
