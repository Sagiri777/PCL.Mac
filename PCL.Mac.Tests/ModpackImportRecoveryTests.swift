import Foundation
import Testing
import ZIPFoundation
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
        let legacyRecord = OfficialWebDownloadRecord(
            projectID: 238222,
            fileID: 1234567,
            fileName: "example.jar",
            destination: "mods/example.jar",
            expectedSHA1: String(repeating: "a", count: 40),
            curseForgePage: URL(string: "https://www.curseforge.com/minecraft/mc-mods/example")
        )
        try OfficialWebDownloadManifest(files: [legacyRecord]).write(to: manualURL)

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
        #expect(recovery.officialWebDownloadManifestURL?.resolvingSymlinksInPath() == manualURL.resolvingSymlinksInPath())
        #expect(recovery.summary.contains("246 / 266"))

        let plan = try ModpackImporter.officialWebDownloadPlan(
            queueURL: manualURL,
            instanceRoot: instanceURL
        )
        let upgradedURL = instanceURL.appending(path: ".PCL_Mac_official_web_downloads.json")
        #expect(plan.groups.count == 1)
        #expect(FileManager.default.fileExists(atPath: upgradedURL.path))
        #expect(!FileManager.default.fileExists(atPath: manualURL.path))
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

    @Test func exporterSkipsSymlinkedFilesOutsideTheInstanceRoot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let minecraftRoot = root.appending(path: "minecraft")
        let instanceURL = minecraftRoot.appending(path: "versions/test")
        let modsURL = instanceURL.appending(path: "mods")
        let sharedModsURL = minecraftRoot.appending(path: "mods")
        try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedModsURL, withIntermediateDirectories: true)

        let manifest = """
        {"id":"1.20.1","type":"release","mainClass":"net.minecraft.client.Main","libraries":[]}
        """
        try Data(manifest.utf8).write(to: instanceURL.appending(path: "test.json"))
        try Data("inside".utf8).write(to: modsURL.appending(path: "inside.jar"))
        try Data("shared".utf8).write(to: sharedModsURL.appending(path: "other-instance.jar"))
        let outsideURL = root.appending(path: "outside.jar")
        try Data("outside".utf8).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: modsURL.appending(path: "linked.jar"),
            withDestinationURL: outsideURL
        )

        let directory = MinecraftDirectory(rootURL: minecraftRoot, name: "test")
        let instance = try #require(MinecraftInstance.create(directory, instanceURL))
        let destination = root.appending(path: "export.mrpack")
        var options = ModpackExporter.Options(name: "test")
        options.includeConfig = false
        options.includeVersionJSON = false
        try await ModpackExporter.export(instance: instance, options: options, to: destination)

        let archive = try Archive(url: destination, accessMode: .read)
        let paths = Set(archive.map(\.path))
        #expect(paths.contains("overrides/mods/inside.jar"))
        #expect(!paths.contains("overrides/mods/linked.jar"))
        #expect(!paths.contains("overrides/mods/other-instance.jar"))
    }

    @Test func exporterIncludesOnlyMatchingShaderPackSettings() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let minecraftRoot = root.appending(path: "minecraft")
        let instanceURL = minecraftRoot.appending(path: "versions/test")
        let shaderPacksURL = instanceURL.appending(path: "shaderpacks")
        try FileManager.default.createDirectory(at: shaderPacksURL, withIntermediateDirectories: true)

        let manifest = """
        {"id":"1.20.1","type":"release","mainClass":"net.minecraft.client.Main","libraries":[]}
        """
        try Data(manifest.utf8).write(to: instanceURL.appending(path: "test.json"))
        try Data("zip".utf8).write(to: shaderPacksURL.appending(path: "cinematic.zip"))
        try Data("zip-settings".utf8).write(to: shaderPacksURL.appending(path: "cinematic.zip.txt"))
        let folderPackURL = shaderPacksURL.appending(path: "folder-pack")
        try FileManager.default.createDirectory(at: folderPackURL, withIntermediateDirectories: true)
        try Data("pack-content".utf8).write(to: folderPackURL.appending(path: "shaders.properties"))
        try Data("folder-settings".utf8).write(to: shaderPacksURL.appending(path: "folder-pack.txt"))
        try Data("orphan".utf8).write(to: shaderPacksURL.appending(path: "orphan.txt"))

        let directory = MinecraftDirectory(rootURL: minecraftRoot, name: "test")
        let instance = try #require(MinecraftInstance.create(directory, instanceURL))
        var options = ModpackExporter.Options(name: "test")
        options.includeMods = false
        options.includeConfig = false
        options.includeShaderPacks = true
        options.includeVersionJSON = false

        let withSettingsURL = root.appending(path: "with-settings.mrpack")
        try await ModpackExporter.export(instance: instance, options: options, to: withSettingsURL)
        let withSettings = try Archive(url: withSettingsURL, accessMode: .read)
        let withSettingsPaths = Set(withSettings.map(\.path))
        #expect(withSettingsPaths.contains("overrides/shaderpacks/cinematic.zip"))
        #expect(withSettingsPaths.contains("overrides/shaderpacks/cinematic.zip.txt"))
        #expect(withSettingsPaths.contains("overrides/shaderpacks/folder-pack/shaders.properties"))
        #expect(withSettingsPaths.contains("overrides/shaderpacks/folder-pack.txt"))
        #expect(!withSettingsPaths.contains("overrides/shaderpacks/orphan.txt"))

        options.includeShaderPackSettings = false
        let withoutSettingsURL = root.appending(path: "without-settings.mrpack")
        try await ModpackExporter.export(instance: instance, options: options, to: withoutSettingsURL)
        let withoutSettings = try Archive(url: withoutSettingsURL, accessMode: .read)
        let withoutSettingsPaths = Set(withoutSettings.map(\.path))
        #expect(withoutSettingsPaths.contains("overrides/shaderpacks/cinematic.zip"))
        #expect(withoutSettingsPaths.contains("overrides/shaderpacks/folder-pack/shaders.properties"))
        #expect(!withoutSettingsPaths.contains("overrides/shaderpacks/cinematic.zip.txt"))
        #expect(!withoutSettingsPaths.contains("overrides/shaderpacks/folder-pack.txt"))
        #expect(!withoutSettingsPaths.contains("overrides/shaderpacks/orphan.txt"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "pcl-modpack-recovery-tests-\(UUID().uuidString)")
    }
}
