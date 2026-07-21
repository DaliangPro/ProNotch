import XCTest
import CoreGraphics
@testable import ProNotch

/// 长截图的串行化与资源上限。
///
/// 两类问题：
/// ① 拼接器过去是 `@unchecked Sendable` 的类，内部有可变段数组与灰度缓存，
///    而接帧在后台跑、用户点「停止」或「双击预览」会同时来调 `result()`——
///    靠"调用方记得 await"保证串行是没有强制力的。改 actor 后由编译器保证。
/// ② 没有任何上限：无限滚动页面能一直拼到内存耗尽，且失败点在最后
///    `result()` 一次性分配整张 RGBA buffer 的那一刻，此时录了几分钟的内容全部作废。
final class LongShotConcurrencyAndLimitsTests: XCTestCase {

    private let W = 360, H = 300, LINE = 24, PAGE = 1200

    // ===== 页面合成（与 LongShotStitcherTests 同法：确定性伪随机，禁 Date/random）=====

    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
        mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    }

    private func makePage() -> [UInt8] {
        var rng = LCG(state: 42)
        var page = [UInt8](repeating: 245, count: PAGE * W)
        for line in 0..<(PAGE / LINE) {
            var rowTpl = [UInt8](repeating: 245, count: W)
            var x = rng.int(4, 16)
            while x < W - 6 {
                let w = rng.int(2, 5), gap = rng.int(1, 3)
                if rng.int(0, 3) > 0 { for i in x..<min(x + w, W) { rowTpl[i] = 40 } }
                x += w + gap
                if rng.int(0, 11) == 0 { x += rng.int(6, 20) }
            }
            for r in 0..<(LINE - 7) {
                let y = line * LINE + r + 3
                guard y < PAGE else { break }
                for xx in 0..<W {
                    page[y * W + xx] = (xx * 7 + r * 13) % 5 == 0 ? 245 : rowTpl[xx]
                }
            }
        }
        return page
    }

    private func frame(_ page: [UInt8], off: Int, seed: UInt64) -> CGImage {
        var rng = LCG(state: seed)
        var buf = [UInt8](repeating: 0, count: H * W)
        for i in 0..<(H * W) {
            buf[i] = UInt8(max(0, min(255, Int(page[off * W + i]) + rng.int(-4, 4))))
        }
        var b = buf
        let ctx = b.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: W, height: H, bitsPerComponent: 8,
                      bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        }
        return ctx.makeImage()!
    }

    /// 小上限的拼接器，省得真去拼一张 6700 万像素的图
    private func stitcher(_ page: [UInt8], limits: LongShotLimits,
                          startedAt: TimeInterval = 0) throws -> LongShotStitcher {
        try XCTUnwrap(LongShotStitcher(firstFrame: frame(page, off: 0, seed: 1),
                                       startedAt: startedAt, limits: limits))
    }

    private func loose(maxHeight: Int = 1_000_000, maxPixels: Int = 1_000_000_000,
                       maxSegments: Int = 100_000, maxDuration: TimeInterval = 100_000) -> LongShotLimits {
        LongShotLimits(maxPixels: maxPixels, maxHeight: maxHeight,
                       maxSegments: maxSegments, maxDuration: maxDuration)
    }

    // MARK: - 串行化

    func test接帧与取结果并发_结果自洽() async throws {
        let page = makePage()
        let st = try stitcher(page, limits: loose())
        // 一边持续接帧，一边持续取结果——过去这会同时读写 segments 数组
        async let ingest: Void = {
            var off = 0
            for (i, step) in [55, 48, 62, 50, 57, 44, 51].enumerated() {
                off += step
                _ = await st.addFrame(self.frame(page, off: off, seed: UInt64(100 + i)), expectedDelta: 55, at: 0)
            }
        }()
        async let probes: [Int] = {
            var heights: [Int] = []
            for _ in 0..<7 {
                let cg = await st.result()
                let total = await st.totalHeight
                // 每次取到的结果都必须是一个自洽的快照：高度 == 当时的 totalHeight
                heights.append((cg?.height ?? -1) - total)
            }
            return heights
        }()
        _ = await ingest
        let deltas = await probes
        XCTAssertTrue(deltas.allSatisfy { $0 == 0 }, "每次取结果都应是自洽快照，实测偏差 \(deltas)")

        let total = await st.totalHeight
        let final = await st.result()
        XCTAssertEqual(final?.height, total)
        XCTAssertEqual(total, H + 55 + 48 + 62 + 50 + 57 + 44 + 51, "并发取结果不应干扰拼接")
    }

    func test停止时等最后一帧落定() async throws {
        let page = makePage()
        let st = try stitcher(page, limits: loose())
        let before = await st.totalHeight

        // 模拟「停止」：最后一帧的处理任务还在途，先 await 它的 value 再取结果——
        // 这正是改掉 sleep 250ms 猜测后的做法
        let inflight = Task { await st.addFrame(self.frame(page, off: 55, seed: 7), expectedDelta: 55, at: 0) }
        _ = await inflight.value

        let cg = await st.result()
        XCTAssertEqual(cg?.height, before + 55, "最后一帧必须已落定在结果里")
    }

    func test已取消的任务不再接帧() async throws {
        let page = makePage()
        let st = try stitcher(page, limits: loose())
        let before = await st.totalHeight

        let t = Task { () -> LongShotIngest in
            // 取消后 sleep 立刻抛出，走到 addFrame 时 isCancelled 必为 true
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return await st.addFrame(self.frame(page, off: 55, seed: 7), expectedDelta: 55, at: 0)
        }
        t.cancel()
        let outcome = await t.value

        XCTAssertEqual(outcome, .skipped, "取消后的迟到帧不得写入")
        let after = await st.totalHeight
        XCTAssertEqual(after, before, "取消后结果不应再增长")
    }

    // MARK: - 资源上限

    func test像素上限_加段前就拒收() async throws {
        let page = makePage()
        // 首帧 360×300 = 108000 像素；再加 55 行（19800 像素）就会越过 120000
        let st = try stitcher(page, limits: loose(maxPixels: 120_000))
        let outcome = await st.addFrame(frame(page, off: 55, seed: 2), expectedDelta: 55, at: 0)
        XCTAssertEqual(outcome, .rejected(.pixels))

        let total = await st.totalHeight
        XCTAssertEqual(total, H, "撞上限的那一段不能被加进去")
        let reason = await st.limitReason
        XCTAssertEqual(reason, .pixels)
        // 结果照常可取：已拼的内容不作废，只是不再增长
        let cg = await st.result()
        XCTAssertEqual(cg?.height, H)
    }

    func test高度上限() async throws {
        let page = makePage()
        let st = try stitcher(page, limits: loose(maxHeight: H + 100))
        var outcome = await st.addFrame(frame(page, off: 55, seed: 2), expectedDelta: 55, at: 0)
        XCTAssertEqual(outcome, .appended(rows: 55), "还没到上限，正常接")
        outcome = await st.addFrame(frame(page, off: 110, seed: 3), expectedDelta: 55, at: 0)
        XCTAssertEqual(outcome, .rejected(.height), "再接就越过 \(H + 100)，必须拒收")
        let total = await st.totalHeight
        XCTAssertEqual(total, H + 55)
    }

    func test段数上限() async throws {
        let page = makePage()
        // 首帧已占 1 段，上限 2 段 → 只能再接一段
        let st = try stitcher(page, limits: loose(maxSegments: 2))
        var outcome = await st.addFrame(frame(page, off: 55, seed: 2), expectedDelta: 55, at: 0)
        XCTAssertEqual(outcome, .appended(rows: 55))
        outcome = await st.addFrame(frame(page, off: 110, seed: 3), expectedDelta: 55, at: 0)
        XCTAssertEqual(outcome, .rejected(.segments))
    }

    func test时长上限() async throws {
        let page = makePage()
        let st = try stitcher(page, limits: loose(maxDuration: 30), startedAt: 1000)
        var outcome = await st.addFrame(frame(page, off: 55, seed: 2), expectedDelta: 55, at: 1029)
        XCTAssertEqual(outcome, .appended(rows: 55), "29 秒还在预算内")
        outcome = await st.addFrame(frame(page, off: 110, seed: 3), expectedDelta: 55, at: 1031)
        XCTAssertEqual(outcome, .rejected(.duration), "31 秒超出 30 秒上限")
        let reason = await st.limitReason
        XCTAssertEqual(reason, .duration)
    }

    func test撞上限后不再增长_也不再重新判定() async throws {
        let page = makePage()
        let st = try stitcher(page, limits: loose(maxHeight: H + 10))
        _ = await st.addFrame(frame(page, off: 55, seed: 2), expectedDelta: 55, at: 0)
        // 后续每一帧都直接被挡，且原因保持首次触发的那个
        for (i, off) in [110, 165, 220].enumerated() {
            let outcome = await st.addFrame(frame(page, off: off, seed: UInt64(30 + i)), expectedDelta: 55, at: 0)
            XCTAssertEqual(outcome, .rejected(.height), "第 \(i + 1) 次续接")
        }
        let total = await st.totalHeight
        XCTAssertEqual(total, H, "一行都不该增长")
    }

    func test上限原因都有面向用户的说明() {
        for reason in [LongShotLimits.Reason.pixels, .height, .segments, .duration] {
            XCTAssertTrue(reason.message.contains("安全上限"), "\(reason) 的提示应说明是安全收尾而非出错")
        }
    }

    func test默认上限按256MB预算换算() {
        XCTAssertEqual(LongShotLimits.default.maxPixels, 256 * 1024 * 1024 / 4)
        XCTAssertGreaterThan(LongShotLimits.default.maxHeight, 0)
        XCTAssertGreaterThan(LongShotLimits.default.maxSegments, 0)
        XCTAssertGreaterThan(LongShotLimits.default.maxDuration, 0)
    }
}
