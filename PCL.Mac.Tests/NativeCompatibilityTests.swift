import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import PCL_Mac

struct NativeCompatibilityTests {
    @Test func independentlyDisablesAndRestoresConfirmedWindowsOnlyMods() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let mods = root.appending(path: "mods")

        let inputMethodBlocker = mods.appending(path: "InputMethodBlocker-1.0.jar")
        try makeJar(at: inputMethodBlocker, entries: [
            "fabric.mod.json": fabricMetadata(
                id: "inputmethodblocker",
                name: "Input Method Blocker",
                version: "1.0"
            ),
            "com/github/skystardust/inputmethodblocker/inputmethodblocker.class": Data("placeholder".utf8),
            "inputmethodblocker-native-x64.dll": peBinary(),
            "inputmethodblocker-native-x86.dll": peBinary(machine: 0x014C)
        ])

        let structural = mods.appending(path: "mandatory-windows-native.jar")
        try makeJar(at: structural, entries: [
            "fabric.mod.json": fabricMetadata(
                id: "mandatorynative",
                name: "Mandatory Native",
                version: "2.0",
                entrypoint: "example.WindowsEntrypoint"
            ),
            "example/WindowsEntrypoint.class": Data(
                "java/lang/System\0loadLibrary\0mandatory-native.dll".utf8
            ),
            "mandatory-native.dll": peBinary()
        ])

        let service = NativeCompatibilityService()
        let scanned = try await service.analyze(instanceURL: root, targetArchitecture: .arm64)
        #expect(scanned.issues.count == 2)
        #expect(scanned.issues.allSatisfy { $0.autoFixEligible && $0.action == .disableMod })

        let fixed = try await service.applyTrustedFixes(report: scanned)
        #expect(fixed.disabledCount == 2)
        #expect(!FileManager.default.fileExists(atPath: inputMethodBlocker.path))
        #expect(!FileManager.default.fileExists(atPath: structural.path))
        #expect(FileManager.default.fileExists(atPath: inputMethodBlocker.path + ".disabled"))
        #expect(FileManager.default.fileExists(atPath: structural.path + ".disabled"))

        let restoredIssue = try #require(fixed.issues.first { $0.relativePath.contains("InputMethodBlocker") })
        try await service.restore(issueID: restoredIssue.id, instanceURL: root)

        #expect(FileManager.default.fileExists(atPath: inputMethodBlocker.path))
        #expect(!FileManager.default.fileExists(atPath: inputMethodBlocker.path + ".disabled"))
        #expect(!FileManager.default.fileExists(atPath: structural.path))
        #expect(FileManager.default.fileExists(atPath: structural.path + ".disabled"))

        let rescanned = try await service.analyze(instanceURL: root, targetArchitecture: .arm64)
        let restoredOnRescan = try #require(rescanned.issues.first { $0.id == restoredIssue.id })
        #expect(restoredOnRescan.isUserRestored)
        #expect(!restoredOnRescan.needsAttention)
        let reapplied = try await service.applyTrustedFixes(report: rescanned)
        #expect(reapplied.issues.first { $0.id == restoredIssue.id }?.isApplied == false)
        #expect(FileManager.default.fileExists(atPath: inputMethodBlocker.path))

        let stateData = try Data(contentsOf: root.appending(path: NativeCompatibilityService.stateFileName))
        let state = try #require(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        let fixes = try #require(state["appliedFixes"] as? [[String: Any]])
        #expect(fixes.contains { ($0["issueID"] as? String) == restoredIssue.id && ($0["status"] as? String) == "restored" })

        try await service.reenableAutomaticFix(issueID: restoredIssue.id, instanceURL: root)
        let enabledAgain = try await service.analyze(instanceURL: root, targetArchitecture: .arm64)
        _ = try await service.applyTrustedFixes(report: enabledAgain)
        #expect(!FileManager.default.fileExists(atPath: inputMethodBlocker.path))
        #expect(FileManager.default.fileExists(atPath: inputMethodBlocker.path + ".disabled"))
    }

    @Test func dllPresenceAloneNeverDisablesACrossPlatformOrOptionalMod() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let mods = root.appending(path: "mods")

        let optional = mods.appending(path: "optional-windows-integration.jar")
        try makeJar(at: optional, entries: [
            "fabric.mod.json": fabricMetadata(
                id: "optionalnative",
                name: "Optional Native",
                version: "1.0",
                entrypoint: "example.OptionalEntrypoint"
            ),
            "example/OptionalEntrypoint.class": Data(
                "java/lang/System\0loadLibrary\0optional.dll\0os.name\0darwin".utf8
            ),
            "optional.dll": peBinary()
        ])

        let unknown = mods.appending(path: "unknown-dll-only.jar")
        try makeJar(at: unknown, entries: [
            "fabric.mod.json": fabricMetadata(id: "unknowndll", name: "Unknown DLL", version: "1.0"),
            "unknown.dll": peBinary()
        ])

        let crossPlatform = mods.appending(path: "cross-platform.jar")
        try makeJar(at: crossPlatform, entries: [
            "fabric.mod.json": fabricMetadata(id: "crossplatform", name: "Cross Platform", version: "1.0"),
            "windows/cross.dll": peBinary(),
            "macos/libcross.dylib": machOArm64Binary()
        ])

        // Even a filename/structure known by an older rule must not be
        // disabled if the artifact now carries a compatible macOS payload.
        let evolvedKnownMod = mods.appending(path: "InputMethodBlocker-cross-platform.jar")
        try makeJar(at: evolvedKnownMod, entries: [
            "fabric.mod.json": fabricMetadata(id: "inputmethodblocker", name: "Input Method Blocker", version: "future"),
            "com/github/skystardust/inputmethodblocker/inputmethodblocker.class": Data("placeholder".utf8),
            "inputmethodblocker-native-x64.dll": peBinary(),
            "inputmethodblocker-native-x86.dll": peBinary(machine: 0x014C),
            "libinputmethodblocker.dylib": machOArm64Binary()
        ])

        // A corrupt JAR is intentionally present to prove one bad archive does
        // not abort analysis of the rest of the instance.
        try Data("not a zip".utf8).write(to: mods.appending(path: "broken.jar"))

        let service = NativeCompatibilityService()
        let scanned = try await service.analyze(instanceURL: root, targetArchitecture: .arm64)
        #expect(scanned.issues.count == 2)
        #expect(scanned.issues.allSatisfy { !$0.autoFixEligible && $0.action == .manualOnly })
        #expect(scanned.issues.contains { $0.modID == "optionalnative" })
        #expect(scanned.issues.contains { $0.modID == "unknowndll" })
        #expect(!scanned.issues.contains { $0.modID == "crossplatform" })
        #expect(!scanned.issues.contains { $0.modVersion == "future" })

        let fixed = try await service.applyTrustedFixes(report: scanned)
        #expect(fixed.disabledCount == 0)
        #expect(FileManager.default.fileExists(atPath: optional.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(FileManager.default.fileExists(atPath: crossPlatform.path))
        #expect(FileManager.default.fileExists(atPath: evolvedKnownMod.path))
    }

    @Test func nearbyCrashEvidencePromotesAnUnknownDllModOnTheNextScan() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let mods = root.appending(path: "mods")
        let logs = root.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let jar = mods.appending(path: "crash-linked.jar")
        try makeJar(at: jar, entries: [
            "fabric.mod.json": fabricMetadata(id: "crashlinked", name: "Crash Linked", version: "1.0"),
            "crash-linked-native-x64.dll": peBinary()
        ])

        let service = NativeCompatibilityService()
        let first = try await service.analyze(instanceURL: root, targetArchitecture: .arm64)
        #expect(first.issues.first?.autoFixEligible == false)

        let crash = """
        [main/ERROR] java.lang.UnsatisfiedLinkError: no crash-linked-native-x64.dll in java.library.path
            at crashlinked.NativeLoader.load(NativeLoader.java:12)
        """
        try Data(crash.utf8).write(to: logs.appending(path: "latest.log"))

        let attributed = try await service.analyze(instanceURL: root, targetArchitecture: .arm64)
        let issue = try #require(attributed.issues.first)
        #expect(issue.autoFixEligible)
        #expect(issue.confidence == .certain)
        #expect(issue.evidence.contains { $0.kind == .crashLog })

        let fixed = try await service.applyTrustedFixes(report: attributed)
        #expect(fixed.disabledCount == 1)
        #expect(FileManager.default.fileExists(atPath: jar.path + ".disabled"))
    }

    @Test func officialSupportStatementAndExactArtifactIdentityConfirmWindowsOnlyStatus() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let jar = root.appending(path: "mods/official-windows-only.jar")
        try makeJar(at: jar, entries: [
            "fabric.mod.json": fabricMetadata(
                id: "officialwindows",
                name: "Official Windows Integration",
                version: "3.2.1"
            ),
            "official.dll": peBinary()
        ])
        let artifactHash = sha256(try Data(contentsOf: jar))
        let officialRule = NativeCompatibilityRule(
            id: "official.officialwindows.3.2.1",
            modIDs: ["officialwindows"],
            versions: ["3.2.1"],
            sha256s: [artifactHash],
            reason: "上游发布说明明确声明该版本仅支持 Windows。",
            evidenceKind: .officialMetadata,
            evidenceSource: URL(string: "https://example.invalid/official-release")
        )
        let service = NativeCompatibilityService(additionalRules: [officialRule])

        let report = try await service.analyze(instanceURL: root, targetArchitecture: .arm64)
        let issue = try #require(report.issues.first)
        #expect(issue.ruleID == officialRule.id)
        #expect(issue.autoFixEligible)
        #expect(issue.evidence.contains { $0.kind == .officialMetadata })
    }

    @Test func communityCandidatesAreFilteredAndRankedWithoutSelectingOne() {
        let context = ReplacementCompatibilityContext(
            minecraftVersion: "1.20.1",
            loader: "fabric",
            installedModAPIs: ["fabric-api"],
            architecture: "arm64"
        )
        let trusted = candidate(
            id: "trusted",
            name: "Trusted",
            tier: .trustedCommunity,
            score: .init(
                sourceAndUpstream: 90,
                reproducibility: 90,
                ecosystemValidation: 80,
                maintenanceAndSecurity: 80,
                licenseCompleteness: 100
            )
        )
        let official = candidate(
            id: "official",
            name: "Official",
            tier: .official,
            score: .init(
                sourceAndUpstream: 55,
                reproducibility: 55,
                ecosystemValidation: 55,
                maintenanceAndSecurity: 55,
                licenseCompleteness: 55
            )
        )
        let lower = candidate(
            id: "lower",
            name: "Lower",
            tier: .trustedCommunity,
            score: .init(
                sourceAndUpstream: 60,
                reproducibility: 60,
                ecosystemValidation: 60,
                maintenanceAndSecurity: 60,
                licenseCompleteness: 60
            )
        )
        let wrongLoader = candidate(
            id: "forge-only",
            name: "Forge Only",
            tier: .trustedCommunity,
            score: .init(
                sourceAndUpstream: 100,
                reproducibility: 100,
                ecosystemValidation: 100,
                maintenanceAndSecurity: 100,
                licenseCompleteness: 100
            ),
            loaders: ["forge"]
        )
        let missingBuildEvidence = candidate(
            id: "unverifiable",
            name: "Unverifiable",
            tier: .trustedCommunity,
            score: lower.trustScore,
            hasPublicBuild: false
        )

        let ranked = ReplacementCandidate.ranked(
            [lower, wrongLoader, missingBuildEvidence, trusted, official],
            compatibleWith: context
        )
        #expect(ranked.map(\.id) == ["official", "trusted", "lower"])
        // Ranking returns choices only; there is deliberately no selected ID
        // or implicit installation side effect in the result.
        #expect(ranked.allSatisfy { $0.downloadURL.isFileURL })
    }

    @Test func trustScoreTiesUseTheSpecifiedDeterministicBreakers() {
        let context = ReplacementCompatibilityContext(
            minecraftVersion: "1.20.1",
            loader: "fabric",
            installedModAPIs: ["fabric-api"],
            architecture: "arm64"
        )
        let strongerBuild = candidate(
            id: "stronger-build",
            name: "Zeta",
            tier: .trustedCommunity,
            score: .init(
                sourceAndUpstream: 80,
                reproducibility: 100,
                ecosystemValidation: 80,
                maintenanceAndSecurity: 80,
                licenseCompleteness: 80
            )
        )
        let strongerUpstreamButWeakerBuild = candidate(
            id: "weaker-build",
            name: "Alpha",
            tier: .trustedCommunity,
            score: .init(
                sourceAndUpstream: 90,
                reproducibility: 86,
                ecosystemValidation: 80,
                maintenanceAndSecurity: 80,
                licenseCompleteness: 80
            )
        )
        #expect(strongerBuild.trustScore.total == strongerUpstreamButWeakerBuild.trustScore.total)

        let ranked = ReplacementCandidate.ranked(
            [strongerUpstreamButWeakerBuild, strongerBuild],
            compatibleWith: context
        )
        #expect(ranked.map(\.id) == ["stronger-build", "weaker-build"])
    }

    @Test func communityArtifactInstallsOnlyAfterExplicitSelectionAndHashVerification() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "mods/community-original.jar")
        try Data("original".utf8).write(to: original)
        let replacementSource = root.appending(path: "candidate-source.jar")
        try Data("replacement".utf8).write(to: replacementSource)

        let originalHash = sha256(try Data(contentsOf: original))
        let validCandidate = candidate(
            id: "community-choice",
            name: "Community Choice",
            tier: .trustedCommunity,
            score: .init(
                sourceAndUpstream: 80,
                reproducibility: 90,
                ecosystemValidation: 75,
                maintenanceAndSecurity: 85,
                licenseCompleteness: 100
            ),
            downloadURL: replacementSource,
            sha256: sha256(try Data(contentsOf: replacementSource))
        )
        let issue = syntheticDisableIssue(
            relativePath: "mods/community-original.jar",
            sha256: originalHash,
            candidates: [validCandidate]
        )
        let service = NativeCompatibilityService()
        let report = NativeCompatibilityReport(
            instancePath: root.path,
            targetArchitecture: "arm64",
            issues: [issue]
        )

        let fixed = try await service.applyTrustedFixes(report: report)
        #expect(fixed.disabledCount == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "mods/community-choice.jar").path))

        try await service.installReplacement(validCandidate, for: issue.id, instanceURL: root)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "mods/community-choice.jar").path))

        try await service.restore(issueID: issue.id, instanceURL: root)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "mods/community-choice.jar").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "mods/community-choice.jar.disabled").path))
    }

    @Test func hashMismatchNeverEnablesAReplacementAndKeepsOriginalRecoverable() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "mods/hash-original.jar")
        try Data("original".utf8).write(to: original)
        let replacementSource = root.appending(path: "bad-source.jar")
        try Data("tampered".utf8).write(to: replacementSource)

        let badCandidate = candidate(
            id: "bad-hash",
            name: "Bad Hash",
            tier: .trustedCommunity,
            score: .init(
                sourceAndUpstream: 80,
                reproducibility: 90,
                ecosystemValidation: 75,
                maintenanceAndSecurity: 85,
                licenseCompleteness: 100
            ),
            downloadURL: replacementSource,
            sha256: String(repeating: "a", count: 64)
        )
        let issue = syntheticDisableIssue(
            relativePath: "mods/hash-original.jar",
            sha256: sha256(try Data(contentsOf: original)),
            candidates: [badCandidate]
        )
        let service = NativeCompatibilityService()
        let report = NativeCompatibilityReport(
            instancePath: root.path,
            targetArchitecture: "arm64",
            issues: [issue]
        )
        _ = try await service.applyTrustedFixes(report: report)

        var rejected = false
        do {
            try await service.installReplacement(badCandidate, for: issue.id, instanceURL: root)
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "mods/bad-hash.jar").path))
        #expect(FileManager.default.fileExists(atPath: original.path + ".disabled"))

        try await service.restore(issueID: issue.id, instanceURL: root)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func exactSameReleaseOfficialArtifactMayInstallAutomatically() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "mods/official-original.jar")
        try Data("original".utf8).write(to: original)
        let officialSource = root.appending(path: "official-source.jar")
        try Data("official mac artifact".utf8).write(to: officialSource)

        let official = candidate(
            id: "official-mac",
            name: "Official Mac Artifact",
            version: "1.0",
            tier: .official,
            score: .init(
                sourceAndUpstream: 100,
                reproducibility: 100,
                ecosystemValidation: 100,
                maintenanceAndSecurity: 100,
                licenseCompleteness: 100
            ),
            delivery: .officialSameReleaseArtifact,
            downloadURL: officialSource,
            sha256: sha256(try Data(contentsOf: officialSource))
        )
        let issue = syntheticDisableIssue(
            relativePath: "mods/official-original.jar",
            sha256: sha256(try Data(contentsOf: original)),
            candidates: [official],
            modVersion: "1.0"
        )
        let service = NativeCompatibilityService()
        let report = NativeCompatibilityReport(
            instancePath: root.path,
            targetArchitecture: "arm64",
            issues: [issue]
        )

        let fixed = try await service.applyTrustedFixes(report: report)
        #expect(fixed.issues.first?.installedReplacementCandidateID == official.id)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "mods/official-mac.jar").path))
        #expect(FileManager.default.fileExists(atPath: original.path + ".disabled"))
    }

    @Test func officialSameReleaseDependencyCompletesWithoutDisablingTheOriginalMod() async throws {
        let root = try temporaryInstance()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "mods/cross-platform-original.jar")
        try Data("original mod bytecode".utf8).write(to: original)
        let officialSource = root.appending(path: "native-source.jar")
        try Data("official native dependency".utf8).write(to: officialSource)

        let official = candidate(
            id: "official-native-dependency",
            name: "Official Native Dependency",
            version: "1.0",
            tier: .official,
            score: .init(
                sourceAndUpstream: 100,
                reproducibility: 100,
                ecosystemValidation: 100,
                maintenanceAndSecurity: 100,
                licenseCompleteness: 100
            ),
            delivery: .officialSameReleaseArtifact,
            downloadURL: officialSource,
            sha256: sha256(try Data(contentsOf: officialSource))
        )
        let issue = syntheticDisableIssue(
            relativePath: "mods/cross-platform-original.jar",
            sha256: sha256(try Data(contentsOf: original)),
            candidates: [official],
            action: .installOfficialArtifact
        )
        let service = NativeCompatibilityService()
        let report = NativeCompatibilityReport(
            instancePath: root.path,
            targetArchitecture: "arm64",
            issues: [issue]
        )

        let fixed = try await service.applyTrustedFixes(report: report)
        let installed = root.appending(path: "mods/official-native-dependency.jar")
        #expect(fixed.disabledCount == 0)
        #expect(fixed.installedOfficialArtifactCount == 1)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: original.path + ".disabled"))
        #expect(FileManager.default.fileExists(atPath: installed.path))

        try await service.restore(issueID: issue.id, instanceURL: root)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        #expect(FileManager.default.fileExists(atPath: installed.path + ".disabled"))

        let reapplied = try await service.applyTrustedFixes(report: report)
        #expect(reapplied.installedOfficialArtifactCount == 0)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }

    @Test func crashAnalyzerReportsWindowsDllAndArchitectureMismatch() {
        let log = """
        java.lang.UnsatisfiedLinkError: inputmethodblocker-native-x64.dll: mach-o, but wrong architecture
        have 'x86_64', need 'arm64'
        """
        let report = MinecraftCrashHandler.analyze(
            logText: log,
            hsErr: "",
            mcCrash: "",
            mcLog: log
        )
        #expect(report.primaryReasons.contains(.windowsNativeLibrary))
        #expect(report.primaryReasons.contains(.nativeArchitectureMismatch))
        #expect(report.suspectedMods.contains("inputmethodblocker-native-x64.dll"))
    }

    // MARK: - Fixtures

    private func temporaryInstance() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pcl-native-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "mods"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeJar(at url: URL, entries: [String: Data]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return start < end ? data.subdata(in: start..<end) : Data()
            }
        }
    }

    private func fabricMetadata(
        id: String,
        name: String,
        version: String,
        entrypoint: String? = nil
    ) -> Data {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "name": name,
            "version": version,
            "description": "test fixture"
        ]
        if let entrypoint {
            object["entrypoints"] = ["main": [entrypoint]]
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func peBinary(machine: UInt16 = 0x8664) -> Data {
        var data = Data(repeating: 0, count: 512)
        data[0] = 0x4D
        data[1] = 0x5A
        data[0x3C] = 0x80
        data[0x80] = 0x50
        data[0x81] = 0x45
        data[0x84] = UInt8(machine & 0xFF)
        data[0x85] = UInt8(machine >> 8)
        return data
    }

    private func machOArm64Binary() -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01] + Array(repeating: 0, count: 64))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func candidate(
        id: String,
        name: String,
        version: String = "1.0",
        tier: ReplacementTrustTier,
        score: ReplacementTrustScore,
        loaders: [String] = ["fabric"],
        hasPublicBuild: Bool = true,
        delivery: ReplacementDelivery = .userSelectedAlternative,
        downloadURL: URL = URL(fileURLWithPath: "/tmp/candidate.jar"),
        sha256: String = String(repeating: "b", count: 64)
    ) -> ReplacementCandidate {
        ReplacementCandidate(
            id: id,
            name: name,
            version: version,
            fileName: "\(id).jar",
            downloadURL: downloadURL,
            sourceURL: URL(string: "https://example.invalid/\(id)/source")!,
            upstreamURL: URL(string: "https://example.invalid/upstream")!,
            upstreamRelationship: tier == .official ? "官方原版" : "上游认可的社区构建",
            buildEvidenceURL: URL(string: "https://example.invalid/\(id)/build")!,
            patchURL: tier == .projectBuilt ? URL(string: "https://example.invalid/\(id)/patch")! : nil,
            sbomURL: tier == .projectBuilt ? URL(string: "https://example.invalid/\(id)/sbom")! : nil,
            commit: "0123456789abcdef0123456789abcdef01234567",
            licenseIdentifier: "MIT",
            sha256: sha256,
            minecraftVersions: ["1.20.1"],
            loaders: loaders,
            requiredModAPIs: ["fabric-api"],
            platforms: [.macOS],
            architectures: ["arm64"],
            delivery: delivery,
            trustTier: tier,
            trustScore: score,
            maintenanceHistoryMonths: 24,
            hasPublicSource: true,
            hasPublicBuild: hasPublicBuild
        )
    }

    private func syntheticDisableIssue(
        relativePath: String,
        sha256: String,
        candidates: [ReplacementCandidate],
        modVersion: String = "1.0",
        action: CompatibilityAction = .disableMod
    ) -> NativeCompatibilityIssue {
        NativeCompatibilityIssue(
            id: "issue-\(relativePath)",
            ruleID: "test.windows-only",
            modID: "test-mod",
            modName: "Test Mod",
            modVersion: modVersion,
            relativePath: relativePath,
            sha256: sha256,
            severity: .blocking,
            confidence: .certain,
            reason: "test",
            evidence: [.init(kind: .builtInRule, detail: "test")],
            nativePayloads: [.init(path: "test.dll", platform: .windows)],
            action: action,
            autoFixEligible: true,
            isApplied: false,
            disabledRelativePath: nil,
            installedReplacementCandidateID: nil,
            installedReplacementRelativePath: nil,
            isUserRestored: false,
            isAcknowledged: false,
            fixError: nil,
            replacementCandidates: candidates
        )
    }
}
