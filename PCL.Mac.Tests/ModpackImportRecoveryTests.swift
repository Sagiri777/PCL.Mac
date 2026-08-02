import Foundation
import Testing
@testable import PCL_Mac

struct ModpackImportRecoveryTests {
    @Test func validCompletedDownloadIsReusedWithoutOpeningItsSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: "cached-mod.jar")
        try Data("already downloaded".utf8).write(to: destination)
        let sha1 = try FileHash.compute(destination, algorithm: .sha1)
        let item = DownloadItem(
            URL(string: "https://example.invalid/this-must-not-be-requested.jar")!,
            destination,
            sha1: sha1
        )

        try await MultiFileDownloader(items: [item], replaceMethod: .skip).start()

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(item.destinationIsValid())
    }

    @Test func persistedCheckpointCanBeFoundAfterTheImporterViewIsGone() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appending(path: "Closing Song1.6.5.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("archive identity".utf8).write(to: archiveURL)

        let minecraftRoot = root.appending(path: "minecraft")
        let directory = MinecraftDirectory(rootURL: minecraftRoot, name: "test")
        let instanceURL = directory.versionsURL.appending(path: "Closing Song1.6.5")
        try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
        let manualURL = instanceURL.appending(path: ".PCL_Mac_manual_downloads.json")
        try Data("{}".utf8).write(to: manualURL)

        let checkpoint: [String: Any] = [
            "schemaVersion": 1,
            "sourceFingerprint": "fixture",
            "sourcePath": archiveURL.standardizedFileURL.path,
            "sourceFileSize": 16,
            "sourceModifiedAt": NSNull(),
            "format": "curseforge",
            "instanceID": "Closing Song1.6.5",
            "packName": "Closing Song1.6.5",
            "state": "failed",
            "currentStage": ModpackImportStage.files.rawValue,
            "completedStages": [ModpackImportStage.runtime.rawValue],
            "completedFiles": 246,
            "totalFiles": 266,
            "lastError": "20 个文件需要人工下载",
            "updatedAt": "2026-08-02T07:00:00Z",
            "curseForgeFiles": NSNull()
        ]
        let checkpointURL = instanceURL.appending(path: ".PCL_Mac_import.json")
        try JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys]).write(to: checkpointURL)

        let recovery = try #require(ModpackImporter.recoveryInfo(for: archiveURL, in: directory))
        #expect(recovery.instanceURL.resolvingSymlinksInPath() == instanceURL.resolvingSymlinksInPath())
        #expect(recovery.completedFiles == 246)
        #expect(recovery.totalFiles == 266)
        #expect(recovery.manualDownloadListURL?.resolvingSymlinksInPath() == manualURL.resolvingSymlinksInPath())
        #expect(recovery.summary.contains("246 / 266"))
    }

    @Test func failureNamesTheStageAndPreservedFileCount() throws {
        let recoveryDirectory = URL(fileURLWithPath: "/tmp/pcl-modpack-recovery-fixture")
        let failure = ModpackImportFailure(
            stage: .files,
            reason: "example.jar 下载失败（HTTP 403）",
            completedFiles: 12,
            totalFiles: 20,
            recoveryDirectory: recoveryDirectory,
            manualDownloadListURL: nil
        )

        let description = try #require(failure.errorDescription)
        #expect(failure.stage == .files)
        #expect(description.contains("example.jar"))
        #expect(description.contains("12 / 20"))
        #expect(description.contains("继续重试"))
    }

    @Test func curseForgeProjectKindsRouteToTheirMinecraftFolders() {
        #expect(ModpackImporter.curseForgeDestinationFolder(
            for: URL(string: "https://www.curseforge.com/minecraft/mc-mods/jei")!
        ) == "mods")
        #expect(ModpackImporter.curseForgeDestinationFolder(
            for: URL(string: "https://www.curseforge.com/minecraft/shaders/complementary-reimagined")!
        ) == "shaderpacks")
        #expect(ModpackImporter.curseForgeDestinationFolder(
            for: URL(string: "https://www.curseforge.com/minecraft/texture-packs/fresh-animations")!
        ) == "resourcepacks")
    }

    @Test func resumePayloadLivesBesideItsPartialDestination() {
        let destination = URL(fileURLWithPath: "/tmp/test-instance/mods/example.jar")
        let resumeURL = SingleFileDownloader.resumeDataURL(for: destination)
        #expect(resumeURL.deletingLastPathComponent() == destination.deletingLastPathComponent())
        #expect(resumeURL.lastPathComponent == ".example.jar.pclresume")
    }

    @Test func resumePayloadIsNeverAppliedToADifferentMirrorURL() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "mods/example.jar")
        let firstSource = URL(string: "https://edge.forgecdn.net/files/example.jar")!
        let fallbackSource = URL(string: "https://mod.mcimirror.top/files/example.jar")!
        let opaquePayload = Data("opaque URLSession resume fixture".utf8)

        SingleFileDownloader.persistResumeData(opaquePayload, for: destination, sourceURL: firstSource)
        #expect(SingleFileDownloader.loadResumeData(for: destination, sourceURL: firstSource) == opaquePayload)
        #expect(SingleFileDownloader.loadResumeData(for: destination, sourceURL: fallbackSource) == nil)
        #expect(!FileManager.default.fileExists(atPath: SingleFileDownloader.resumeDataURL(for: destination).path))
    }

    @Test @MainActor func recoverableInstanceIsNotListedAsLaunchable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = MinecraftDirectory(rootURL: root, name: "test")
        let instanceURL = directory.versionsURL.appending(path: "unfinished")
        try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: instanceURL.appending(path: "unfinished.json"))
        try Data("{}".utf8).write(to: instanceURL.appending(path: ".PCL_Mac_import.json"))

        let instances: [InstanceInfo] = await withCheckedContinuation { continuation in
            directory.loadInnerInstances { continuation.resume(returning: $0) }
        }

        #expect(instances.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "pcl-modpack-recovery-tests-\(UUID().uuidString)")
    }
}
