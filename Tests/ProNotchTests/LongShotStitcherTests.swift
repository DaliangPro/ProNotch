import XCTest
import CoreGraphics
@testable import ProNotch

/// 长截图拼接器回归护栏：合成"密集文字"页面 → 按已知偏移取帧（带确定性噪声）→
/// 断言拼接器测得的 δ 与真实偏移完全一致。曾经的重叠/缺行 bug 都会在这里现形。
final class LongShotStitcherTests: XCTestCase {
    // ===== 确定性伪随机（禁 Date/random，可复现）=====
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
        mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    }

    private let W = 360, H = 300, LINE = 24, PAGE = 1200

    /// 合成页面：行高 24 的"文字"行（行内逐像素行变化，惩罚差一像素的错配）
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
                    let masked = (xx * 7 + r * 13) % 5 == 0
                    page[y * W + xx] = masked ? 245 : rowTpl[xx]
                }
            }
        }
        return page
    }

    /// 页面 off 行起取一帧，叠 ±4 确定性噪声（模拟亚像素重渲染差异）
    private func frame(_ page: [UInt8], off: Int, seed: UInt64) -> CGImage {
        var rng = LCG(state: seed)
        var buf = [UInt8](repeating: 0, count: H * W)
        for i in 0..<(H * W) {
            let v = Int(page[off * W + i]) + rng.int(-4, 4)
            buf[i] = UInt8(max(0, min(255, v)))
        }
        return grayImage(buf)
    }

    private func grayImage(_ buf: [UInt8]) -> CGImage {
        var b = buf
        let ctx = b.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: W, height: H, bitsPerComponent: 8,
                      bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        }
        return ctx.makeImage()!
    }

    /// 纯噪声帧（模拟画面突变/遮挡，应被拼接器拒收）
    private func garbageFrame(seed: UInt64) -> CGImage {
        var rng = LCG(state: seed)
        var buf = [UInt8](repeating: 0, count: H * W)
        for i in 0..<(H * W) { buf[i] = UInt8(rng.int(0, 255)) }
        return grayImage(buf)
    }

    // ===== 用例 =====

    func test向下拼接_测得偏移与真实一致() async throws {
        let page = makePage()
        let stitcher = try XCTUnwrap(LongShotStitcher(firstFrame: frame(page, off: 0, seed: 1)))
        var off = 0
        for (i, step) in [55, 48, 62, 50, 57].enumerated() {
            off += step
            let got = await stitcher.addFrame(frame(page, off: off, seed: UInt64(2 + i)), expectedDelta: 55)
            XCTAssertEqual(got, .appended(rows: step), "第 \(i + 1) 帧测得 δ=\(got.rows)，真实=\(step)")
        }
        let total = await stitcher.totalHeight
        XCTAssertEqual(total, H + 55 + 48 + 62 + 50 + 57)
        let result = await stitcher.result()
        XCTAssertEqual(result?.height, total)
    }

    func test向上拼接_测得偏移与真实一致() async throws {
        let page = makePage()
        var off = 600
        let stitcher = try XCTUnwrap(LongShotStitcher(firstFrame: frame(page, off: off, seed: 11)))
        for (i, step) in [45, 52, 40].enumerated() {
            off -= step
            let got = await stitcher.prependFrame(frame(page, off: off, seed: UInt64(12 + i)), expectedDelta: 45)
            XCTAssertEqual(got, .appended(rows: step), "第 \(i + 1) 帧测得 δ=\(got.rows)，真实=\(step)")
        }
        let total = await stitcher.totalHeight
        XCTAssertEqual(total, H + 45 + 52 + 40)
    }

    func test坏帧拒收_内容不丢_下帧累计接回() async throws {
        let page = makePage()
        let stitcher = try XCTUnwrap(LongShotStitcher(firstFrame: frame(page, off: 0, seed: 21)))
        var got = await stitcher.addFrame(frame(page, off: 50, seed: 22), expectedDelta: 55)
        XCTAssertEqual(got, .appended(rows: 50))
        // 画面突变的坏帧：拒收（.skipped，而不是"撞上限"），且保留参考帧
        got = await stitcher.addFrame(garbageFrame(seed: 23), expectedDelta: 55)
        XCTAssertEqual(got, .skipped)
        // 坏帧期间页面又滚了 45：下一帧应测得「累计」45，中间内容一行不丢
        got = await stitcher.addFrame(frame(page, off: 95, seed: 24), expectedDelta: 55)
        XCTAssertEqual(got, .appended(rows: 45))
        let total = await stitcher.totalHeight
        XCTAssertEqual(total, H + 50 + 45)
    }

    func test方向探测() async throws {
        let page = makePage()
        let stitcher = try XCTUnwrap(LongShotStitcher(firstFrame: frame(page, off: 400, seed: 31)))
        var d = await stitcher.probeDirection(frame(page, off: 430, seed: 32))
        XCTAssertEqual(d, 1, "内容向下滚应返回 +1")
        d = await stitcher.probeDirection(frame(page, off: 370, seed: 33))
        XCTAssertEqual(d, -1, "内容向上滚应返回 -1")
        d = await stitcher.probeDirection(frame(page, off: 400, seed: 34))
        XCTAssertEqual(d, 0, "没动应返回 0")
    }
}
