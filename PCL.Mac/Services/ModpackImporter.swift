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

public enum ModpackImportStage: Int, CaseIterable, Identifiable, Sendable {
    case detecting
    case runtime
    case files
    case overrides
    case validation

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .detecting: "识别整合包"
        case .runtime: "安装游戏环境"
        case .files: "下载整合包内容"
        case .overrides: "应用配置与存档"
        case .validation: "校验启动环境"
        }
    }

    public var systemImage: String {
        switch self {
        case .detecting: "doc.zipper"
        case .runtime: "shippingbox"
        case .files: "arrow.down.circle"
        case .overrides: "slider.horizontal.3"
        case .validation: "play.circle"
        }
    }
}

public struct ModpackImportProgressUpdate: Sendable {
    public let packName: String
    public let status: String
    public let stage: ModpackImportStage
    public let stageProgress: Double
    public let progress: Double
    public let finishedFiles: Int
    public let totalFiles: Int

    public init(
        packName: String,
        status: String,
        stage: ModpackImportStage = .detecting,
        stageProgress: Double? = nil,
        progress: Double,
        finishedFiles: Int,
        totalFiles: Int
    ) {
        self.packName = packName
        self.status = status
        self.stage = stage
        self.stageProgress = min(max(stageProgress ?? progress, 0), 1)
        self.progress = min(max(progress, 0), 1)
        self.finishedFiles = finishedFiles
        self.totalFiles = totalFiles
    }
}

public typealias ModpackImportProgressHandler = (ModpackImportProgressUpdate) -> Void

// MARK: - ModpackImporter

public enum ModpackImporter {
    public enum Format: Sendable, Equatable {
        case modrinth       // .mrpack (zip 含 modrinth.index.json)
        case curseforge     // .zip 含 manifest.json (minecraft/modloader 字段)
        case hmcl           // .zip 含 manifest.json + override/
        case simple         // 压缩包内直接包含 .minecraft/versions/<实例名>
        case unknown
    }

    /// 探测 zip 类型。
    public static func detectFormat(of zipURL: URL) throws -> Format {
        let zipURL = try resolveNestedModpackURL(zipURL)
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
        if findSimpleInstancePrefix(in: entries) != nil {
            return .simple
        }
        return .unknown
    }

    /// 解析 .mrpack。
    public static func parseModrinth(_ zipURL: URL) throws -> ModrinthModpack {
        let zipURL = try resolveNestedModpackURL(zipURL)
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
        let zipURL = try resolveNestedModpackURL(zipURL)
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
            stage: .detecting,
            stageProgress: 0.2,
            progress: 0,
            finishedFiles: 0,
            totalFiles: 0
        ))
        let zipURL = try resolveNestedModpackURL(zipURL)
        let format = try detectFormat(of: zipURL)
        progress?(.init(
            packName: instanceName ?? zipURL.deletingPathExtension().lastPathComponent,
            status: "已识别整合包格式",
            stage: .detecting,
            stageProgress: 1,
            progress: 0.01,
            finishedFiles: 0,
            totalFiles: 0
        ))
        switch format {
        case .modrinth:
            return try await installModrinth(zipURL: zipURL, into: minecraftDirectory, instanceName: instanceName, progress: progress)
        case .curseforge:
            return try await installCurseForge(zipURL: zipURL, into: minecraftDirectory, instanceName: instanceName, progress: progress)
        case .hmcl:
            return try await installHMCL(zipURL: zipURL, into: minecraftDirectory, instanceName: instanceName, progress: progress)
        case .simple:
            return try await installSimple(zipURL: zipURL, into: minecraftDirectory, instanceName: instanceName, progress: progress)
        case .unknown:
            throw MyLocalizedError(reason: "无法识别的整合包格式。期待 .mrpack / CurseForge / HMCL / .minecraft 压缩包其中之一。")
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
        let instanceId = uniqueInstanceDirectoryName(sanitizeDirName(name), in: minecraftDirectory)
        let versionDir = minecraftDirectory.versionsURL.appending(path: instanceId)
        // 实例内容直接放到 versionDir（即实例 runningDirectory），与 ModInstaller / InstanceModsView 读取的 runningDirectory/mods 一致；
        // 之前多套一层 ".minecraft"，导致 jar 落到 versions/<name>/.minecraft/mods，启动器和 mod 列表都看不到。
        let instanceDir = versionDir

        var installCompleted = false
        defer {
            if !installCompleted {
                cleanupIncompleteInstance(at: versionDir)
            }
        }

        let requirement = try runtimeRequirement(
            minecraftVersion: pack.dependencies["minecraft"],
            loaders: [
                (.fabric, pack.dependencies["fabric-loader"]),
                (.forge, pack.dependencies["forge"]),
                (.neoforge, pack.dependencies["neoforge"]),
                (.quilt, pack.dependencies["quilt-loader"])
            ]
        )
        progress?(.init(packName: name, status: "正在安装 Minecraft \(requirement.minecraftVersion)", stage: .runtime, stageProgress: 0.05, progress: 0.02, finishedFiles: 0, totalFiles: pack.files.count))
        try await installRuntime(requirement, name: instanceId, packName: name, totalFiles: pack.files.count, into: minecraftDirectory, progress: progress)
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: instanceDir.appending(path: "mods"), withIntermediateDirectories: true)

        // 1. 下载所有 file 到 instanceDir/<path>
        let files = pack.files.filter { $0.env?.client != "unsupported" }
        log("Modrinth 整合包安装：\(name)，共 \(files.count) 个文件")
        progress?(.init(packName: name, status: "正在解决依赖", stage: .files, stageProgress: 0.02, progress: 0.12, finishedFiles: 0, totalFiles: files.count))
        let downloadBaseProgress = 0.12
        let downloadProgressWeight = 0.76

        let downloadItems: [DownloadItem] = try files.map { file in
            guard let url = file.downloads.first else {
                throw MyLocalizedError(reason: "整合包文件 \(file.path) 没有可用下载源。")
            }
            return DownloadItem(url, try safeDestination(relativePath: file.path, under: instanceDir), sha1: file.hashes.sha1)
        }
        let downloader = MultiFileDownloader(items: downloadItems, replaceMethod: .skip, networkCategory: .gameDownload) { fileProgress, finished in
            let progressValue = downloadBaseProgress + fileProgress * downloadProgressWeight
            progress?(.init(
                packName: name,
                status: "正在导入整合包文件",
                stage: .files,
                stageProgress: fileProgress,
                progress: progressValue,
                finishedFiles: finished,
                totalFiles: files.count
            ))
        }
        try await downloader.start()

        // 2. 写出 overrides 目录（Modrinth 标准放在 overrides/ 子目录，必须传 sourceSubdir，
        //    否则 extractOverrides 的无 sub 分支会跳过所有含 "/" 的条目，config/资源包/光影一个都不解压）
        progress?(.init(packName: name, status: "正在解压覆盖文件", stage: .overrides, stageProgress: 0.1, progress: 0.90, finishedFiles: files.count, totalFiles: files.count))
        try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "overrides")
        try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "client-overrides")

        progress?(.init(packName: name, status: "正在校验实例", stage: .validation, stageProgress: 0.35, progress: 0.97, finishedFiles: pack.files.count, totalFiles: pack.files.count))
        try validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)

        log("Modrinth 整合包安装完成：\(name)")
        installCompleted = true
        progress?(.init(packName: name, status: "导入完成", stage: .validation, stageProgress: 1, progress: 1, finishedFiles: files.count, totalFiles: files.count))
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
        let mcVersion = minecraftVersion(from: manifest)
        let name = instanceName ?? manifest["name"].stringValue
        let instanceId = uniqueInstanceDirectoryName(sanitizeDirName(name), in: minecraftDirectory)
        let versionDir = minecraftDirectory.versionsURL.appending(path: instanceId)
        let instanceDir = versionDir

        var installCompleted = false
        defer {
            if !installCompleted {
                cleanupIncompleteInstance(at: versionDir)
            }
        }

        let loaderEntries = manifest["minecraft"]["modLoaders"].arrayValue
        let preferredLoaderEntries = loaderEntries.filter { $0["primary"].boolValue }
        let declaredLoaders: [(ClientBrand, String?)] = (preferredLoaderEntries.isEmpty ? loaderEntries : preferredLoaderEntries).compactMap { loader in
            guard let id = loader["id"].string else { return nil }
            return parseCurseForgeLoader(id)
        }
        let requirement = try runtimeRequirement(
            minecraftVersion: mcVersion,
            loaders: declaredLoaders
        )
        progress?(.init(packName: name, status: "正在安装 Minecraft \(requirement.minecraftVersion)", stage: .runtime, stageProgress: 0.05, progress: 0.02, finishedFiles: 0, totalFiles: manifest["files"].arrayValue.count))
        try await installRuntime(requirement, name: instanceId, packName: name, totalFiles: manifest["files"].arrayValue.count, into: minecraftDirectory, progress: progress)
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: instanceDir.appending(path: "mods"), withIntermediateDirectories: true)

        // 1. CurseForge 标准清单只提供 projectID/fileID。官方无 Key
        // 下载端点会重定向到实际文件，因此可以完整解决依赖；禁用第三方下载
        // 的作者文件会明确失败，而不是静默生成一个缺 Mod 的实例。
        let mods = manifest["files"].arrayValue
        log("CurseForge 整合包安装：\(name)，共 \(mods.count) 个 mod")
        progress?(.init(packName: name, status: "正在解决并下载整合包依赖", stage: .files, stageProgress: 0.02, progress: 0.12, finishedFiles: 0, totalFiles: mods.count))
        let downloadItems = try mods.map { mod -> DownloadItem in
            let projectID = try mod["projectID"].int.unwrap("CurseForge 清单缺少 projectID。")
            let fileID = try mod["fileID"].int.unwrap("CurseForge 清单缺少 fileID。")
            let suppliedURL = mod["url"].url
            let downloadURL = suppliedURL ?? URL(string: "https://www.curseforge.com/api/v1/mods/\(projectID)/files/\(fileID)/download")!
            let suppliedName = mod["fileName"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = (suppliedName?.isEmpty == false ? suppliedName! : "curseforge-\(projectID)-\(fileID).jar")
            let destination = try safeDestination(relativePath: "mods/\(fileName)", under: instanceDir)
            return DownloadItem(downloadURL, destination)
        }
        try await MultiFileDownloader(items: downloadItems, replaceMethod: .skip, networkCategory: .gameDownload) { fileProgress, finished in
            progress?(.init(
                packName: name,
                status: "正在下载 CurseForge 依赖",
                stage: .files,
                stageProgress: fileProgress,
                progress: 0.12 + fileProgress * 0.68,
                finishedFiles: finished,
                totalFiles: mods.count
            ))
        }.start()

        // 2. overrides（CurseForge 整合包的 overrides/ 子目录包含 config 等运行时文件，
        //    部分第三方/离线整合包还会把 mod 打进 overrides/mods；之前不传 sub 导致全部被跳过）
        let overridesDirectory = manifest["overrides"].stringValue.isEmpty ? "overrides" : manifest["overrides"].stringValue
        progress?(.init(packName: name, status: "正在解压覆盖文件", stage: .overrides, stageProgress: 0.15, progress: 0.84, finishedFiles: mods.count, totalFiles: mods.count))
        try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: overridesDirectory)

        progress?(.init(packName: name, status: "正在校验实例", stage: .validation, stageProgress: 0.35, progress: 0.97, finishedFiles: mods.count, totalFiles: mods.count))
        try validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)
        log("CurseForge 整合包安装完成：\(name)")
        installCompleted = true
        progress?(.init(packName: name, status: "导入完成", stage: .validation, stageProgress: 1, progress: 1, finishedFiles: mods.count, totalFiles: mods.count))
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
        let mcVersion = minecraftVersion(from: manifest)
        let name = instanceName ?? manifest["name"].stringValue
        let instanceId = uniqueInstanceDirectoryName(sanitizeDirName(name), in: minecraftDirectory)
        let versionDir = minecraftDirectory.versionsURL.appending(path: instanceId)
        let instanceDir = versionDir

        var installCompleted = false
        defer {
            if !installCompleted {
                cleanupIncompleteInstance(at: versionDir)
            }
        }

        let requirement = try runtimeRequirement(
            minecraftVersion: mcVersion,
            loaders: [
                (.forge, manifest["forge"].string),
                (.fabric, manifest["fabricLoader"].string),
                (.quilt, manifest["quiltLoader"].string),
                (.liteLoader, manifest["liteloader"].string)
            ]
        )
        progress?(.init(packName: name, status: "正在安装 Minecraft \(requirement.minecraftVersion)", stage: .runtime, stageProgress: 0.05, progress: 0.02, finishedFiles: 0, totalFiles: 0))
        try await installRuntime(requirement, name: instanceId, packName: name, totalFiles: 0, into: minecraftDirectory, progress: progress)
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)

        // HMCL 把 override/ 直接当 .minecraft 内容展开
        progress?(.init(packName: name, status: "正在解压覆盖文件", stage: .overrides, stageProgress: 0.15, progress: 0.84, finishedFiles: 0, totalFiles: 0))
        try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "override")

        progress?(.init(packName: name, status: "正在校验实例", stage: .validation, stageProgress: 0.35, progress: 0.96, finishedFiles: 0, totalFiles: 0))
        try validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)
        log("HMCL 整合包安装完成：\(name)")
        installCompleted = true
        progress?(.init(packName: name, status: "导入完成", stage: .validation, stageProgress: 1, progress: 1, finishedFiles: 0, totalFiles: 0))
        return instanceDir
    }

    // MARK: - 简单压缩包安装

    public static func installSimple(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let archive = try Archive(url: zipURL, accessMode: .read)
        let entries = Array(archive)
        guard let found = findSimpleInstancePrefix(in: entries) else {
            throw MyLocalizedError(reason: "找不到 .minecraft/versions 下的实例目录。")
        }

        let name = instanceName ?? found.name
        let instanceId = uniqueInstanceDirectoryName(sanitizeDirName(name), in: minecraftDirectory)
        let versionDir = minecraftDirectory.versionsURL.appending(path: instanceId)
        var installCompleted = false
        defer {
            if !installCompleted {
                cleanupIncompleteInstance(at: versionDir)
            }
        }
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let files = entries.filter { !$0.path.hasSuffix("/") && normalizedArchivePath($0.path).hasPrefix(found.prefix) }
        progress?(.init(packName: name, status: "正在拷贝整合包文件", stage: .files, stageProgress: 0.02, progress: 0.12, finishedFiles: 0, totalFiles: files.count))

        for (index, entry) in files.enumerated() {
            let normalized = normalizedArchivePath(entry.path)
            let relative = String(normalized.dropFirst(found.prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let target = try safeDestination(relativePath: relative, under: versionDir)
            try target.ensureParentDirectoryExists()
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            _ = try archive.extract(entry, to: target)
            progress?(.init(
                packName: name,
                status: "正在拷贝 \(relative)",
                stage: .files,
                stageProgress: progressForFile(index, 1, total: files.count, base: 0, weight: 1),
                progress: progressForFile(index, 1, total: files.count, base: 0.1, weight: 0.85),
                finishedFiles: index + 1,
                totalFiles: files.count
            ))
        }

        try renameSimpleVersionFilesIfNeeded(in: versionDir, from: found.name, to: instanceId)
        progress?(.init(packName: name, status: "正在补全游戏依赖", stage: .validation, stageProgress: 0.2, progress: 0.96, finishedFiles: files.count, totalFiles: files.count))
        let instance = try validateInstance(at: versionDir, in: minecraftDirectory, requirement: nil)
        try await MinecraftInstaller.complete(instance) { value, status in
            progress?(.init(
                packName: name,
                status: status,
                stage: .validation,
                stageProgress: 0.2 + value * 0.75,
                progress: 0.96 + value * 0.03,
                finishedFiles: files.count,
                totalFiles: files.count
            ))
        }
        try validateInstance(at: versionDir, in: minecraftDirectory, requirement: nil)
        installCompleted = true
        progress?(.init(packName: name, status: "导入完成", stage: .validation, stageProgress: 1, progress: 1, finishedFiles: files.count, totalFiles: files.count))
        return versionDir
    }

    // MARK: - Helpers

    /// 解压 zip 里的 overrides（顶层文件 + override/ 子目录）到目标目录。
    private static func extractOverrides(zipURL: URL, into instanceDir: URL, sourceSubdir: String? = nil) async throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        let sub = sourceSubdir
        for entry in Array(archive) {
            try Task.checkCancellation()
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
            let target = try safeDestination(relativePath: relativePath, under: instanceDir)
            try target.ensureParentDirectoryExists()
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            _ = try archive.extract(entry, to: target)
        }
    }

    private struct RuntimeRequirement {
        let minecraftVersion: String
        let loader: ClientBrand?
        let loaderVersion: String?
    }

    private static func runtimeRequirement(
        minecraftVersion: String?,
        loaders: [(ClientBrand, String?)]
    ) throws -> RuntimeRequirement {
        let version = minecraftVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else {
            throw MyLocalizedError(reason: "整合包没有声明 Minecraft 游戏版本。")
        }

        let declared = loaders.compactMap { brand, version -> (ClientBrand, String)? in
            guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
            return (brand, version)
        }
        guard declared.count <= 1 else {
            let names = declared.map { $0.0.getName() }.joined(separator: "、")
            throw MyLocalizedError(reason: "整合包同时声明了多个加载器（\(names)），无法确定启动环境。")
        }
        return .init(
            minecraftVersion: version,
            loader: declared.first?.0,
            loaderVersion: declared.first?.1
        )
    }

    private static func installRuntime(
        _ requirement: RuntimeRequirement,
        name: String,
        packName: String,
        totalFiles: Int,
        into minecraftDirectory: MinecraftDirectory,
        progress: ModpackImportProgressHandler?
    ) async throws {
        _ = try await MinecraftInstaller.install(
            MinecraftVersion(displayName: requirement.minecraftVersion),
            name: name,
            minecraftDirectory: minecraftDirectory,
            loader: requirement.loader,
            loaderVersion: requirement.loaderVersion
        ) { value, status in
            progress?(.init(
                packName: packName,
                status: status,
                stage: .runtime,
                stageProgress: value,
                progress: 0.02 + value * 0.09,
                finishedFiles: 0,
                totalFiles: totalFiles
            ))
        }
    }

    @discardableResult
    private static func validateInstance(
        at versionDirectory: URL,
        in minecraftDirectory: MinecraftDirectory,
        requirement: RuntimeRequirement?
    ) throws -> MinecraftInstance {
        let name = versionDirectory.lastPathComponent
        let manifestURL = versionDirectory.appending(path: "\(name).json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MyLocalizedError(reason: "实例缺少客户端清单 \(name).json。")
        }
        guard FileManager.default.fileExists(atPath: versionDirectory.appending(path: "\(name).jar").path) else {
            throw MyLocalizedError(reason: "实例缺少 Minecraft 客户端 \(name).jar。")
        }

        MinecraftInstance.clearCache(for: versionDirectory)
        guard let instance = MinecraftInstance.create(minecraftDirectory, versionDirectory),
              !instance.manifest.mainClass.isEmpty else {
            throw MyLocalizedError(reason: "实例文件已生成，但启动清单无法加载。")
        }
        if let expectedLoader = requirement?.loader,
           expectedLoader != .vanilla,
           instance.clientBrand != expectedLoader {
            throw MyLocalizedError(reason: "实例加载器校验失败：期望 \(expectedLoader.getName())，实际为 \(instance.clientBrand.getName())。")
        }
        return instance
    }

    private static func cleanupIncompleteInstance(at versionDirectory: URL) {
        MinecraftInstance.clearCache(for: versionDirectory)
        guard FileManager.default.fileExists(atPath: versionDirectory.path) else { return }
        do {
            try FileManager.default.removeItem(at: versionDirectory)
            log("已清理导入失败的实例：\(versionDirectory.lastPathComponent)")
        } catch {
            err("无法清理导入失败的实例：\(error.localizedDescription)")
        }
    }

    private static func safeDestination(relativePath: String, under root: URL) throws -> URL {
        let normalized = normalizedArchivePath(relativePath)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw MyLocalizedError(reason: "整合包包含不安全路径：\(relativePath)")
        }
        let rootURL = root.standardizedFileURL
        let destination = rootURL.appending(path: normalized).standardizedFileURL
        guard destination.path == rootURL.path || destination.path.hasPrefix(rootURL.path + "/") else {
            throw MyLocalizedError(reason: "整合包文件试图写入实例目录之外：\(relativePath)")
        }
        return destination
    }

    private static func minecraftVersion(from manifest: JSON) -> String {
        let candidates = [
            manifest["minecraft"]["version"].string,
            manifest["gameVersion"].string,
            manifest["minecraftVersion"].string,
            manifest["minecraft"].string
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? ""
    }

    private static func parseCurseForgeLoader(_ id: String) -> (ClientBrand, String?)? {
        let lower = id.lowercased()
        for (prefix, brand) in [
            ("neoforge-", ClientBrand.neoforge),
            ("forge-", ClientBrand.forge),
            ("fabric-", ClientBrand.fabric),
            ("quilt-", ClientBrand.quilt)
        ] where lower.hasPrefix(prefix) {
            return (brand, String(id.dropFirst(prefix.count)))
        }
        return nil
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

    private static func uniqueInstanceDirectoryName(_ proposed: String, in minecraftDirectory: MinecraftDirectory) -> String {
        let base = proposed.isEmpty ? "modpack" : proposed
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(atPath: minecraftDirectory.versionsURL.appending(path: candidate).path) {
            candidate = "\(base) \(index)"
            index += 1
        }
        return candidate
    }

    private static func resolveNestedModpackURL(_ zipURL: URL) throws -> URL {
        let archive = try Archive(url: zipURL, accessMode: .read)
        guard let entry = Array(archive).first(where: {
            let path = normalizedArchivePath($0.path).lowercased()
            return path == "modpack.mrpack" || path == "modpack.zip"
        }) else {
            return zipURL
        }

        let tempDirectory = SharedConstants.shared.temperatureURL.appending(path: "modpack-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let nestedURL = tempDirectory.appending(path: (entry.path as NSString).lastPathComponent)
        _ = try archive.extract(entry, to: nestedURL)
        return nestedURL
    }

    private static func findSimpleInstancePrefix(in entries: [Entry]) -> (prefix: String, name: String)? {
        for entry in entries {
            let path = normalizedArchivePath(entry.path)
            guard let range = path.range(of: ".minecraft/versions/") else { continue }
            let remaining = path[range.upperBound...]
            guard let namePart = remaining.split(separator: "/", omittingEmptySubsequences: true).first else { continue }
            let prefix = String(path[..<range.upperBound]) + namePart + "/"
            return (prefix, String(namePart))
        }
        return nil
    }

    private static func normalizedArchivePath(_ path: String) -> String {
        let replaced = path.replacingOccurrences(of: "\\", with: "/")
        return replaced.hasPrefix("./") ? String(replaced.dropFirst(2)) : replaced
    }

    private static func renameSimpleVersionFilesIfNeeded(in versionDir: URL, from oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        let oldJSON = versionDir.appending(path: "\(oldName).json")
        let newJSON = versionDir.appending(path: "\(newName).json")
        if FileManager.default.fileExists(atPath: oldJSON.path), !FileManager.default.fileExists(atPath: newJSON.path) {
            try FileManager.default.moveItem(at: oldJSON, to: newJSON)
        }

        let oldJar = versionDir.appending(path: "\(oldName).jar")
        let newJar = versionDir.appending(path: "\(newName).jar")
        if FileManager.default.fileExists(atPath: oldJar.path), !FileManager.default.fileExists(atPath: newJar.path) {
            try FileManager.default.moveItem(at: oldJar, to: newJar)
        }
    }
}
