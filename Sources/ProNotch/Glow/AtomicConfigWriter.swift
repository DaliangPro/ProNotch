import Foundation

/// 改写别家 Agent 配置文件的统一写入闸口。
///
/// 这些文件是用户自己的资产（`~/.codex/config.toml`、`~/.claude/settings.json` 等），
/// 我们只是往里加一条 hook。原先直接 `write(to:)` 覆盖，有三个隐患：
/// 写一半掉电/崩溃留下截断文件；生成的内容如果被解析逻辑写坏，坏内容直接落盘；
/// 权限被重置成默认值。这里统一收口：同目录临时文件 → 结构校验 → 原子替换，
/// 任一步失败原文件都保持字节不变。
enum AtomicConfigWriter {
    enum WriteError: Error, Equatable {
        /// 新内容没通过结构校验，已放弃写入
        case validationFailed
        case ioFailed(String)
    }

    /// 备份保留两代：`.pronotch.bak` 为最近一次，`.pronotch.bak.1` 为上一次。
    /// 固定轮换而非时间戳——不依赖时钟，行为可预测，也不会在用户目录里越堆越多
    @discardableResult
    static func backup(_ path: String) -> Bool {
        let fm = FileManager.default
        guard let current = fm.contents(atPath: path) else { return false }
        let latest = path + ".pronotch.bak"
        let previous = latest + ".1"
        if let old = fm.contents(atPath: latest) {
            try? old.write(to: URL(fileURLWithPath: previous))
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous)
        }
        guard (try? current.write(to: URL(fileURLWithPath: latest))) != nil else { return false }
        // 备份里可能含用户的接口地址、token 等，只给本人读写
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: latest)
        return true
    }

    /// 原子写入文本。`validate` 返回 false 即整笔放弃，原文件不动。
    /// `defaultPermissions` 只在目标文件原本不存在时使用；已存在则沿用原权限
    @discardableResult
    static func write(_ contents: String, to path: String,
                      defaultPermissions: Int = 0o644,
                      validate: (String) -> Bool) -> Result<Void, WriteError> {
        guard validate(contents) else { return .failure(.validationFailed) }
        guard let data = contents.data(using: .utf8) else {
            return .failure(.ioFailed("内容无法编码为 UTF-8"))
        }
        return writeData(data, to: path, defaultPermissions: defaultPermissions)
    }

    /// 原子写入二进制（JSON 配置走这条）
    @discardableResult
    static func writeData(_ data: Data, to path: String,
                          defaultPermissions: Int = 0o644) -> Result<Void, WriteError> {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path)
        let directory = target.deletingLastPathComponent()
        // 临时文件必须和目标同目录：跨卷 rename 不是原子操作
        let temp = directory.appendingPathComponent(".pronotch-tmp-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp)
        } catch {
            try? fm.removeItem(at: temp)
            return .failure(.ioFailed(error.localizedDescription))
        }

        // 沿用原文件权限；新建时用默认值，且一律不给同组/其他人写
        let existing = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        let mode = (existing ?? defaultPermissions) & ~0o022
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)

        do {
            if fm.fileExists(atPath: path) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
            return .success(())
        } catch {
            try? fm.removeItem(at: temp)   // 失败不留垃圾，原文件字节不变
            return .failure(.ioFailed(error.localizedDescription))
        }
    }

    /// 把脚本先写到同目录临时文件，返回临时路径；配置替换成功后再 `commitScript` 落位。
    /// 顺序很重要：配置里引用的脚本路径一旦落位就可能被 Agent 调起，
    /// 配置还没写成功就先放脚本，等于留下一个谁也不认识的可执行文件
    static func stageScript(_ contents: String, finalPath: String) -> String? {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: finalPath)
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".pronotch-tmp-\(UUID().uuidString).sh")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try contents.write(to: temp, atomically: true, encoding: .utf8)
            // 可执行但不允许同组/其他人写，避免被替换成任意代码
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            return temp.path
        } catch {
            try? fm.removeItem(at: temp)
            return nil
        }
    }

    /// 把暂存脚本原子挪到最终位置
    @discardableResult
    static func commitScript(from staged: String, to finalPath: String) -> Bool {
        let fm = FileManager.default
        let temp = URL(fileURLWithPath: staged)
        let target = URL(fileURLWithPath: finalPath)
        do {
            if fm.fileExists(atPath: finalPath) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
                // replaceItemAt 会沿用被替换文件的权限，这里重新钉死可执行位
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalPath)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }

    /// 丢弃暂存脚本（配置写失败时调用）
    static func discardScript(_ staged: String?) {
        guard let staged else { return }
        try? FileManager.default.removeItem(atPath: staged)
    }
}
