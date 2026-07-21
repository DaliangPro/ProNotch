import AppKit
import Foundation

/// 写文件这一步抽成协议，测试才有办法制造「磁盘满」「没权限」这类真实故障——
/// 否则这条失败路径只能靠拔硬盘来验
protocol ImageFileWriting: Sendable {
    func write(_ data: Data, to url: URL) throws
}

struct DiskImageWriter: ImageFileWriting {
    func write(_ data: Data, to url: URL) throws {
        // withoutOverwriting：万一唯一名算完到写入之间又冒出同名文件，
        // 宁可报错重来，也不能把人家的文件盖掉
        try data.write(to: url, options: .withoutOverwriting)
    }
}

/// 截图落盘。
///
/// 病灶：原实现是 `try? png.write(to: url)` 紧跟一句 `close()`。
/// 磁盘满、桌面没写权限、编码返回 nil——任何一种失败都被 `try?` 咽掉，
/// overlay 照样关闭、长截图结果照样清理。用户以为存好了，桌面上什么都没有，
/// 而那张几万像素高、刚滚了半分钟才拼出来的长图已经没了。
///
/// 对策：写盘返回 `Result`，成功才关窗清理；失败保留结果并说明原因，
/// 复制、重试保存、丢弃三条路都还在。
enum ScreenshotSaver {

    enum Failure: Error, Equatable {
        case encodingFailed
        case writeFailed(String)

        var message: String {
            switch self {
            case .encodingFailed:
                return "图片编码失败，未能保存。内容还在，可以重试或复制。"
            case .writeFailed(let detail):
                return "保存到桌面失败：\(detail)。内容还在，可以重试或复制。"
            }
        }
    }

    /// 保存之后该怎么办。抽出来是为了让「失败不关窗、重试成功才关窗」
    /// 这条规则本身可测——overlay 那边只剩一个 switch
    enum Outcome: Equatable {
        case close(URL)
        case keepOpen(String)
    }

    static var desktop: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    static func timestamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return fmt.string(from: date)
    }

    /// 目标文件名：`截图 2026-07-21 10.30.00.png`；已存在就追加 `-2`、`-3`……
    /// 同一秒内连存两张是常事，不排重就是直接覆盖掉前一张
    static func uniqueURL(in directory: URL, prefix: String, date: Date, attempt: Int = 0,
                          exists: (URL) -> Bool = {
                              FileManager.default.fileExists(atPath: $0.path)
                          }) -> URL {
        let stamp = timestamp(date)
        var index = max(1, attempt + 1)
        while true {
            let name = index == 1 ? "\(prefix) \(stamp).png" : "\(prefix) \(stamp)-\(index).png"
            let candidate = directory.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            index += 1
            // 同一秒里排到 99 张：不再纠缠，交给写入端的 withoutOverwriting 报错
            if index > 99 { return candidate }
        }
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func pngData(_ cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// 编码后的数据写到桌面。`data` 为 nil 表示编码那步就失败了。
    ///
    /// 唯一名算出来到真正写入之间仍有窗口期，撞上就换下一个名字重来（最多几次），
    /// 而不是覆盖已有文件
    static func save(_ data: Data?, prefix: String, date: Date,
                     directory: URL? = nil,
                     writer: ImageFileWriting = DiskImageWriter(),
                     exists: ((URL) -> Bool)? = nil) -> Result<URL, Failure> {
        guard let data else { return .failure(.encodingFailed) }
        let directory = directory ?? desktop
        let exists = exists ?? { FileManager.default.fileExists(atPath: $0.path) }

        var lastError: Error?
        for attempt in 0..<5 {
            let url = uniqueURL(in: directory, prefix: prefix, date: date,
                                attempt: attempt, exists: exists)
            do {
                try writer.write(data, to: url)
                return .success(url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                lastError = error   // 名字被别人抢先占了，换一个再来
                continue
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
        }
        return .failure(.writeFailed(lastError?.localizedDescription ?? "文件名冲突"))
    }

    /// 成功才关窗；失败留在原地，把原因交给调用方去显示
    static func outcome(for result: Result<URL, Failure>) -> Outcome {
        switch result {
        case .success(let url): return .close(url)
        case .failure(let failure): return .keepOpen(failure.message)
        }
    }
}
