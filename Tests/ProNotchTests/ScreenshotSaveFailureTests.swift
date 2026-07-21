import XCTest
import AppKit
@testable import ProNotch

/// 截图写盘失败时，结果必须留在原地。
///
/// 病灶：原实现是 `try? png.write(to: url)` 紧跟一句 `close()`。
/// 磁盘满、桌面没写权限、编码返回 nil——任何一种失败都被 try? 咽掉，
/// overlay 照样关闭、长截图结果照样清理。用户以为存好了，桌面上什么都没有；
/// 那张滚了半分钟才拼出来的长图已经没了。
final class ScreenshotSaveFailureTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1_784_000_000)
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProNotchSave-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 替身

    /// 按脚本失败的写入器：第 n 次成功、之前全失败，用来演「重试」
    private final class ScriptedWriter: ImageFileWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var remainingFailures: Int
        private let error: Error
        private(set) var written: [URL] = []
        private(set) var attempts = 0

        init(failuresBeforeSuccess: Int, error: Error = CocoaError(.fileWriteOutOfSpace)) {
            self.remainingFailures = failuresBeforeSuccess
            self.error = error
        }

        func write(_ data: Data, to url: URL) throws {
            lock.lock()
            defer { lock.unlock() }
            attempts += 1
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw error
            }
            written.append(url)
        }
    }

    private var samplePNG: Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return ScreenshotSaver.pngData(image)!
    }

    // MARK: - 写入失败

    func test写入失败时不关窗_结果仍在() {
        let writer = ScriptedWriter(failuresBeforeSuccess: 1)
        let result = ScreenshotSaver.save(samplePNG, prefix: "截图", date: date,
                                          directory: tempDir, writer: writer,
                                          exists: { _ in false })

        XCTAssertEqual(ScreenshotSaver.outcome(for: result),
                       .keepOpen(ScreenshotSaver.Failure
                        .writeFailed(CocoaError(.fileWriteOutOfSpace).localizedDescription).message))
        XCTAssertTrue(writer.written.isEmpty, "没写成就是没写成")
    }

    func test第二次重试成功之后才关窗() {
        // 第一次磁盘满 → 留窗；用户腾出空间再点一次保存 → 这次才关
        let failing = ScriptedWriter(failuresBeforeSuccess: 1)
        let first = ScreenshotSaver.save(samplePNG, prefix: "长截图", date: date,
                                         directory: tempDir, writer: failing,
                                         exists: { _ in false })
        guard case .keepOpen = ScreenshotSaver.outcome(for: first) else {
            return XCTFail("第一次应当留在原地")
        }

        let succeeding = ScriptedWriter(failuresBeforeSuccess: 0)
        let second = ScreenshotSaver.save(samplePNG, prefix: "长截图", date: date,
                                          directory: tempDir, writer: succeeding,
                                          exists: { _ in false })
        guard case .close(let url) = ScreenshotSaver.outcome(for: second) else {
            return XCTFail("重试成功就该收工了")
        }
        XCTAssertEqual(url.lastPathComponent, "长截图 \(ScreenshotSaver.timestamp(date)).png")
        XCTAssertEqual(succeeding.written, [url])
    }

    func test没有写权限也走同一条留窗路径() {
        let writer = ScriptedWriter(failuresBeforeSuccess: 99, error: CocoaError(.fileWriteNoPermission))
        let result = ScreenshotSaver.save(samplePNG, prefix: "截图", date: date,
                                          directory: tempDir, writer: writer,
                                          exists: { _ in false })
        guard case .keepOpen(let message) = ScreenshotSaver.outcome(for: result) else {
            return XCTFail("没权限也不能把结果丢了")
        }
        XCTAssertTrue(message.contains("内容还在"), "得告诉用户东西没丢，实得：\(message)")
    }

    // MARK: - 编码失败

    func test编码失败不落盘也不关窗() {
        let writer = ScriptedWriter(failuresBeforeSuccess: 0)
        // data 为 nil 就代表编码那步失败了
        let result = ScreenshotSaver.save(nil, prefix: "长截图", date: date,
                                          directory: tempDir, writer: writer)

        XCTAssertEqual(result, .failure(.encodingFailed))
        XCTAssertEqual(ScreenshotSaver.outcome(for: result),
                       .keepOpen(ScreenshotSaver.Failure.encodingFailed.message))
        XCTAssertEqual(writer.attempts, 0, "编码都没成，不该去碰磁盘")
    }

    func test编码失败后原图仍可再次编码() {
        // 「不丢失原 CGImage」的实际含义：保存这条路失败了，图还在，能再来一次
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("取不到 CGImage")
        }

        _ = ScreenshotSaver.save(nil, prefix: "长截图", date: date, directory: tempDir,
                                 writer: ScriptedWriter(failuresBeforeSuccess: 0))
        XCTAssertNotNil(ScreenshotSaver.pngData(cg), "失败一次之后原图还得能编码出来")
    }

    // MARK: - 文件名唯一

    func test同一秒连存两张不互相覆盖() throws {
        let first = ScreenshotSaver.save(samplePNG, prefix: "截图", date: date, directory: tempDir)
        let second = ScreenshotSaver.save(samplePNG, prefix: "截图", date: date, directory: tempDir)

        guard case .success(let a) = first, case .success(let b) = second else {
            return XCTFail("两次都该成功：\(first) / \(second)")
        }
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, "截图 \(ScreenshotSaver.timestamp(date)).png")
        XCTAssertEqual(b.lastPathComponent, "截图 \(ScreenshotSaver.timestamp(date))-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func test已存在的文件名会被跳过() {
        let taken = Set(["截图 \(ScreenshotSaver.timestamp(date)).png",
                         "截图 \(ScreenshotSaver.timestamp(date))-2.png"])
        let url = ScreenshotSaver.uniqueURL(in: tempDir, prefix: "截图", date: date,
                                            exists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(url.lastPathComponent, "截图 \(ScreenshotSaver.timestamp(date))-3.png")
    }

    func test算完名字到写入之间被抢占_换个名字重来而不是覆盖() {
        // exists 说没人占，写的时候却报「已存在」——真实竞态就长这样
        final class ExistsOnceWriter: ImageFileWriting, @unchecked Sendable {
            private let lock = NSLock()
            private var refused = false
            private(set) var tried: [URL] = []
            func write(_ data: Data, to url: URL) throws {
                lock.lock(); defer { lock.unlock() }
                tried.append(url)
                if !refused { refused = true; throw CocoaError(.fileWriteFileExists) }
            }
        }
        let writer = ExistsOnceWriter()
        let result = ScreenshotSaver.save(samplePNG, prefix: "截图", date: date,
                                          directory: tempDir, writer: writer,
                                          exists: { _ in false })

        guard case .success(let url) = result else { return XCTFail("换个名字就该成了") }
        XCTAssertEqual(writer.tried.count, 2)
        XCTAssertNotEqual(writer.tried[0], writer.tried[1], "第二次必须换名，不能原地覆盖")
        XCTAssertEqual(url, writer.tried[1])
    }

    // MARK: - 成功路径

    func test写入成功返回真实路径() throws {
        let result = ScreenshotSaver.save(samplePNG, prefix: "截图", date: date, directory: tempDir)
        guard case .success(let url) = result else { return XCTFail("应当成功") }

        XCTAssertEqual(ScreenshotSaver.outcome(for: result), .close(url))
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, samplePNG)
        XCTAssertEqual(written.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "确实是 PNG")
    }

    func test默认目录是桌面() {
        XCTAssertEqual(ScreenshotSaver.desktop.lastPathComponent, "Desktop")
    }
}
