//
//  ModpackImporter.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 ModModpack.vb 中 InstallPackModrinth / InstallPackCurseForge / InstallPackHMCL。
//

import Foundation
import CryptoKit
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

public enum ModpackImportStage: Int, CaseIterable, Identifiable, Sendable, Codable {
    case detecting
    case runtime
    case files
    case overrides
    case validation
    case compatibility

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .detecting: "识别整合包"
        case .runtime: "安装游戏环境"
        case .files: "下载整合包内容"
        case .overrides: "应用配置与存档"
        case .validation: "校验启动环境"
        case .compatibility: "检查 Mac 兼容性"
        }
    }

    public var systemImage: String {
        switch self {
        case .detecting: "doc.zipper"
        case .runtime: "shippingbox"
        case .files: "arrow.down.circle"
        case .overrides: "slider.horizontal.3"
        case .validation: "play.circle"
        case .compatibility: "shield.lefthalf.filled"
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

public struct ModpackImportRecoveryInfo: Sendable {
    public let instanceURL: URL
    public let completedFiles: Int
    public let totalFiles: Int
    public let lastError: String?
    public let manualDownloadListURL: URL?

    public init(
        instanceURL: URL,
        completedFiles: Int,
        totalFiles: Int,
        lastError: String?,
        manualDownloadListURL: URL?
    ) {
        self.instanceURL = instanceURL
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.lastError = lastError
        self.manualDownloadListURL = manualDownloadListURL
    }

    public var summary: String {
        guard totalFiles > 0 else { return "未完成实例已保留；重试将从上次阶段继续。" }
        return "已保留 \(completedFiles) / \(totalFiles) 个文件；重试会先校验现有文件，只下载缺失或损坏的内容。"
    }
}

public struct ModpackImportFailure: LocalizedError, Sendable {
    public let stage: ModpackImportStage
    public let reason: String
    public let completedFiles: Int
    public let totalFiles: Int
    public let recoveryDirectory: URL
    public let manualDownloadListURL: URL?

    public init(
        stage: ModpackImportStage,
        reason: String,
        completedFiles: Int,
        totalFiles: Int,
        recoveryDirectory: URL,
        manualDownloadListURL: URL?
    ) {
        self.stage = stage
        self.reason = reason
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.recoveryDirectory = recoveryDirectory
        self.manualDownloadListURL = manualDownloadListURL
    }

    public var errorDescription: String? {
        var lines = [reason]
        if totalFiles > 0 {
            lines.append("已保留 \(completedFiles) / \(totalFiles) 个文件，继续重试不会重新下载已校验通过的文件。")
        } else {
            lines.append("未完成实例已保留，继续重试会从上次阶段恢复。")
        }
        if let manualDownloadListURL {
            lines.append("人工下载清单：\(manualDownloadListURL.path)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ModpackImporter

public enum ModpackImporter {
    private static let checkpointFileName = ".PCL_Mac_import.json"
    private static let manualDownloadFileName = ".PCL_Mac_manual_downloads.json"

    private struct ResolvedCurseForgeFile: Codable, Sendable {
        let projectID: Int
        let fileID: Int
        let fileName: String
        let relativePath: String
        let downloadURL: URL?
        let sha1: String?
        let projectPageURL: URL?
        let isAvailable: Bool
    }

    private struct ImportCheckpoint: Codable {
        var schemaVersion = 1
        let sourceFingerprint: String
        let sourcePath: String
        let sourceFileSize: Int64
        let sourceModifiedAt: Date?
        let format: String
        let instanceID: String
        let packName: String
        var state: String = "inProgress"
        var currentStage: ModpackImportStage = .detecting
        var completedStages: Set<ModpackImportStage> = []
        var completedFiles = 0
        var totalFiles = 0
        var lastError: String?
        var updatedAt = Date()
        var curseForgeFiles: [ResolvedCurseForgeFile]?
    }

    private final class ImportSession {
        let instanceURL: URL
        let checkpointURL: URL
        var checkpoint: ImportCheckpoint

        init(instanceURL: URL, checkpoint: ImportCheckpoint) {
            self.instanceURL = instanceURL
            self.checkpointURL = instanceURL.appending(path: ModpackImporter.checkpointFileName)
            self.checkpoint = checkpoint
        }

        func begin(_ stage: ModpackImportStage) throws {
            checkpoint.currentStage = stage
            checkpoint.state = "inProgress"
            checkpoint.updatedAt = Date()
            try save()
        }

        func complete(_ stage: ModpackImportStage, completedFiles: Int? = nil, totalFiles: Int? = nil) throws {
            checkpoint.completedStages.insert(stage)
            checkpoint.currentStage = stage
            if let completedFiles { checkpoint.completedFiles = completedFiles }
            if let totalFiles { checkpoint.totalFiles = totalFiles }
            checkpoint.lastError = nil
            checkpoint.updatedAt = Date()
            try save()
        }

        func contains(_ stage: ModpackImportStage) -> Bool {
            checkpoint.completedStages.contains(stage)
        }

        func cache(_ files: [ResolvedCurseForgeFile]) throws {
            checkpoint.curseForgeFiles = files
            checkpoint.updatedAt = Date()
            try save()
        }

        func fail(_ failure: ModpackImportFailure) {
            checkpoint.state = "failed"
            checkpoint.currentStage = failure.stage
            checkpoint.completedFiles = failure.completedFiles
            checkpoint.totalFiles = failure.totalFiles
            checkpoint.lastError = failure.reason
            checkpoint.updatedAt = Date()
            try? save()
        }

        func finish() throws {
            try? FileManager.default.removeItem(at: instanceURL.appending(path: ModpackImporter.manualDownloadFileName))
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                try FileManager.default.removeItem(at: checkpointURL)
            }
        }

        func discard() {
            ModpackImporter.cleanupIncompleteInstance(at: instanceURL)
        }

        private func save() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
            try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
        }
    }

    private struct ManualDownloadRecord: Codable, Sendable {
        let projectID: Int
        let fileID: Int
        let fileName: String
        let destination: String
        let expectedSHA1: String?
        let curseForgePage: URL?
    }

    private struct ManualDownloadManifest: Codable, Sendable {
        let schemaVersion: Int
        let reason: String
        let generatedAt: Date
        let files: [ManualDownloadRecord]
    }

    private struct CurseForgeProjectHint {
        let projectURL: URL

        var destinationFolder: String {
            ModpackImporter.curseForgeDestinationFolder(for: projectURL)
        }
    }

    static func curseForgeDestinationFolder(for projectURL: URL) -> String {
        let path = projectURL.path.lowercased()
        if path.contains("/shaders/") { return "shaderpacks" }
        if path.contains("/texture-packs/") || path.contains("/resource-packs/") { return "resourcepacks" }
        if path.contains("/worlds/") { return "saves" }
        return "mods"
    }

    public enum Format: Sendable, Equatable {
        case modrinth       // .mrpack (zip 含 modrinth.index.json)
        case curseforge     // .zip 含 manifest.json (minecraft/modloader 字段)
        case hmcl           // .zip 含 manifest.json + override/
        case simple         // 压缩包内直接包含 .minecraft/versions/<实例名>
        case unknown
    }

    /// Finds the recoverable instance associated with the selected archive.
    /// This also works after an app restart because the checkpoint lives inside
    /// the Minecraft directory rather than in transient view state.
    public static func recoveryInfo(
        for zipURL: URL,
        in minecraftDirectory: MinecraftDirectory
    ) -> ModpackImportRecoveryInfo? {
        guard let checkpoints = try? FileManager.default.contentsOfDirectory(
            at: minecraftDirectory.versionsURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return nil }

        let sourcePath = zipURL.standardizedFileURL.path
        return checkpoints.compactMap { directory -> (ImportCheckpoint, URL)? in
            let checkpointURL = directory.appending(path: checkpointFileName)
            guard let checkpoint = readCheckpoint(at: checkpointURL),
                  checkpoint.sourcePath == sourcePath,
                  checkpoint.state != "complete" else { return nil }
            return (checkpoint, directory)
        }
        .sorted { $0.0.updatedAt > $1.0.updatedAt }
        .first
        .map { checkpoint, directory in
            let manualURL = directory.appending(path: manualDownloadFileName)
            return ModpackImportRecoveryInfo(
                instanceURL: directory,
                completedFiles: checkpoint.completedFiles,
                totalFiles: checkpoint.totalFiles,
                lastError: checkpoint.lastError,
                manualDownloadListURL: FileManager.default.fileExists(atPath: manualURL.path) ? manualURL : nil
            )
        }
    }

    private static func prepareImportSession(
        recoverySourceURL: URL,
        format: String,
        packName: String,
        proposedInstanceID: String,
        signature: Data,
        minecraftDirectory: MinecraftDirectory
    ) throws -> ImportSession {
        try FileManager.default.createDirectory(at: minecraftDirectory.versionsURL, withIntermediateDirectories: true)
        let source = recoverySourceURL.standardizedFileURL
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        let modifiedAt = values.contentModificationDate
        let signatureHash = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
        let identity = [
            source.path,
            String(size),
            modifiedAt.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "unknown",
            format,
            signatureHash
        ].joined(separator: "|")
        let fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()

        let directories = (try? FileManager.default.contentsOfDirectory(
            at: minecraftDirectory.versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        if let recovered = directories.compactMap({ directory -> ImportSession? in
            let checkpointURL = directory.appending(path: checkpointFileName)
            guard let checkpoint = readCheckpoint(at: checkpointURL),
                  checkpoint.sourceFingerprint == fingerprint,
                  checkpoint.state != "complete" else { return nil }
            return ImportSession(instanceURL: directory, checkpoint: checkpoint)
        }).sorted(by: { $0.checkpoint.updatedAt > $1.checkpoint.updatedAt }).first {
            log("继续整合包导入：\(recovered.checkpoint.packName)，复用实例目录 \(recovered.instanceURL.lastPathComponent)")
            return recovered
        }

        let instanceID = uniqueInstanceDirectoryName(proposedInstanceID, in: minecraftDirectory)
        let instanceURL = minecraftDirectory.versionsURL.appending(path: instanceID)
        let checkpoint = ImportCheckpoint(
            sourceFingerprint: fingerprint,
            sourcePath: source.path,
            sourceFileSize: size,
            sourceModifiedAt: modifiedAt,
            format: format,
            instanceID: instanceID,
            packName: packName
        )
        let session = ImportSession(instanceURL: instanceURL, checkpoint: checkpoint)
        try session.begin(.detecting)
        return session
    }

    private static func runRecoverableImport<T>(
        _ session: ImportSession,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            try session.finish()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                session.discard()
                throw CancellationError()
            }

            let failure: ModpackImportFailure
            if let known = error as? ModpackImportFailure {
                failure = known
            } else if let batch = error as? MultiFileDownloadFailure {
                failure = ModpackImportFailure(
                    stage: session.checkpoint.currentStage,
                    reason: batch.reason,
                    completedFiles: batch.completedFiles,
                    totalFiles: batch.totalFiles,
                    recoveryDirectory: session.instanceURL,
                    manualDownloadListURL: nil
                )
            } else {
                failure = ModpackImportFailure(
                    stage: session.checkpoint.currentStage,
                    reason: error.localizedDescription,
                    completedFiles: session.checkpoint.completedFiles,
                    totalFiles: session.checkpoint.totalFiles,
                    recoveryDirectory: session.instanceURL,
                    manualDownloadListURL: nil
                )
            }
            session.fail(failure)
            throw failure
        }
    }

    private static func readCheckpoint(at url: URL) -> ImportCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportCheckpoint.self, from: data)
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
        // A wrapper archive may contain modpack.zip/modpack.mrpack. Keep the
        // user-selected outer URL as the stable recovery identity; the nested
        // file is extracted to a new temporary path on every app launch.
        let recoverySourceURL = zipURL
        let resolvedZipURL = try resolveNestedModpackURL(zipURL)
        let format = try detectFormat(of: resolvedZipURL)
        progress?(.init(
            packName: instanceName ?? recoverySourceURL.deletingPathExtension().lastPathComponent,
            status: "已识别整合包格式",
            stage: .detecting,
            stageProgress: 1,
            progress: 0.01,
            finishedFiles: 0,
            totalFiles: 0
        ))
        let installedURL: URL
        switch format {
        case .modrinth:
            installedURL = try await installModrinth(zipURL: resolvedZipURL, into: minecraftDirectory, instanceName: instanceName, recoverySourceURL: recoverySourceURL, progress: progress)
        case .curseforge:
            installedURL = try await installCurseForge(zipURL: resolvedZipURL, into: minecraftDirectory, instanceName: instanceName, recoverySourceURL: recoverySourceURL, progress: progress)
        case .hmcl:
            installedURL = try await installHMCL(zipURL: resolvedZipURL, into: minecraftDirectory, instanceName: instanceName, recoverySourceURL: recoverySourceURL, progress: progress)
        case .simple:
            installedURL = try await installSimple(zipURL: resolvedZipURL, into: minecraftDirectory, instanceName: instanceName, recoverySourceURL: recoverySourceURL, progress: progress)
        case .unknown:
            throw MyLocalizedError(reason: "无法识别的整合包格式。期待 .mrpack / CurseForge / HMCL / .minecraft 压缩包其中之一。")
        }

        let displayName = instanceName ?? installedURL.lastPathComponent
        progress?(.init(
            packName: displayName,
            status: "正在检查 Windows-only Mod 与原生架构",
            stage: .compatibility,
            stageProgress: 0.15,
            progress: 0.985,
            finishedFiles: 0,
            totalFiles: 0
        ))
        do {
            let instance = MinecraftInstance.create(minecraftDirectory, installedURL)
            let configuredJava: URL? = instance?.config.javaURL
            let targetArchitecture = configuredJava.map { Architecture.getArchOfFile($0) } ?? .system
            let resolvedArchitecture: Architecture = switch targetArchitecture {
            case .unknown, .fatFile: .system
            default: targetArchitecture
            }
            var report: NativeCompatibilityReport
            if let instance {
                report = try await NativeCompatibilityService.shared.analyze(
                    instance: instance,
                    targetArchitecture: resolvedArchitecture
                )
            } else {
                report = try await NativeCompatibilityService.shared.analyze(
                    instanceURL: installedURL,
                    targetArchitecture: resolvedArchitecture
                )
            }
            report = try await NativeCompatibilityService.shared.applyTrustedFixes(report: report)
            let status: String
            if report.disabledCount > 0 || report.installedOfficialArtifactCount > 0 || report.unresolvedCount > 0 {
                status = "已隔离 \(report.disabledCount) 个，官方补全 \(report.installedOfficialArtifactCount) 个，仅警告 \(report.unresolvedCount) 个"
            } else {
                status = "未发现 Mac 原生兼容问题"
            }
            progress?(.init(
                packName: displayName,
                status: status,
                stage: .compatibility,
                stageProgress: 1,
                progress: 1,
                finishedFiles: 0,
                totalFiles: 0
            ))
        } catch {
            // Compatibility diagnostics must not destroy an otherwise valid
            // imported instance. Launch precheck will retry the same scan.
            warn("整合包 Mac 兼容性检查暂未完成：\(error.localizedDescription)")
            progress?(.init(
                packName: displayName,
                status: "导入完成；兼容性检查将在启动前重试",
                stage: .compatibility,
                stageProgress: 1,
                progress: 1,
                finishedFiles: 0,
                totalFiles: 0
            ))
        }
        return installedURL
    }

    // MARK: - Modrinth 安装

    public static func installModrinth(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        recoverySourceURL: URL? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let pack = try parseModrinth(zipURL)
        let name = instanceName ?? pack.name
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let session = try prepareImportSession(
            recoverySourceURL: recoverySourceURL ?? zipURL,
            format: "modrinth",
            packName: name,
            proposedInstanceID: sanitizeDirName(name),
            signature: try encoder.encode(pack),
            minecraftDirectory: minecraftDirectory
        )
        let instanceId = session.checkpoint.instanceID
        let versionDir = session.instanceURL
        let instanceDir = versionDir
        let requirement = try runtimeRequirement(
            minecraftVersion: pack.dependencies["minecraft"],
            loaders: [
                (.fabric, pack.dependencies["fabric-loader"]),
                (.forge, pack.dependencies["forge"]),
                (.neoforge, pack.dependencies["neoforge"]),
                (.quilt, pack.dependencies["quilt-loader"])
            ]
        )
        let files = pack.files.filter { $0.env?.client != "unsupported" }
        return try await runRecoverableImport(session) {
            try session.begin(.runtime)
            if session.contains(.runtime),
               (try? validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)) != nil {
                progress?(.init(packName: name, status: "已复用安装完成的游戏环境", stage: .runtime, stageProgress: 1, progress: 0.11, finishedFiles: 0, totalFiles: files.count))
            } else {
                progress?(.init(packName: name, status: "正在安装 Minecraft \(requirement.minecraftVersion)", stage: .runtime, stageProgress: 0.05, progress: 0.02, finishedFiles: 0, totalFiles: files.count))
                try await installRuntime(requirement, name: instanceId, packName: name, totalFiles: files.count, into: minecraftDirectory, progress: progress)
                try session.complete(.runtime)
            }
            try Task.checkCancellation()

            try session.begin(.files)
            try FileManager.default.createDirectory(at: instanceDir.appending(path: "mods"), withIntermediateDirectories: true)
            log("Modrinth 整合包安装：\(name)，共 \(files.count) 个文件")
            let downloadItems: [DownloadItem] = try files.map { file in
                guard let url = file.downloads.first else {
                    throw MyLocalizedError(reason: "整合包文件 \(file.path) 没有可用下载源。")
                }
                return DownloadItem(url, try safeDestination(relativePath: file.path, under: instanceDir), sha1: file.hashes.sha1)
            }
            try await MultiFileDownloader(items: downloadItems, replaceMethod: .skip, networkCategory: .gameDownload) { fileProgress, finished in
                progress?(.init(
                    packName: name,
                    status: finished > 0 ? "正在导入整合包文件（已复用或完成 \(finished) 个）" : "正在导入整合包文件",
                    stage: .files,
                    stageProgress: fileProgress,
                    progress: 0.12 + fileProgress * 0.76,
                    finishedFiles: finished,
                    totalFiles: files.count
                ))
            }.start()
            try session.complete(.files, completedFiles: files.count, totalFiles: files.count)

            try session.begin(.overrides)
            progress?(.init(packName: name, status: "正在校验并应用覆盖文件", stage: .overrides, stageProgress: 0.1, progress: 0.90, finishedFiles: files.count, totalFiles: files.count))
            try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "overrides")
            try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "client-overrides")
            try session.complete(.overrides)

            try session.begin(.validation)
            progress?(.init(packName: name, status: "正在校验实例", stage: .validation, stageProgress: 0.35, progress: 0.97, finishedFiles: files.count, totalFiles: files.count))
            try validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)
            try session.complete(.validation, completedFiles: files.count, totalFiles: files.count)
            log("Modrinth 整合包安装完成：\(name)")
            progress?(.init(packName: name, status: "实例文件已就绪", stage: .validation, stageProgress: 1, progress: 0.98, finishedFiles: files.count, totalFiles: files.count))
            return instanceDir
        }
    }

    // MARK: - CurseForge 安装

    public static func installCurseForge(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        recoverySourceURL: URL? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let manifest = try parseCurseForge(zipURL)
        let mcVersion = minecraftVersion(from: manifest)
        let manifestName = manifest["name"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = instanceName ?? (manifestName.isEmpty ? zipURL.deletingPathExtension().lastPathComponent : manifestName)
        let signature = try JSONSerialization.data(withJSONObject: manifest.object, options: [.sortedKeys])
        let session = try prepareImportSession(
            recoverySourceURL: recoverySourceURL ?? zipURL,
            format: "curseforge",
            packName: name,
            proposedInstanceID: sanitizeDirName(name),
            signature: signature,
            minecraftDirectory: minecraftDirectory
        )
        let instanceId = session.checkpoint.instanceID
        let versionDir = session.instanceURL
        let instanceDir = versionDir
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
        let mods = manifest["files"].arrayValue
        return try await runRecoverableImport(session) {
            try session.begin(.runtime)
            if session.contains(.runtime),
               (try? validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)) != nil {
                progress?(.init(packName: name, status: "已复用安装完成的游戏环境", stage: .runtime, stageProgress: 1, progress: 0.11, finishedFiles: 0, totalFiles: mods.count))
            } else {
                progress?(.init(packName: name, status: "正在安装 Minecraft \(requirement.minecraftVersion)", stage: .runtime, stageProgress: 0.05, progress: 0.02, finishedFiles: 0, totalFiles: mods.count))
                try await installRuntime(requirement, name: instanceId, packName: name, totalFiles: mods.count, into: minecraftDirectory, progress: progress)
                try session.complete(.runtime)
            }
            try Task.checkCancellation()

            try session.begin(.files)
            progress?(.init(packName: name, status: "正在解析 CurseForge 文件名、校验值与下载地址", stage: .files, stageProgress: 0.02, progress: 0.12, finishedFiles: 0, totalFiles: mods.count))
            let resolvedFiles = try await resolveCurseForgeFiles(
                mods: mods,
                zipURL: zipURL,
                cached: session.checkpoint.curseForgeFiles
            )
            try session.cache(resolvedFiles)
            log("CurseForge 整合包安装：\(name)，共 \(resolvedFiles.count) 个声明文件")

            var downloadItems: [DownloadItem] = []
            var manuallySatisfied = 0
            var manualRecords: [ManualDownloadRecord] = []
            for file in resolvedFiles {
                let destination = try safeDestination(relativePath: file.relativePath, under: instanceDir)
                if let downloadURL = file.downloadURL {
                    downloadItems.append(DownloadItem(downloadURL, destination, sha1: file.sha1))
                } else if fileIsValid(at: destination, sha1: file.sha1) {
                    manuallySatisfied += 1
                } else {
                    manualRecords.append(.init(
                        projectID: file.projectID,
                        fileID: file.fileID,
                        fileName: file.fileName,
                        destination: file.relativePath,
                        expectedSHA1: file.sha1,
                        curseForgePage: file.projectPageURL
                    ))
                }
            }

            let manualListURL = instanceDir.appending(path: manualDownloadFileName)
            if manualRecords.isEmpty {
                try? FileManager.default.removeItem(at: manualListURL)
            } else {
                try writeManualDownloadManifest(manualRecords, to: manualListURL)
            }

            do {
                try await MultiFileDownloader(items: downloadItems, replaceMethod: .skip, networkCategory: .gameDownload) { fileProgress, finished in
                    let completed = manuallySatisfied + finished
                    let totalProgress = resolvedFiles.isEmpty
                        ? 1
                        : Double(completed) / Double(resolvedFiles.count)
                    progress?(.init(
                        packName: name,
                        status: completed > 0 ? "正在下载 CurseForge 依赖（已复用或完成 \(completed) 个）" : "正在下载 CurseForge 依赖",
                        stage: .files,
                        stageProgress: totalProgress,
                        progress: 0.12 + totalProgress * 0.68,
                        finishedFiles: completed,
                        totalFiles: resolvedFiles.count
                    ))
                }.start()
            } catch let failure as MultiFileDownloadFailure {
                throw ModpackImportFailure(
                    stage: .files,
                    reason: failure.reason,
                    completedFiles: manuallySatisfied + failure.completedFiles,
                    totalFiles: resolvedFiles.count,
                    recoveryDirectory: instanceDir,
                    manualDownloadListURL: manualRecords.isEmpty ? nil : manualListURL
                )
            }

            let completed = manuallySatisfied + downloadItems.count
            if !manualRecords.isEmpty {
                let reason = "CurseForge 中有 \(manualRecords.count) 个文件由作者关闭了第三方启动器下载。其余 \(completed) 个文件已下载并保留；请按照清单手动下载到标注目录后继续重试。PCL.Mac 不会绕过作者的分发设置。"
                warn("\(name)：\(reason) 清单位于 \(manualListURL.path)")
                throw ModpackImportFailure(
                    stage: .files,
                    reason: reason,
                    completedFiles: completed,
                    totalFiles: resolvedFiles.count,
                    recoveryDirectory: instanceDir,
                    manualDownloadListURL: manualListURL
                )
            }
            try session.complete(.files, completedFiles: resolvedFiles.count, totalFiles: resolvedFiles.count)

            let overridesDirectory = manifest["overrides"].stringValue.isEmpty ? "overrides" : manifest["overrides"].stringValue
            try session.begin(.overrides)
            progress?(.init(packName: name, status: "正在校验并应用覆盖文件", stage: .overrides, stageProgress: 0.15, progress: 0.84, finishedFiles: mods.count, totalFiles: mods.count))
            try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: overridesDirectory)
            try session.complete(.overrides)

            try session.begin(.validation)
            progress?(.init(packName: name, status: "正在校验实例", stage: .validation, stageProgress: 0.35, progress: 0.97, finishedFiles: mods.count, totalFiles: mods.count))
            try validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)
            try session.complete(.validation, completedFiles: mods.count, totalFiles: mods.count)
            log("CurseForge 整合包安装完成：\(name)")
            progress?(.init(packName: name, status: "实例文件已就绪", stage: .validation, stageProgress: 1, progress: 0.98, finishedFiles: mods.count, totalFiles: mods.count))
            return instanceDir
        }
    }

    // MARK: - HMCL 安装

    public static func installHMCL(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        recoverySourceURL: URL? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let manifest = try parseHMCL(zipURL)
        let mcVersion = minecraftVersion(from: manifest)
        let manifestName = manifest["name"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = instanceName ?? (manifestName.isEmpty ? zipURL.deletingPathExtension().lastPathComponent : manifestName)
        let signature = try JSONSerialization.data(withJSONObject: manifest.object, options: [.sortedKeys])
        let session = try prepareImportSession(
            recoverySourceURL: recoverySourceURL ?? zipURL,
            format: "hmcl",
            packName: name,
            proposedInstanceID: sanitizeDirName(name),
            signature: signature,
            minecraftDirectory: minecraftDirectory
        )
        let instanceId = session.checkpoint.instanceID
        let versionDir = session.instanceURL
        let instanceDir = versionDir
        let requirement = try runtimeRequirement(
            minecraftVersion: mcVersion,
            loaders: [
                (.forge, manifest["forge"].string),
                (.fabric, manifest["fabricLoader"].string),
                (.quilt, manifest["quiltLoader"].string),
                (.liteLoader, manifest["liteloader"].string)
            ]
        )
        return try await runRecoverableImport(session) {
            try session.begin(.runtime)
            if session.contains(.runtime),
               (try? validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)) != nil {
                progress?(.init(packName: name, status: "已复用安装完成的游戏环境", stage: .runtime, stageProgress: 1, progress: 0.11, finishedFiles: 0, totalFiles: 0))
            } else {
                progress?(.init(packName: name, status: "正在安装 Minecraft \(requirement.minecraftVersion)", stage: .runtime, stageProgress: 0.05, progress: 0.02, finishedFiles: 0, totalFiles: 0))
                try await installRuntime(requirement, name: instanceId, packName: name, totalFiles: 0, into: minecraftDirectory, progress: progress)
                try session.complete(.runtime)
            }
            try Task.checkCancellation()

            try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
            try session.begin(.overrides)
            progress?(.init(packName: name, status: "正在校验并应用覆盖文件", stage: .overrides, stageProgress: 0.15, progress: 0.84, finishedFiles: 0, totalFiles: 0))
            try await extractOverrides(zipURL: zipURL, into: instanceDir, sourceSubdir: "override")
            try session.complete(.overrides)

            try session.begin(.validation)
            progress?(.init(packName: name, status: "正在校验实例", stage: .validation, stageProgress: 0.35, progress: 0.96, finishedFiles: 0, totalFiles: 0))
            try validateInstance(at: versionDir, in: minecraftDirectory, requirement: requirement)
            try session.complete(.validation)
            log("HMCL 整合包安装完成：\(name)")
            progress?(.init(packName: name, status: "实例文件已就绪", stage: .validation, stageProgress: 1, progress: 0.98, finishedFiles: 0, totalFiles: 0))
            return instanceDir
        }
    }

    // MARK: - 简单压缩包安装

    public static func installSimple(
        zipURL: URL,
        into minecraftDirectory: MinecraftDirectory,
        instanceName: String? = nil,
        recoverySourceURL: URL? = nil,
        progress: ModpackImportProgressHandler? = nil
    ) async throws -> URL {
        let archive = try Archive(url: zipURL, accessMode: .read)
        let entries = Array(archive)
        guard let found = findSimpleInstancePrefix(in: entries) else {
            throw MyLocalizedError(reason: "找不到 .minecraft/versions 下的实例目录。")
        }

        let name = instanceName ?? found.name
        let files = entries.filter { !$0.path.hasSuffix("/") && normalizedArchivePath($0.path).hasPrefix(found.prefix) }
        let signatureText = files
            .map { "\(normalizedArchivePath($0.path)):\($0.uncompressedSize)" }
            .joined(separator: "\n")
        let session = try prepareImportSession(
            recoverySourceURL: recoverySourceURL ?? zipURL,
            format: "simple",
            packName: name,
            proposedInstanceID: sanitizeDirName(name),
            signature: Data(signatureText.utf8),
            minecraftDirectory: minecraftDirectory
        )
        let instanceId = session.checkpoint.instanceID
        let versionDir = session.instanceURL

        return try await runRecoverableImport(session) {
            try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
            try session.begin(.files)
            progress?(.init(packName: name, status: "正在校验并拷贝整合包文件", stage: .files, stageProgress: 0.02, progress: 0.12, finishedFiles: 0, totalFiles: files.count))

            for (index, entry) in files.enumerated() {
                try Task.checkCancellation()
                let normalized = normalizedArchivePath(entry.path)
                var relative = String(normalized.dropFirst(found.prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relative.isEmpty else { continue }
                if relative == "\(found.name).json" {
                    relative = "\(instanceId).json"
                } else if relative == "\(found.name).jar" {
                    relative = "\(instanceId).jar"
                }
                guard relative != checkpointFileName,
                      relative != manualDownloadFileName else {
                    throw MyLocalizedError(reason: "整合包试图覆盖 PCL.Mac 的导入检查点：\(relative)")
                }
                let target = try safeDestination(relativePath: relative, under: versionDir)
                if !fileMatchesArchiveEntry(target, entry: entry) {
                    try target.ensureParentDirectoryExists()
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    _ = try archive.extract(entry, to: target)
                }
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
            try session.complete(.files, completedFiles: files.count, totalFiles: files.count)

            try session.begin(.validation)
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
            try session.complete(.validation, completedFiles: files.count, totalFiles: files.count)
            progress?(.init(packName: name, status: "实例文件已就绪", stage: .validation, stageProgress: 1, progress: 0.98, finishedFiles: files.count, totalFiles: files.count))
            return versionDir
        }
    }

    // MARK: - Helpers

    /// CurseForge manifests intentionally contain only project/file IDs. The
    /// public web download route is protected by Cloudflare and is not an API.
    /// Resolve the official file metadata through the mirror already trusted by
    /// the launcher's download-source subsystem, then download the returned CDN
    /// URL with its SHA-1. No URL is synthesized for author-restricted files.
    private static func resolveCurseForgeFiles(
        mods: [JSON],
        zipURL: URL,
        cached: [ResolvedCurseForgeFile]?
    ) async throws -> [ResolvedCurseForgeFile] {
        let identifiers: [(projectID: Int, fileID: Int)] = try mods.map { mod in
            (
                try mod["projectID"].int.unwrap("CurseForge 清单缺少 projectID。"),
                try mod["fileID"].int.unwrap("CurseForge 清单缺少 fileID。")
            )
        }
        if let cached,
           cached.count == identifiers.count,
           zip(cached, identifiers).allSatisfy({ file, identifier in
               file.projectID == identifier.projectID && file.fileID == identifier.fileID
           }) {
            log("已复用 \(cached.count) 条 CurseForge 文件元数据")
            return cached
        }
        guard !identifiers.isEmpty else { return [] }

        let endpoint = URL(string: "https://mod.mcimirror.top/curseforge/v1/mods/files")!
        let response = await Requests.post(
            endpoint,
            body: ["fileIds": identifiers.map(\.fileID)],
            category: .gameDownload
        )
        guard response.statusCode == 200 else {
            let detail = response.error?.localizedDescription ?? "HTTP \(response.statusCode)"
            throw MyLocalizedError(reason: "无法解析 CurseForge 文件元数据（mod.mcimirror.top：\(detail)）。已下载文件仍会保留，可稍后继续重试。")
        }
        let payload = try response.getJSONOrThrow()
        let metadata = payload["data"].arrayValue
        var metadataByFileID: [Int: JSON] = [:]
        for item in metadata {
            if let id = item["id"].int {
                metadataByFileID[id] = item
            }
        }
        let hints = try curseForgeProjectHints(in: zipURL)

        return try identifiers.enumerated().map { index, identifier in
            guard let item = metadataByFileID[identifier.fileID] else {
                throw MyLocalizedError(reason: "CurseForge 元数据缺少文件 \(identifier.fileID)（项目 \(identifier.projectID)）。")
            }
            if let resolvedProjectID = item["modId"].int,
               resolvedProjectID != identifier.projectID {
                throw MyLocalizedError(reason: "CurseForge 文件 \(identifier.fileID) 所属项目不匹配：清单为 \(identifier.projectID)，元数据为 \(resolvedProjectID)。")
            }

            let manifestFile = mods[index]
            let suppliedName = manifestFile["fileName"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let metadataName = item["fileName"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawName = suppliedName?.isEmpty == false ? suppliedName! : (metadataName ?? "")
            let fileName = (rawName as NSString).lastPathComponent
            guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
                throw MyLocalizedError(reason: "CurseForge 文件 \(identifier.fileID) 没有安全、可用的文件名。")
            }

            let sha1 = item["hashes"].arrayValue.first(where: { hash in
                hash["algo"].int == 1 || hash["value"].stringValue.count == 40
            })?["value"].string
            let hint = hints.indices.contains(index) ? hints[index] : nil
            let destinationFolder = hint?.destinationFolder ?? "mods"
            let suppliedURL = manifestFile["url"].url
            let downloadURL = suppliedURL ?? item["downloadUrl"].url
            let projectPageURL = hint?.projectURL
                .appending(path: "files")
                .appending(path: String(identifier.fileID))

            return ResolvedCurseForgeFile(
                projectID: identifier.projectID,
                fileID: identifier.fileID,
                fileName: fileName,
                relativePath: "\(destinationFolder)/\(fileName)",
                downloadURL: downloadURL,
                sha1: sha1,
                projectPageURL: projectPageURL,
                isAvailable: item["isAvailable"].bool ?? true
            )
        }
    }

    private static func curseForgeProjectHints(in zipURL: URL) throws -> [CurseForgeProjectHint?] {
        let archive = try Archive(url: zipURL, accessMode: .read)
        guard let entry = Array(archive).first(where: {
            normalizedArchivePath($0.path).lowercased() == "modlist.html"
        }) else { return [] }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        let expression = try NSRegularExpression(
            pattern: #"<li\b[^>]*>\s*<a\b[^>]*\bhref\s*=\s*[\"']([^\"']+)[\"']"#,
            options: [.caseInsensitive]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.matches(in: html, range: range).map { match in
            guard match.numberOfRanges > 1,
                  let hrefRange = Range(match.range(at: 1), in: html) else { return nil }
            let href = String(html[hrefRange])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
            guard let url = URL(string: href),
                  url.host?.lowercased().hasSuffix("curseforge.com") == true,
                  url.path.lowercased().contains("/minecraft/") else { return nil }
            return CurseForgeProjectHint(projectURL: url)
        }
    }

    private static func fileIsValid(at url: URL, sha1: String?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let sha1, !sha1.isEmpty else { return true }
        return (try? FileHash.verify(url, expected: sha1, algorithm: .sha1)) != nil
    }

    private static func writeManualDownloadManifest(
        _ records: [ManualDownloadRecord],
        to url: URL
    ) throws {
        let manifest = ManualDownloadManifest(
            schemaVersion: 1,
            reason: "这些 CurseForge 文件由作者关闭了第三方启动器下载。请从 curseForgePage 下载原文件，保持文件名不变，并放入 destination 后重试。",
            generatedAt: Date(),
            files: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try url.ensureParentDirectoryExists()
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

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
            guard relativePath != checkpointFileName,
                  relativePath != manualDownloadFileName else {
                throw MyLocalizedError(reason: "整合包试图覆盖 PCL.Mac 的导入检查点：\(relativePath)")
            }
            let target = try safeDestination(relativePath: relativePath, under: instanceDir)
            if fileMatchesArchiveEntry(target, entry: entry) {
                continue
            }
            try target.ensureParentDirectoryExists()
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            _ = try archive.extract(entry, to: target)
        }
    }

    private static func fileMatchesArchiveEntry(_ url: URL, entry: Entry) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0,
              UInt64(size) == entry.uncompressedSize,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var checksum: CRC32 = 0
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                checksum = chunk.crc32(checksum: checksum)
            }
            return checksum == entry.checksum
        } catch {
            return false
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
