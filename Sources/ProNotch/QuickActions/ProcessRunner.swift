import Foundation

/// 子进程跑完之后的结果
struct ProcessResult: Equatable, Sendable {
    let status: Int32
    let stderr: String

    var succeeded: Bool { status == 0 }
}

/// 子进程执行器。
///
/// 病灶：快捷操作原先只 `try task.run()` 就立刻改 UI —— `run()` 只保证「进程起来了」，
/// 不保证「干成了」。osascript 没拿到自动化授权、`defaults write` 被拒、
/// `killall Finder` 找不到进程，全都会静默失败，而开关已经翻过去了：
/// 界面说净屏开着，桌面图标还在。
///
/// 对策：抽成协议，后台等退出，把 `terminationStatus` 和 stderr 一起带回来。
/// 抽协议还有一个现实理由——真跑 osascript 既要自动化授权，
/// 又会真的把大梁老师的系统外观改掉，这种事不能在测试里发生。
protocol ProcessRunning: Sendable {
    /// 启动失败（可执行文件不存在、权限不足）抛错；
    /// 只要进程跑起来了就返回退出码与 stderr，由调用方判断成败
    func run(executable: String, arguments: [String]) async throws -> ProcessResult
}

struct SystemProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            // 等退出是阻塞的，扔到后台队列，别占着主线程
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                let errPipe = Pipe()
                task.standardError = errPipe
                task.standardOutput = FileHandle.nullDevice
                do {
                    try task.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                // 先读干管道再等退出：反过来会在 stderr 写满管道缓冲区时双向死锁
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                cont.resume(returning: ProcessResult(status: task.terminationStatus,
                                                     stderr: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// stderr → 用户能看懂的一句话。
///
/// 只做**白名单映射**：命中已知失败签名就给对应指引，否则只报动作名和退出码。
/// 绝不把 stderr 原文回显到界面——它常年带着绝对路径（含用户名）、脚本原文、
/// 系统内部对象名，对用户毫无帮助，泄露却是实打实的。
enum ProcessFailureMessage {
    static func text(action: String, result: ProcessResult) -> String {
        let raw = result.stderr
        // -1743：未获自动化授权，这是外观切换最常见的失败
        if raw.contains("-1743") || raw.localizedCaseInsensitiveContains("not authorized") {
            return "\(action)失败：系统未授权 ProNotch 控制「系统事件」，请到系统设置 → 隐私与安全性 → 自动化中勾选。"
        }
        // -1728：脚本接口在新系统上换了对象名
        if raw.contains("-1728") {
            return "\(action)失败：系统脚本接口未返回预期对象，可能是系统版本差异。"
        }
        if raw.localizedCaseInsensitiveContains("no matching processes") {
            return "\(action)失败：访达当前未在运行，稍后重试即可。"
        }
        if raw.localizedCaseInsensitiveContains("operation not permitted")
            || raw.localizedCaseInsensitiveContains("permission denied") {
            return "\(action)失败：系统拒绝了本次操作（权限不足）。"
        }
        return "\(action)失败（退出码 \(result.status)）。"
    }
}
