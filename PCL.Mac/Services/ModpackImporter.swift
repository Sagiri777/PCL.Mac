//
//  ModpackImporter.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 ModModpack.vb 中 InstallPackModrinth / InstallPackCurseForge / InstallPackHMCL。
//

import Foundation
import ZIPFoundation
import SwiftyJSON

// MARK: - ModpackManifest (Modrinth .mrpack 格式)

public struct ModrinthModpack: Codable, Sendable {
    public let formatVersion: Int
    public let game: String
    public let versionId: String
    public let name: String
    public let summary: String?
    public let files: [ModrinthFile]
    public let dependencies: [String: String]

    enum CodingKeys: String, CodingKey {
        case formatVersion, game, versionId, name, summary, files, dependencies
    }

    public struct ModrinthFile: Codable, Sendable {
        public let path: String
        public let hashes: Hashes
        public let env: Env?
        public let downloads: [URL]
        public let fileSize: Int

        public struct Hashes: Codable, Sendable {
            public let sha1: String
            public let sha512: String?
        }
        public struct Env: Codable, Sendable {
            public let client: String?
            public let server: String?
        }
    }
}

public struct ModpackImportProgressUpdate: Sendable {
    public let packName: String
    public let status: String
    public let progress: Double
    public let finishedFiles: Int
    public let totalFiles: Int
}

public typealias ModpackImportProgressHandler = (ModpackImportProgressUpdate) -> Void

// MARK: - ModpackImporter

public enum ModpackImporter {
    public enum Format: Sendable {
        case modrinth       // .mrpack (zip 含 modrinth.index.json)
        case curseforge     // .zip 含 manifest.json (minecraft/modloader 字段)
        case hmcl           // .zip 含 manifest.json + override/
        case unknown
    }

    /// 探测 zip 类型。
    public static func detectFormat(of zipURL: URL) throws -> Format {
        let archive = try Archive(url: zipURL, accessMode: .read)
        let entries = Array(archive)
        if entries.contains(where: { $0.path == "modrinth.index.json" }) {
            return .modrinth
        }
        if entries.contains(where: { $0.path == "manifest.json" }) {
            // CurseForge vs HMCL：HMCL 一般有 override/ 目录
            if entries.contains(where: { $0.path.hasPrefix("override/") }) {
                return .hmcl
            }
            return .curseforge
        }
        return .unknown
    }

    /// 解析 .mrpack。
    public static func parseModrinth(_ zipURL: URL) throws -> ModrinthModpack {
        let archive = try Archive(url: zipURL, accessMode: .read)
        guard let entry = Array(archive).first(where: { $0.path == "modrinth.index.json" }) else {
            throw MyLocalizedError(reason: "找不到 modrinth.index.json")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return try JSONDecoder().decode(ModrinthModpack.self, from: data)
    }

    /// 解析 CurseForge manifest.json。
    public static func parseCurseForge(_ zipURL: URL) throws -> JSON {
        let archive = try Archive(url: zipURL, accessMode: .read)
        guard let entry = Array(archive).first(where: { $0.path == "manifest.json" }) else {
            throw MyLocalizedError(reason: "找不到 manifest.json")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return try JSON(data: data)
    }

    /// 解析 HMCL manifest.json。
    public static func parseHMCL(_ zipURL: URL) throws -> JSON {
        return try parseCurseForge(zipURL)
    }

    /// 通用安装入口：根据 zip 类型分发。
    @discardableResult
    public static func install(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        progress?(.init(
            packName: instanceName ?? zipURL.deletingPathExtension().lastPathComponent,
            status: "正在识别整合包",
            progress: 0,
            finishedFiles: 0,
            totalFiles: 0
        ))
        let format = try detectFormat(of: zipURL)
        switch format {
        case .modrinth:
            return try await installModrinth(zipURL: zipURL, into: minecraftDirectory, instanceName: instanceName, progress: progress)
        case .curseforge:
            return try await installCurseForge(zipURL: zipURL, into: minecraftDirectory, instanceName: instanceName, progress: progress)
        case .hmcl:
            return try await installHMCL(zipURL: zipURL, into: minecraftDirectory, instanceName: instanceName, progress: progress)
        case .unknown:
            throw MyLocalizedError(reason: "无法识别的整合包格式。期待 .mrpack / CurseForge / HMCL 其中之一。")
        }
    }

    // MARK: - Modrinth 安装

    public static func installModrinth(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let pack = try parseModrinth(zipURL)
        let name = instanceName ?? pack.name
        let versionDir = minecraftDirectory.versionsURL.appending(path: sanitizeDirName(name))
        // 实例内容直接放到 versionDir（即实例 runningDirectory），与 ModInstaller / InstanceModsView 读取的 runningDirectory/mods 一致；
        // 之前多套一层 ".minecraft"，导致 jar 落到 versions/<name>/.minecraft/mods，启动器和 mod 列表都看不到。
        let instanceDir = versionDir

        try FileManager.default.createDirectory(at: instanceDir.appending(path: "mods"), withIntermediateDirectories: true)

        // 1. 下载所有 file 到 instanceDir/<path>
        log("Modrinth 整合包安装：\(name)，共 \(pack.files.count) 个文件")
        progress?(.init(packName: name, status: "正在解决依赖", progress: 0.04, finishedFiles: 0, totalFiles: pack.files.count))
        let downloadBaseProgress = 0.08
        let downloadProgressWeight = 0.84
        for (index, file) in pack.files.enumerated() {
            let target = instanceDir.appending(path: file.path)
            try target.ensureParentDirectoryExists()
            guard let url = file.downloads.first else {
                log("跳过无下载源的文件：\(file.path)")
                progress?(.init(
                    packName: name,
                    status: "正在导入 \(file.path)",
                    progress: progressForFile(index + 1, 1, total: pack.files.count, base: downloadBaseProgress, weight: downloadProgressWeight),
                    finishedFiles: index + 1,
                    totalFiles: pack.files.count
                ))
                continue
            }
            log("下载 \(file.path) (\(file.fileSize) bytes)")
            progress?(.init(
                packName: name,
                status: "正在导入 \(file.path)",
                progress: progressForFile(index, 0, total: pack.files.count, base: downloadBaseProgress, weight: downloadProgressWeight),
                finishedFiles: index,
                totalFiles: pack.files.count
            ))
            try await SingleFileDownloader.download(url: url, destination: target, networkCategory: .gameDownload) { fileProgress in
                let normalizedProgress = fileProgress < 0 ? 0 : fileProgress
                progress?(.init(
                    packName: name,
                    status: "正在导入 \(file.path)",
                    progress: progressForFile(index, normalizedProgress, total: pack.files.count, base: downloadBaseProgress, weight: downloadProgressWeight),
                    finishedFiles: index,
                    totalFiles: pack.files.count
                ))
            }
            // 校验 SHA1
            if !file.hashes.sha1.isEmpty {
                do {
                    try FileHash.verify(target, expected: file.hashes.sha1, algorithm: .sha1)
                } catch {
                    err("SHA1 校验失败：\(file.path) — \(error.localizedDescription)")
                }
            }
        }

        // 2. 写出 overrides 目录（Modrinth 标准放在 overrides/ 子目录，必须传 sourceSubdir，
        //    否则 extractOverrides 的无 sub 分支会跳过所有含 "/" 的条目，config/资源包/光影一个都不解压）
        progress?(.init(packName: name, status: "正在解压覆盖文件", progress: 0.93, finishedFiles: pack.files.count, totalFiles: pack.files.count))
        try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "overrides")

        // 3. 构造版本 JSON
        progress?(.init(packName: name, status: "正在解决依赖", progress: 0.97, finishedFiles: pack.files.count, totalFiles: pack.files.count))
        let mcVersion = pack.dependencies["minecraft"] ?? ""
        let fabricLoader = pack.dependencies["fabric-loader"]
        let forgeLoader = pack.dependencies["forge"]
        let neoForgeLoader = pack.dependencies["neoforge"]
        let quiltLoader = pack.dependencies["quilt-loader"]

        let versionJSON = try buildInheritsVersionJSON(
            inheritsFrom: mcVersion,
            versionId: sanitizeDirName(name),
            loaders: [
                fabricLoader.map { "fabric-loader:\($0)" },
                forgeLoader.map { "forge:\($0)" },
                neoForgeLoader.map { "neoforge:\($0)" },
                quiltLoader.map { "quilt-loader:\($0)" }
            ].compactMap { $0 }
        )
        try versionJSON.write(to: versionDir.appending(path: "\(sanitizeDirName(name)).json"))

        log("Modrinth 整合包安装完成：\(name)")
        progress?(.init(packName: name, status: "导入完成", progress: 1, finishedFiles: pack.files.count, totalFiles: pack.files.count))
        return instanceDir
    }

    // MARK: - CurseForge 安装

    public static func installCurseForge(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let manifest = try parseCurseForge(zipURL)
        let mcVersion = manifest["minecraft"]["version"].stringValue
        let name = instanceName ?? manifest["name"].stringValue
        let versionDir = minecraftDirectory.versionsURL.appending(path: sanitizeDirName(name))
        let instanceDir = versionDir

        try FileManager.default.createDirectory(at: instanceDir.appending(path: "mods"), withIntermediateDirectories: true)

        // 1. 遍历 mods 数组，依次从 CurseForge 拉
        // 注：完整实现需要 CurseForge API Key；这里只拉直链
        let mods = manifest["files"].arrayValue
        log("CurseForge 整合包安装：\(name)，共 \(mods.count) 个 mod")
        progress?(.init(packName: name, status: "正在解决依赖", progress: 0.12, finishedFiles: 0, totalFiles: mods.count))
        for mod in mods {
            // CurseForge 文件 ID — 需要调用 CurseForge API 解析 projectID/fileID 为下载链接
            // 这里保留 hook，留待 Stage 2+ 集成完整
            log("CurseForge mod \(mod["projectID"]) / \(mod["fileID"]) 需要 CurseForge API 解析（占位）")
        }

        // 2. overrides（CurseForge 整合包的 overrides/ 子目录包含 config 等运行时文件，
        //    部分第三方/离线整合包还会把 mod 打进 overrides/mods；之前不传 sub 导致全部被跳过）
        progress?(.init(packName: name, status: "正在解压覆盖文件", progress: 0.70, finishedFiles: 0, totalFiles: mods.count))
        try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "overrides")

        // 3. JSON
        progress?(.init(packName: name, status: "正在写入实例配置", progress: 0.92, finishedFiles: 0, totalFiles: mods.count))
        let loaders: [String] = {
            var out: [String] = []
            for loader in manifest["minecraft"]["modLoaders"].arrayValue {
                if let id = loader["id"].string {
                    if id.hasPrefix("forge-") { out.append("forge:\(id.dropFirst("forge-".count))") }
                    else if id.hasPrefix("neoforge-") { out.append("neoforge:\(id.dropFirst("neoforge-".count))") }
                    else if id.hasPrefix("fabric-") { out.append("fabric-loader:\(id.dropFirst("fabric-".count))") }
                }
            }
            return out
        }()

        let versionJSON = try buildInheritsVersionJSON(
            inheritsFrom: mcVersion,
            versionId: sanitizeDirName(name),
            loaders: loaders
        )
        try versionJSON.write(to: versionDir.appending(path: "\(sanitizeDirName(name)).json"))
        log("CurseForge 整合包安装完成（部分）：\(name)")
        progress?(.init(packName: name, status: "导入完成", progress: 1, finishedFiles: mods.count, totalFiles: mods.count))
        return instanceDir
    }

    // MARK: - HMCL 安装

    public static func installHMCL(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let manifest = try parseHMCL(zipURL)
        let mcVersion = manifest["minecraft"]["version"].stringValue
        let name = instanceName ?? manifest["name"].stringValue
        let versionDir = minecraftDirectory.versionsURL.appending(path: sanitizeDirName(name))
        let instanceDir = versionDir

        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)

        // HMCL 把 override/ 直接当 .minecraft 内容展开
        progress?(.init(packName: name, status: "正在解压覆盖文件", progress: 0.35, finishedFiles: 0, totalFiles: 0))
        try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "override")

        // 加载器信息（HMCL 用 forge 版本号）
        progress?(.init(packName: name, status: "正在解决依赖", progress: 0.82, finishedFiles: 0, totalFiles: 0))
        let loaders: [String] = {
            var out: [String] = []
            if let forge = manifest["forge"].string { out.append("forge:\(forge)") }
            if let lite = manifest["liteloader"].string { out.append("com.mumfrey:liteloader:\(lite)") }
            if let fabric = manifest["fabricLoader"].string { out.append("fabric-loader:\(fabric)") }
            return out
        }()

        let versionJSON = try buildInheritsVersionJSON(
            inheritsFrom: mcVersion,
            versionId: sanitizeDirName(name),
            loaders: loaders
        )
        try versionJSON.write(to: versionDir.appending(path: "\(sanitizeDirName(name)).json"))
        log("HMCL 整合包安装完成：\(name)")
        progress?(.init(packName: name, status: "导入完成", progress: 1, finishedFiles: 0, totalFiles: 0))
        return instanceDir
    }

    // MARK: - Helpers

    /// 解压 zip 里的 overrides（顶层文件 + override/ 子目录）到目标目录。
    private static func extractOverrides(zipURL: URL, into instanceDir: URL, sourceSubdir: String? = nil) async throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        let sub = sourceSubdir
        for entry in Array(archive) {
            guard !entry.path.hasSuffix("/") else { continue } // skip dirs
            // 规范化：去掉 "./" 前缀，统一分隔符为 "/"，子目录前缀按小写匹配（兼容 overrides / Overrides 等）
            let raw = entry.path
            let normalized = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            let normalizedForCompare = normalized.lowercased().replacingOccurrences(of: "\\", with: "/")
            if let prefix = sub {
                guard normalizedForCompare.hasPrefix("\(prefix.lowercased())/") else { continue }
            } else {
                // 只挑不在子目录里的（顶层文件）；子目录条目（如 overrides/manifest.json）跳过
                if normalizedForCompare.contains("/") { continue }
            }
            let relativePath: String = {
                if let prefix = sub {
                    return String(normalized.dropFirst("\(prefix)/".count))
                } else {
                    return normalized
                }
            }()
            let target = instanceDir.appending(path: relativePath)
            try target.ensureParentDirectoryExists()
            _ = try archive.extract(entry) { chunk in
                if FileManager.default.fileExists(atPath: target.path) {
                    let handle = try FileHandle(forWritingTo: target)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: chunk)
                    try handle.close()
                } else {
                    try chunk.write(to: target)
                }
            }
        }
    }

    private static func buildInheritsVersionJSON(inheritsFrom: String, versionId: String, loaders: [String]) throws -> Data {
        var libraries: [[String: Any]] = []
        for loader in loaders {
            if loader.hasPrefix("fabric-loader:") {
                libraries.append([
                    "name": "net.fabricmc:fabric-loader:\(loader.dropFirst("fabric-loader:".count))"
                ])
            } else if loader.hasPrefix("forge:") {
                libraries.append([
                    "name": "net.minecraftforge:forge:\(loader.dropFirst("forge:".count))"
                ])
            } else if loader.hasPrefix("neoforge:") {
                libraries.append([
                    "name": "net.neoforged:neoforge:\(loader.dropFirst("neoforge:".count))"
                ])
            } else if loader.hasPrefix("quilt-loader:") {
                libraries.append([
                    "name": "org.quiltmc:quilt-loader:\(loader.dropFirst("quilt-loader:".count))"
                ])
            }
        }
        let json: [String: Any] = [
            "id": versionId,
            "inheritsFrom": inheritsFrom,
            "releaseTime": ISO8601DateFormatter().string(from: Date()),
            "time": ISO8601DateFormatter().string(from: Date()),
            "type": "release",
            "mainClass": "", // 由 inheritsFrom 决定
            "libraries": libraries
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    }

    private static func progressForFile(_ index: Int, _ fileProgress: Double, total: Int, base: Double, weight: Double) -> Double {
        guard total > 0 else { return base + weight }
        let safeFileProgress = min(max(fileProgress, 0), 1)
        let progress = (Double(index) + safeFileProgress) / Double(total)
        return min(max(base + progress * weight, 0), 1)
    }

    private static func sanitizeDirName(_ s: String) -> String {
        // 只过滤文件系统非法/不安全字符（macOS: ':' '/'；以及控制字符），保留中日韩等 Unicode 字符。
        // 之前只允许 ASCII 字母数字，会把"拔刀之旅"这类名字塌缩成 "modpack"，导致实例名丢失且多次导入会撞名覆盖。
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var out = ""
        var lastDash = false
        for ch in s.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if illegal.contains(ch) || ch == "\0" {
                if !lastDash { out.append("-"); lastDash = true }
            } else {
                out.unicodeScalars.append(ch)
                lastDash = (ch == "-")
            }
        }
        let cleaned = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "modpack" : cleaned
    }
}
