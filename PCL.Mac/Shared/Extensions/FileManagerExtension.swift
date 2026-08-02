//
//  FileManagerExtension.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/19.
//

import Foundation

extension FileManager {
    static let logURL = SharedConstants.shared.logURL

    /// 追加日志。
    ///
    /// 旧实现每行都做 `fileExists` + 打开 FileHandle + seekToEnd + 关闭。Minecraft
    /// 启动时瞬间产生数千行日志，那就是几千次 open/close 系统调用。现在复用一个
    /// 常驻句柄，只在句柄失效（日志被外部删除或轮转）时重开。
    static func writeLog(_ content: String) throws {
        try LogWriter.shared.write(content)
    }

    /// 关闭常驻日志句柄。进程退出前调用，确保数据落盘。
    static func closeLogHandle() {
        LogWriter.shared.close()
    }
}

/// 持有 app.log 的常驻写句柄。`LogStore` 已把写入串行化到自己的队列上，
/// 这里仍加锁以防未来出现其他调用方。
private final class LogWriter {
    static let shared = LogWriter()

    private let lock = NSLock()
    private var handle: FileHandle?

    private init() {}

    func write(_ content: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = Data(content.utf8)
        if let handle {
            do {
                try handle.write(contentsOf: data)
                return
            } catch {
                try? handle.close()
                self.handle = nil
            }
        }

        let handle = try openHandle()
        self.handle = handle
        try handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    private func openHandle() throws -> FileHandle {
        let fileManager = FileManager.default
        let logURL = FileManager.logURL
        if !fileManager.fileExists(atPath: logURL.path) {
            try fileManager.createDirectory(
                at: logURL.parent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }
}
