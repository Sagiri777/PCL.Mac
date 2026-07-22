//
//  Support.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  工具函数：URL extension + 文件 hash（PCL.Mac.Core 没暴露，所以 inline 在 UI target 这边）。
//

import Foundation
import CryptoKit

public extension URL {
    func ensureParentDirectoryExists() throws {
        let parent = deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}

public enum FileHash {
    public enum Algorithm: String {
        case sha1, sha256, sha512
    }

    public static func verify(_ url: URL, expected: String, algorithm: Algorithm) throws {
        let data = try Data(contentsOf: url)
        let actual: String
        switch algorithm {
        case .sha1:
            actual = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha256:
            actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha512:
            actual = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw HashError.mismatch(expected: expected, actual: actual, file: url)
        }
    }

    /// 计算文件指定算法的十六进制哈希（小写）。供 ModpackExporter 生成 manifest 用。
    public static func compute(_ url: URL, algorithm: Algorithm) throws -> String {
        let data = try Data(contentsOf: url)
        switch algorithm {
        case .sha1:
            return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha256:
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha512:
            return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

public enum HashError: LocalizedError {
    case mismatch(expected: String, actual: String, file: URL)
    public var errorDescription: String? {
        switch self {
        case let .mismatch(expected, actual, file):
            return "Hash mismatch for \(file.lastPathComponent): expected \(expected), got \(actual)."
        }
    }
}
