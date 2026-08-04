//
//  Architecture.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 8/11/25.
//

import Foundation

public enum Architecture {
    public static var system: Architecture {
        get {
            systemArchLock.lock()
            defer { systemArchLock.unlock() }
            if _systemArch == nil {
                var systemInfo = utsname()
                uname(&systemInfo)
                let machineMirror = Mirror(reflecting: systemInfo.machine)
                let identifier = machineMirror.children.reduce("") { identifier, element in
                    guard let value = element.value as? Int8, value != 0 else { return identifier }
                    return identifier + String(UnicodeScalar(UInt8(value)))
                }
                _systemArch = switch identifier {
                case "arm64": .arm64
                case "x86_64": .x64
                default: .unknown
                }
            }
            return _systemArch ?? .unknown
        }
    }
    
    /// 读取文件架构（带缓存）。
    ///
    /// 这个方法在 Java 搜索、启动前检查、启动时映射 artifact，以及 natives 目录里
    /// 每个 dylib 上都会被调用，原本每次都要开 FileHandle 读 Mach-O 头。
    /// 缓存键包含修改时间与大小，文件被替换后自动失效。
    public static func getArchOfFile(_ executableURL: URL) -> Architecture {
        archCache.value(for: executableURL) { readArchOfFile(executableURL) }
    }

    private static func readArchOfFile(_ executableURL: URL) -> Architecture {
        guard let fh = try? FileHandle(forReadingFrom: executableURL) else { return .unknown }
        defer { try? fh.close() }
        
        guard let magicData = try? fh.read(upToCount: 4), magicData.count == 4 else { return .unknown }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let isFat = (magic == 0xBEBAFECA || magic == 0xBFBAFECA || magic == 0xCAFEBABE || magic == 0xCAFEBABF)
        
        if isFat {
            guard let nfatArchData = try? fh.read(upToCount: 4), nfatArchData.count == 4 else { return .unknown }
            let nfatArch = nfatArchData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            var foundX64 = false
            var foundArm64 = false
            
            for _ in 0..<nfatArch {
                guard let archData = try? fh.read(upToCount: 20), archData.count == 20 else { return .unknown }
                let cputype = archData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                switch cputype {
                case 0x1000007: foundX64 = true // CPU_TYPE_X86_64
                case 0x100000C: foundArm64 = true // CPU_TYPE_ARM64
                default: break
                }
            }
            if foundX64 && foundArm64 {
                return .fatFile
            } else if foundArm64 {
                return .arm64
            } else if foundX64 {
                return .x64
            } else {
                return .unknown
            }
        }
        
        guard let cputypeData = try? fh.read(upToCount: 4), cputypeData.count == 4 else { return .unknown }
        let cputype = cputypeData.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch cputype {
        case 0x100000C: return .arm64
        case 0x1000007: return .x64
        default: return .unknown
        }
    }
    
    private static var _systemArch: Architecture? = nil
    private static let systemArchLock = NSLock()
    private static let archCache = ArchCache()

    /// 线程安全的 (路径, mtime, size) → 架构缓存。
    private final class ArchCache {
        private struct Key: Hashable {
            let path: String
            let modified: TimeInterval
            let size: Int
        }

        private let lock = NSLock()
        private var storage: [Key: Architecture] = [:]

        private func key(for url: URL) -> Key? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            return Key(
                path: url.path,
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: values.fileSize ?? 0
            )
        }

        func value(for url: URL, compute: () -> Architecture) -> Architecture {
            guard let key = key(for: url) else { return compute() }

            lock.lock()
            let cached = storage[key]
            lock.unlock()
            if let cached { return cached }

            let computed = compute()

            lock.lock()
            // 上限保护：natives 目录可能有上百个 dylib，不让缓存无限增长。
            if storage.count > 512 { storage.removeAll(keepingCapacity: true) }
            storage[key] = computed
            lock.unlock()
            return computed
        }
    }

    /// ARM64，Apple Silicon
    case arm64
    
    /// x86_64，Intel Chip
    case x64
    
    /// Universal Binary，至少包含 ARM64 与 x86_64
    case fatFile
    
    /// 未知
    case unknown
    
    /// 是否与某个架构兼容。
    /// - Parameter arch: 目标架构，不可为 fatFile
    public func isCompatiable(with arch: Architecture) -> Bool {
        return self == arch || self == .fatFile
    }
    
    /// 是否与系统架构兼容。
    public func isCompatiableWithSystem() -> Bool {
        return isCompatiable(with: .system)
    }
    
    public static func fromString(_ string: String) -> Architecture {
        switch string {
        case "aarch64", "arm64", "arm": .arm64
        case "x86", "x64", "x86_64", "amd64": .x64
        default: .unknown
        }
    }
}
