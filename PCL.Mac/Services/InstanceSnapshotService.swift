import CryptoKit
import Foundation
import ZIPFoundation

struct InstanceSnapshotMetadata: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let instanceName: String
    let sourceFingerprint: String
    let createdAt: Date
    let reason: String
    let includedPaths: [String]

    init(instance: MinecraftInstance, reason: String, includedPaths: [String]) {
        schemaVersion = Self.currentSchemaVersion
        id = UUID()
        instanceName = instance.name
        sourceFingerprint = InstanceSnapshotService.fingerprint(for: instance.runningDirectory)
        createdAt = Date()
        self.reason = reason
        self.includedPaths = includedPaths
    }
}

struct InstanceSnapshotRecord: Identifiable, Hashable, Sendable {
    var id: UUID { metadata.id }
    let metadata: InstanceSnapshotMetadata
    let archiveURL: URL
    let byteSize: Int64
}

enum InstanceSnapshotError: LocalizedError {
    case incompatibleSnapshot
    case corruptedSnapshot
    case instanceIsRunning
    case noSnapshotContent

    var errorDescription: String? {
        switch self {
        case .incompatibleSnapshot: "该快照属于另一个实例，不能恢复到当前实例。"
        case .corruptedSnapshot: "快照已损坏或元数据不完整。"
        case .instanceIsRunning: "游戏运行时不能创建或恢复快照。"
        case .noSnapshotContent: "实例中没有可写入快照的配置或内容。"
        }
    }
}

actor InstanceSnapshotService {
    static let shared = InstanceSnapshotService()

    static let managedPaths = [
        ".PCL_Mac.json",
        "mods",
        "config",
        "resourcepacks",
        "shaderpacks",
        "options.txt",
        "servers.dat"
    ]

    private let storageRoot: URL
    private let fileManager: FileManager

    init(storageRoot: URL? = nil, fileManager: FileManager = .default) {
        self.storageRoot = storageRoot
            ?? SharedConstants.shared.applicationSupportURL.appending(path: "Snapshots")
        self.fileManager = fileManager
    }

    func snapshots(for instance: MinecraftInstance) throws -> [InstanceSnapshotRecord] {
        let directory = snapshotDirectory(for: instance)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { metadataURL in
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(InstanceSnapshotMetadata.self, from: data),
                  metadata.schemaVersion == InstanceSnapshotMetadata.currentSchemaVersion else {
                return nil
            }
            let archiveURL = metadataURL.deletingPathExtension().appendingPathExtension("zip")
            guard fileManager.fileExists(atPath: archiveURL.path) else { return nil }
            let size = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return InstanceSnapshotRecord(metadata: metadata, archiveURL: archiveURL, byteSize: size)
        }
        .sorted { $0.metadata.createdAt > $1.metadata.createdAt }
    }

    @discardableResult
    func createSnapshot(for instance: MinecraftInstance, reason: String) throws -> InstanceSnapshotRecord {
        guard instance.process?.isRunning != true else { throw InstanceSnapshotError.instanceIsRunning }

        let included = Self.managedPaths.filter {
            fileManager.fileExists(atPath: instance.runningDirectory.appending(path: $0).path)
        }
        guard !included.isEmpty else { throw InstanceSnapshotError.noSnapshotContent }
        let metadata = InstanceSnapshotMetadata(instance: instance, reason: reason, includedPaths: included)
        let workingDirectory = temporaryDirectory(prefix: "pcl-snapshot-create")
        defer { try? fileManager.removeItem(at: workingDirectory) }
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        for relativePath in included {
            try copyWithoutSymbolicLinks(
                from: instance.runningDirectory.appending(path: relativePath),
                to: workingDirectory.appending(path: relativePath)
            )
        }
        let embeddedMetadataURL = workingDirectory.appending(path: ".pcl-snapshot.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: embeddedMetadataURL, options: .atomic)

        let destinationDirectory = snapshotDirectory(for: instance)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let baseName = snapshotBaseName(metadata)
        let archiveURL = destinationDirectory.appending(path: "\(baseName).zip")
        let metadataURL = destinationDirectory.appending(path: "\(baseName).json")
        try fileManager.zipItem(at: workingDirectory, to: archiveURL, shouldKeepParent: false)
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        let size = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return InstanceSnapshotRecord(metadata: metadata, archiveURL: archiveURL, byteSize: size)
    }

    func restore(_ snapshot: InstanceSnapshotRecord, to instance: MinecraftInstance) throws {
        guard instance.process?.isRunning != true else { throw InstanceSnapshotError.instanceIsRunning }
        guard snapshot.metadata.sourceFingerprint == Self.fingerprint(for: instance.runningDirectory),
              snapshot.metadata.instanceName == instance.name else {
            throw InstanceSnapshotError.incompatibleSnapshot
        }

        // 恢复前保留一个可见的自动快照，让用户能撤销本次恢复。
        _ = try createSnapshot(for: instance, reason: "恢复前自动备份")

        let extracted = temporaryDirectory(prefix: "pcl-snapshot-extract")
        let rollback = temporaryDirectory(prefix: "pcl-snapshot-rollback")
        defer {
            try? fileManager.removeItem(at: extracted)
            try? fileManager.removeItem(at: rollback)
        }
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
        try Util.unzipOrThrow(archiveURL: snapshot.archiveURL, destination: extracted)

        let embeddedURL = extracted.appending(path: ".pcl-snapshot.json")
        guard let embeddedData = try? Data(contentsOf: embeddedURL),
              let embedded = try? JSONDecoder().decode(InstanceSnapshotMetadata.self, from: embeddedData),
              embedded == snapshot.metadata else {
            throw InstanceSnapshotError.corruptedSnapshot
        }

        var movedCurrent: [String] = []
        do {
            for relativePath in Self.managedPaths {
                let currentURL = instance.runningDirectory.appending(path: relativePath)
                guard fileManager.fileExists(atPath: currentURL.path) else { continue }
                let rollbackURL = rollback.appending(path: relativePath)
                try fileManager.createDirectory(
                    at: rollbackURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: currentURL, to: rollbackURL)
                movedCurrent.append(relativePath)
            }

            for relativePath in embedded.includedPaths {
                guard Self.managedPaths.contains(relativePath) else {
                    throw InstanceSnapshotError.corruptedSnapshot
                }
                let sourceURL = extracted.appending(path: relativePath)
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw InstanceSnapshotError.corruptedSnapshot
                }
                try copyWithoutSymbolicLinks(
                    from: sourceURL,
                    to: instance.runningDirectory.appending(path: relativePath)
                )
            }
        } catch {
            for relativePath in Self.managedPaths {
                try? fileManager.removeItem(at: instance.runningDirectory.appending(path: relativePath))
            }
            for relativePath in movedCurrent {
                let rollbackURL = rollback.appending(path: relativePath)
                if fileManager.fileExists(atPath: rollbackURL.path) {
                    try? fileManager.moveItem(
                        at: rollbackURL,
                        to: instance.runningDirectory.appending(path: relativePath)
                    )
                }
            }
            throw error
        }

        MinecraftInstance.clearCache(for: instance.runningDirectory)
    }

    func delete(_ snapshot: InstanceSnapshotRecord) throws {
        try fileManager.removeItem(at: snapshot.archiveURL)
        let metadataURL = snapshot.archiveURL.deletingPathExtension().appendingPathExtension("json")
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
    }

    static func fingerprint(for url: URL) -> String {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func snapshotDirectory(for instance: MinecraftInstance) -> URL {
        storageRoot.appending(path: Self.fingerprint(for: instance.runningDirectory))
    }

    private func snapshotBaseName(_ metadata: InstanceSnapshotMetadata) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: metadata.createdAt))-\(metadata.id.uuidString.lowercased())"
    }

    private func temporaryDirectory(prefix: String) -> URL {
        fileManager.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
    }

    private func copyWithoutSymbolicLinks(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { return }
        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) {
                try copyWithoutSymbolicLinks(from: child, to: destination.appending(path: child.lastPathComponent))
            }
        } else {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }
    }
}
