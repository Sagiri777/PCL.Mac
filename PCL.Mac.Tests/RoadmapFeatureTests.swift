import Foundation
import Testing
@testable import PCL_Mac

struct RoadmapFeatureTests {
    @Test func modUpdatePlannerOnlyOffersNewerVersionsInTheCurrentChannel() throws {
        let now = Date()
        let newestBeta = version(id: "beta-new", type: "beta", date: now.addingTimeInterval(300))
        let newestRelease = version(id: "release-new", type: "release", date: now.addingTimeInterval(200))
        let current = version(id: "current", type: "release", date: now.addingTimeInterval(100))
        let older = version(id: "older", type: "release", date: now)

        let selected = try #require(ModUpdatePlanner.latestCompatibleVersion(
            currentVersionID: current.versionId,
            currentVersionType: "release",
            versions: [older, current, newestBeta, newestRelease]
        ))
        #expect(selected.versionId == newestRelease.versionId)
        #expect(ModUpdatePlanner.latestCompatibleVersion(
            currentVersionID: newestRelease.versionId,
            currentVersionType: "release",
            versions: [older, current, newestRelease]
        ) == nil)
    }

    @Test func serverStatusPacketDecodesMotdPlayersAndLatency() throws {
        let json = Data("""
        {"version":{"name":"1.21.8"},"players":{"online":4,"max":20},"description":{"text":"Glass ","extra":[{"text":"Server"}]}}
        """.utf8)
        var packet = Data([0x00])
        packet.append(varInt(json.count))
        packet.append(json)

        let status = try MinecraftServerPinger.decodeStatus(packet, latencyMilliseconds: 42)
        #expect(status.versionName == "1.21.8")
        #expect(status.motd == "Glass Server")
        #expect(status.onlinePlayers == 4)
        #expect(status.maximumPlayers == 20)
        #expect(status.latencyMilliseconds == 42)
    }

    @Test func multiplayerLaunchArgumentsContainTheBoundServer() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-multiplayer-launch-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = MinecraftDirectory(rootURL: root, name: "test")
        let instanceURL = directory.versionsURL.appending(path: "fixture")
        try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
        try Data("""
        {"id":"1.20.1","type":"release","mainClass":"example.Main","libraries":[],"arguments":{"game":[],"jvm":[]}}
        """.utf8).write(to: instanceURL.appending(path: "fixture.json"))
        try Data("client".utf8).write(to: instanceURL.appending(path: "fixture.jar"))
        let instance = try #require(MinecraftInstance.create(directory, instanceURL))
        let launcher = try #require(MinecraftLauncher(instance))
        let options = LaunchOptions()
        options.serverAddress = "play.example.net"
        options.serverPort = 25570

        let arguments = launcher.buildGameArguments(options)
        #expect(arguments.suffix(4) == ["--server", "play.example.net", "--port", "25570"])
    }

    @Test func javaInstallTransactionPreservesTheOldRuntimeWhenValidationFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-java-transaction-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidSource = root.appending(path: "invalid-source")
        let destination = root.appending(path: "zulu-21.jre")
        try FileManager.default.createDirectory(at: invalidSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appending(path: "keep-me")
        try Data("old-runtime".utf8).write(to: marker)

        #expect(throws: Error.self) {
            try JavaInstallTask.installAtomically(from: invalidSource, to: destination)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old-runtime")
    }

    @Test func javaInstallTransactionCommitsAValidatedRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-java-commit-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let executable = source.appending(path: "Contents/Home/bin/java")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let destination = root.appending(path: "installed/zulu-21.jre")

        try JavaInstallTask.installAtomically(from: source, to: destination)

        #expect(FileManager.default.isExecutableFile(
            atPath: destination.appending(path: "Contents/Home/bin/java").path
        ))
    }

    private func version(id: String, type: String, date: Date) -> ProjectVersion {
        ProjectVersion(
            versionId: id,
            projectType: .mod,
            projectId: "fixture-project",
            name: id,
            versionNumber: id,
            type: type,
            downloads: 0,
            updateDate: date,
            gameVersions: [.init(displayName: "1.21.8")],
            loaders: [.fabric],
            dependencies: [],
            downloadURL: URL(string: "https://example.invalid/\(id).jar")!
        )
    }

    private func varInt(_ value: Int) -> Data {
        var value = UInt32(value)
        var result = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }
}
