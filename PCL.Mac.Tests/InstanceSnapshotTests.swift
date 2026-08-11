import Foundation
import Testing
@testable import PCL_Mac

struct InstanceSnapshotTests {
    @Test func snapshotRestoreIsTransactionalAndCreatesAnUndoPoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-snapshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try makeInstance(at: root.appending(path: "minecraft"))
        let storage = root.appending(path: "snapshot-storage")
        let service = InstanceSnapshotService(storageRoot: storage)

        let configFile = instance.runningDirectory.appending(path: "config/example.toml")
        let modFile = instance.runningDirectory.appending(path: "mods/example.jar")
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stable-config".utf8).write(to: configFile)
        try Data("stable-mod".utf8).write(to: modFile)

        let stable = try await service.createSnapshot(for: instance, reason: "更新前")
        try Data("broken-config".utf8).write(to: configFile, options: .atomic)
        try Data("new-mod".utf8).write(to: instance.runningDirectory.appending(path: "mods/new.jar"))

        try await service.restore(stable, to: instance)

        #expect(try String(contentsOf: configFile, encoding: .utf8) == "stable-config")
        #expect(!FileManager.default.fileExists(
            atPath: instance.runningDirectory.appending(path: "mods/new.jar").path
        ))
        let snapshots = try await service.snapshots(for: instance)
        #expect(snapshots.count == 2)
        #expect(snapshots.contains { $0.metadata.reason == "恢复前自动备份" })
    }

    @Test func snapshotNeverCapturesSymbolicLinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-snapshot-symlink-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try makeInstance(at: root.appending(path: "minecraft"))
        let service = InstanceSnapshotService(storageRoot: root.appending(path: "snapshots"))
        let outside = root.appending(path: "outside-secret.txt")
        try Data("must-not-be-captured".utf8).write(to: outside)
        let config = instance.runningDirectory.appending(path: "config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: config.appending(path: "outside-link"),
            withDestinationURL: outside
        )

        let snapshot = try await service.createSnapshot(for: instance, reason: "符号链接检查")
        #expect(snapshot.byteSize > 0)
        try FileManager.default.removeItem(at: config)
        try await service.restore(snapshot, to: instance)

        #expect(!FileManager.default.fileExists(atPath: config.appending(path: "outside-link").path))
    }

    private func makeInstance(at minecraftRoot: URL) throws -> MinecraftInstance {
        let directory = MinecraftDirectory(rootURL: minecraftRoot, name: "test")
        let instanceURL = directory.versionsURL.appending(path: "fixture")
        try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
        try Data("""
        {"id":"1.20.1","type":"release","mainClass":"example.Main","libraries":[]}
        """.utf8).write(to: instanceURL.appending(path: "fixture.json"))
        try Data("client".utf8).write(to: instanceURL.appending(path: "fixture.jar"))
        return try #require(MinecraftInstance.create(directory, instanceURL))
    }
}
