import Foundation
import Testing
@testable import PCL_Mac

struct ClientManifestNativeTests {
    @Test func keepsClasspathAndNativeClassifierAsIndependentRecords() throws {
        let manifest = try parseManifest(libraries: [combinedLibrary()])

        #expect(manifest.libraries.count == 2)
        #expect(manifest.libraries.filter { $0.role == .classpath }.count == 1)
        #expect(manifest.libraries.filter { $0.role == .native }.count == 1)
        #expect(manifest.getNeededLibraries(for: .arm64).count == 1)
        #expect(manifest.getNeededNatives(for: .arm64).count == 1)

        ClientManifest.deduplicateLibraries(manifest)
        #expect(manifest.libraries.count == 2)

        let native = try #require(manifest.libraries.first { $0.role == .native })
        let mirrorURL = try #require(BMCLAPIDownloadSource.shared.getLibraryURL(native))
        #expect(mirrorURL.path.hasSuffix("/example/native-lib/1.0/native-lib-1.0-natives-osx.jar"))
    }

    @Test func evaluatesMojangRulesInOrderAndForTheTargetProcessArchitecture() throws {
        var ordered = combinedLibrary()
        ordered["rules"] = [
            ["action": "allow", "os": ["name": "osx"]],
            ["action": "disallow", "os": ["name": "osx"]]
        ]
        var armOnly = artifactOnlyLibrary(name: "example:arm-only:1.0")
        armOnly["rules"] = [
            ["action": "allow", "os": ["name": "osx", "arch": "^(arm64|aarch64)$"]]
        ]
        let manifest = try parseManifest(libraries: [ordered, armOnly])

        #expect(manifest.getAllowedLibraries(for: .arm64).map(\.artifactId) == ["arm-only"])
        #expect(manifest.getAllowedLibraries(for: .x64).isEmpty)
    }

    @Test func mapsMinecraft112ObjCBridgeForBothClasspathAndNativeExtraction() throws {
        let bridge: [String: Any] = [
            "name": "ca.weblite:java-objc-bridge:1.0.0",
            "downloads": [
                "artifact": [
                    "path": "ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0.jar",
                    "url": "https://libraries.minecraft.net/ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0.jar"
                ],
                "classifiers": [
                    "natives-osx": [
                        "path": "ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0-natives-osx.jar",
                        "url": "https://libraries.minecraft.net/ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0-natives-osx.jar"
                    ]
                ]
            ],
            "natives": ["osx": "natives-osx"],
            "rules": [["action": "allow", "os": ["name": "osx"]]]
        ]
        let manifest = try parseManifest(libraries: [bridge])

        ArtifactVersionMapper.map(manifest, arch: .arm64)

        let classpath = try #require(manifest.getNeededLibraries(for: .arm64).first)
        let native = try #require(manifest.getNeededNatives(for: .arm64).first)
        let expectedPath = "org/glavo/hmcl/mmachina/java-objc-bridge/1.1.0-mmachina.1/java-objc-bridge-1.1.0-mmachina.1.jar"
        #expect(classpath.role == .classpath)
        #expect(classpath.name == "org.glavo.hmcl.mmachina:java-objc-bridge:1.1.0-mmachina.1")
        #expect(classpath.artifact?.path == expectedPath)
        #expect(native.0.role == .native)
        #expect(native.1.path == expectedPath)
    }

    @Test func argumentRulesUseTheActualGameProcessArchitecture() throws {
        let arguments: [String: Any] = [
            "game": [],
            "jvm": [
                [
                    "rules": [["action": "allow", "os": ["name": "osx", "arch": "^(arm64|aarch64)$"]]],
                    "value": "-Dnative.arch=arm64"
                ],
                [
                    "rules": [["action": "allow", "os": ["name": "osx", "arch": "^(x86_64|amd64)$"]]],
                    "value": "-Dnative.arch=x86_64"
                ]
            ]
        ]
        let manifest = try parseManifest(libraries: [], arguments: arguments)
        let parsedArguments = try #require(manifest.arguments)

        #expect(parsedArguments.getAllowedJVMArguments(targetArchitecture: .arm64) == ["-Dnative.arch=arm64"])
        #expect(parsedArguments.getAllowedJVMArguments(targetArchitecture: .x64) == ["-Dnative.arch=x86_64"])
    }

    // MARK: - Fixtures

    private func parseManifest(
        libraries: [[String: Any]],
        arguments: [String: Any]? = nil
    ) throws -> ClientManifest {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-manifest-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "version.json")
        var object: [String: Any] = [
            "id": "test",
            "mainClass": "example.Main",
            "type": "release",
            "assets": "legacy",
            "libraries": libraries
        ]
        if let arguments { object["arguments"] = arguments }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        return try #require(try ClientManifest.parse(url: url))
    }

    private func combinedLibrary() -> [String: Any] {
        [
            "name": "example:native-lib:1.0",
            "downloads": [
                "artifact": [
                    "path": "example/native-lib/1.0/native-lib-1.0.jar",
                    "url": "https://libraries.minecraft.net/example/native-lib/1.0/native-lib-1.0.jar"
                ],
                "classifiers": [
                    "natives-osx": [
                        "path": "example/native-lib/1.0/native-lib-1.0-natives-osx.jar",
                        "url": "https://libraries.minecraft.net/example/native-lib/1.0/native-lib-1.0-natives-osx.jar"
                    ]
                ]
            ],
            "natives": ["osx": "natives-osx"]
        ]
    }

    private func artifactOnlyLibrary(name: String) -> [String: Any] {
        let parts = name.split(separator: ":")
        let path = "\(parts[0])/\(parts[1])/\(parts[2])/\(parts[1])-\(parts[2]).jar"
        return [
            "name": name,
            "downloads": [
                "artifact": [
                    "path": path,
                    "url": "https://libraries.minecraft.net/\(path)"
                ]
            ]
        ]
    }
}
