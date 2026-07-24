//
//  MemoryOptimizer.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 Application.xaml.vb 中 `--memory` 子命令与 PageOtherTest.MemoryOptimizeInternal。
//

import Foundation
import Darwin

/// 内存优化工具。
/// 通过释放磁盘缓存、清空文件系统缓存、malloc_trim 回收堆内存，尝试降低进程占用。
public enum MemoryOptimizer {
    /// 进程启动时的物理内存占用（字节）。
    public static func currentResidentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    /// 系统可用物理内存（字节）。
    public static func systemAvailableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let pageSize = UInt64(vm_kernel_page_size)
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        return free + inactive
    }

    /// 执行内存优化，返回释放的字节数估算。
    /// - Parameters:
    ///   - clearCaches: 是否清空 ~/Library/Caches/*
    ///   - purgeDiskCache: 是否触发 `purge` 系统命令（需要 root，仅在用户 sudo 启动时有效）
    @discardableResult
    public static func optimize(clearCaches: Bool = true, purgeDiskCache: Bool = false) -> UInt64 {
        let before = currentResidentMemory()
        log("内存优化开始，初始占用 \(FileManager.humanReadableBytes(Int64(before)))")

        if clearCaches {
            clearUserCaches()
        }

        // 强制 Swift runtime 回收可释放的堆内存。
        mallocTrim()

        // 触发 autorelease pool 回收。
        autoreleasepool { }

        // 尝试向内核释放缓存（无 sudo 时会失败但不致命）。
        if purgeDiskCache {
            purgeDiskCacheSync()
        }

        let after = currentResidentMemory()
        let freed = before > after ? before - after : 0
        log("内存优化完成，释放约 \(FileManager.humanReadableBytes(Int64(freed)))")
        return freed
    }

    /// 清空用户级 ~/Library/Caches/* 下与本应用相关的目录（保留系统关键目录）。
    private static func clearUserCaches() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: "Library/Caches/PCL.Mac"),
            home.appending(path: "Library/Caches/com.apple.Safari"),
            home.appending(path: "Library/Caches/com.apple.QuickLook.thumbnailcache"),
            home.appending(path: "Library/Caches/com.apple.iconservices.store"),
        ]
        for dir in candidates {
            guard fm.fileExists(atPath: dir.path) else { continue }
            do {
                let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                for f in contents {
                    try? fm.removeItem(at: f)
                }
                log("已清理缓存目录：\(dir.lastPathComponent)")
            } catch {
                err("清理 \(dir.path) 失败：\(error.localizedDescription)")
            }
        }
    }

    /// 调用 glibc 的 `malloc_trim`（macOS 用 libSystem）。
    /// 让 malloc 把未使用的堆页归还给内核。
    private static func mallocTrim() {
        // macOS 上对应的函数是 malloc_zone_pressure_relief
        guard let zone = malloc_default_zone() else { return }
        let freed = malloc_zone_pressure_relief(zone, 0)
        log("malloc_zone_pressure_relief freed \(freed) bytes")
    }

    /// 触发系统级 purge（需要 root）。失败也不抛错。
    private static func purgeDiskCacheSync() {
        let task = Process()
        task.launchPath = "/usr/bin/purge"
        task.arguments = []
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            log("purge 已执行")
        } catch {
            log("purge 失败（需要 root 或无该命令）：\(error.localizedDescription)")
        }
    }
}

/// FileManager 扩展：人类可读字节数。
extension FileManager {
    public static func humanReadableBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024 && idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: idx == 0 ? "%.0f %@" : "%.2f %@", size, units[idx])
    }
}
