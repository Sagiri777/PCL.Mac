//
//  Util.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/18.
//

import Foundation
import AppKit
import ZIPFoundation
import CryptoKit

public class Util {
    public static func getMainClass(_ jarURL: URL) -> String? {
        do {
            let archive = try Archive(url: jarURL, accessMode: .read)
            let data = try ArchiveUtil.getEntryOrThrow(archive: archive, name: "META-INF/MANIFEST.MF")
            let manifest = String(data: data, encoding: .utf8)!

            if let match = manifest.firstMatch(of: /(?m)^Main-Class:\s*([^\r\n]+)/) {
                return String(match.1)
            }
        } catch {
            err("无法获取主类: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    public static func formatJSON(_ jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            let prettyData = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted]
            )
            return String(data: prettyData, encoding: .utf8)
        } catch {
            err("JSON格式化失败: \(error.localizedDescription)")
            return nil
        }
    }
    
    public static func parse(mavenCoordinate: String) -> MavenCoordinate {
        let pattern = #"^([^:]+):([^:]+):([^:@]+)(?::([^@]+))?(?:@(.+))?$"#
        let r = mavenCoordinate.range(of: pattern, options: .regularExpression)!
        let match = String(mavenCoordinate[r])
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsrange = NSRange(match.startIndex..<match.endIndex, in: match)
        let result = regex.firstMatch(in: match, options: [], range: nsrange)!
        func group(_ i: Int) -> String? {
            guard let range = Range(result.range(at: i), in: match) else { return nil }
            return String(match[range])
        }
        return MavenCoordinate(
            group(1)!,
            group(2)!,
            group(3)!,
            classifier: group(4),
            packaging: group(5)
        )
    }
    
    public static func toPath(mavenCoordinate: String) -> String {
        let coord = parse(mavenCoordinate: mavenCoordinate)
        return "\(coord.groupId.replacingOccurrences(of: ".", with: "/"))/\(coord.artifactId)/\(coord.version)/\(coord.artifactId)-\(coord.version)"
        + (coord.classifier != nil ? "-" + coord.classifier! : "")
        + "." + (coord.packaging != nil ? coord.packaging! : "jar")
    }
    
    public static func replaceTemplateStrings(_ strings: [String], with dict: [String: String]) -> [String] {
        return strings.map { original in
            var result = original
            for (key, value) in dict {
                result = result
                    .replacingOccurrences(of: "${\(key)}", with: value)
                    .replacingOccurrences(of: "{\(key)}", with: value)
            }
            return result
        }
    }
    
    public static func clearTemp() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: SharedConstants.shared.temperatureURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            for itemURL in contents {
                try FileManager.default.removeItem(at: itemURL)
            }
        } catch {
            err("在清理时发生错误: \(error.localizedDescription)")
        }
    }
    
    public static func unzip(archiveURL: URL, destination: URL, replace: Bool = true) {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            err("无法读取文件: \(error.localizedDescription)")
            return
        }
        
        for entry in archive {
            do {
                let destinationFileURL = destination.appendingPathComponent(entry.path)
                if FileManager.default.fileExists(atPath: destinationFileURL.path) && replace {
                    try FileManager.default.removeItem(at: destinationFileURL)
                    debug("已删除重复文件 \(destinationFileURL.lastPathComponent)")
                }
                _ = try archive.extract(entry, to: destinationFileURL)
            } catch {
                err("无法解压文件: \(error.localizedDescription)")
            }
        }
    }
    
    public static func sha1OfFile(url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        var hasher = Insecure.SHA1()
        while true {
            let data = try fileHandle.read(upToCount: 1024 * 1024)
            if let data = data, !data.isEmpty {
                hasher.update(data: data)
            } else {
                break
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func getFileName(url: URL) -> String? {
        var urlString = url.absoluteString
        if urlString.hasSuffix("/") { return nil }
        
        if let qIndex = urlString.firstIndex(of: "?") {
            urlString = String(urlString[..<qIndex])
        }
        
        if let lastBackslash = urlString.lastIndex(of: "/") {
            let fileNameStart = urlString.index(after: lastBackslash)
            urlString = String(urlString[fileNameStart...])
        }
        return urlString
    }
    
    public static func replaceRoot(url: any URLConvertible, root: String, target: String) -> any URLConvertible {
        return URL(string: url.url.absoluteString.replacingOccurrences(of: root, with: target))!
    }

    /// 在 Finder 中打开（或定位到）给定的 URL，处理几种边界情况：
    ///
    /// - **路径不存在**：如果 `createIfMissing = true`，按目录尝试创建；否则退到其父目录。
    ///   创建失败仍然退到父目录，避免 UI 上“什么都没发生”。
    /// - **目标是文件**：仍交给 Finder 打开目录（macOS 会回退到默认 app），并把父目录尽量曝露。
    /// - **NSWorkspace 失败**：兜底用 `activateFileViewerSelecting`，至少让 Finder 弹出对应窗口。
    ///
    /// 早期版本直接 `NSWorkspace.shared.open(instance.runningDirectory.appending(path: "mods"))`，
    /// 在 mods/ 还没建好（例如第一次点 mod 标签页还没下过 mod）时，`open` 对
    /// 不存在的目录会静默返回 false，表现为“按钮点了没反应”。
    ///
    /// 完成后会 `err(...)` 记录最后一次失败原因，便于回看 log。
    public static func openInFinder(_ url: URL, createIfMissing: Bool = false) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        var exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        var target = url

        if !exists {
            if createIfMissing {
                do {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    exists = true
                    isDirectory = true
                } catch {
                    err("openInFinder: 创建目录失败 \(url.path): \(error.localizedDescription)")
                    target = url.deletingLastPathComponent()
                    exists = fm.fileExists(atPath: target.path, isDirectory: &isDirectory)
                }
            } else {
                target = url.deletingLastPathComponent()
                exists = fm.fileExists(atPath: target.path, isDirectory: &isDirectory)
            }
        } else if !isDirectory.boolValue {
            // 目标是文件：让 Finder 打开父目录再选中它。
            target = url.deletingLastPathComponent()
        }

        guard exists else {
            err("openInFinder: 路径不存在且无法回退: \(url.path)")
            return
        }

        let opened = NSWorkspace.shared.open(target)
        if !opened {
            // 兜底：让 Finder 至少显示这个路径对应的窗口（如果路径存在但 open 失败，例如权限问题）。
            NSWorkspace.shared.activateFileViewerSelecting([target])
            err("openInFinder: NSWorkspace.open 失败，回退到 activateFileViewerSelecting: \(target.path)")
        }
    }
}

public struct MavenCoordinate {
    public let groupId: String
    public let artifactId: String
    public let version: String
    public let classifier: String?
    public let packaging: String?
    
    init(_ groupId: String, _ artifactId: String, _ version: String, classifier: String? = nil, packaging: String? = nil) {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.classifier = classifier
        self.packaging = packaging
    }
}
