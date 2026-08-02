//
//  NativeCompatibilityService.swift
//  PCL.Mac
//
//  macOS native payload inspection, reversible Windows-only isolation and
//  user-controlled replacement selection.
//

import Foundation
import ZIPFoundation
import CryptoKit

public enum NativeCompatibilitySeverity: Int, Codable, Sendable, Comparable {
    case information
    case warning
    case blocking

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum NativeCompatibilityConfidence: Int, Codable, Sendable {
    case low
    case medium
    case high
    case certain
}

public enum CompatibilityAction: String, Codable, Sendable {
    case disableMod
    case installOfficialArtifact
    case chooseReplacement
    case useRosetta
    case manualOnly
}

public enum ReplacementTrustTier: Int, Codable, Sendable, Comparable {
    case projectBuilt = 1
    case trustedCommunity = 2
    case official = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ReplacementDelivery: String, Codable, Sendable {
    /// A macOS native artifact published by the same upstream project for the
    /// exact same Mod release. This is the only replacement delivery that may
    /// be installed without an extra user choice.
    case officialSameReleaseArtifact
    /// A different version, fork, rewrite or functionally equivalent Mod.
    case userSelectedAlternative
}

public enum NativePayloadPlatform: String, Codable, Sendable {
    case windows
    case macOS
    case linux
    case unknown
}

public enum NativeCompatibilityEvidenceKind: String, Codable, Sendable {
    case builtInRule
    case officialMetadata
    case mandatoryNativeEntrypoint
    case crashLog
    case nativePayload
    case architecture
}

public struct NativeCompatibilityEvidence: Codable, Sendable, Hashable {
    public let kind: NativeCompatibilityEvidenceKind
    public let detail: String
    public let sourceURL: URL?

    public init(kind: NativeCompatibilityEvidenceKind, detail: String, sourceURL: URL? = nil) {
        self.kind = kind
        self.detail = detail
        self.sourceURL = sourceURL
    }
}

public struct NativePayload: Codable, Sendable, Hashable {
    public let path: String
    public let platform: NativePayloadPlatform
    public let architectures: [String]

    public init(path: String, platform: NativePayloadPlatform, architectures: [String] = []) {
        self.path = path
        self.platform = platform
        self.architectures = architectures
    }
}

/// The five dimensions are each expressed as 0...100. `total` applies the
/// fixed 35/25/20/15/5 weighting agreed for community replacement ranking.
public struct ReplacementTrustScore: Codable, Sendable, Hashable {
    public let sourceAndUpstream: Int
    public let reproducibility: Int
    public let ecosystemValidation: Int
    public let maintenanceAndSecurity: Int
    public let licenseCompleteness: Int

    public init(
        sourceAndUpstream: Int,
        reproducibility: Int,
        ecosystemValidation: Int,
        maintenanceAndSecurity: Int,
        licenseCompleteness: Int
    ) {
        self.sourceAndUpstream = Self.clamp(sourceAndUpstream)
        self.reproducibility = Self.clamp(reproducibility)
        self.ecosystemValidation = Self.clamp(ecosystemValidation)
        self.maintenanceAndSecurity = Self.clamp(maintenanceAndSecurity)
        self.licenseCompleteness = Self.clamp(licenseCompleteness)
    }

    public var total: Int {
        Int((
            Double(sourceAndUpstream) * 0.35
            + Double(reproducibility) * 0.25
            + Double(ecosystemValidation) * 0.20
            + Double(maintenanceAndSecurity) * 0.15
            + Double(licenseCompleteness) * 0.05
        ).rounded())
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 100) }
}

public struct ReplacementCompatibilityContext: Codable, Sendable, Hashable {
    public let minecraftVersion: String?
    public let loader: String?
    public let installedModAPIs: Set<String>
    public let architecture: String

    public init(
        minecraftVersion: String?,
        loader: String?,
        installedModAPIs: Set<String> = [],
        architecture: String
    ) {
        self.minecraftVersion = minecraftVersion
        self.loader = loader?.lowercased()
        self.installedModAPIs = Set(installedModAPIs.map { $0.lowercased() })
        self.architecture = architecture.lowercased()
    }
}

public struct ReplacementCandidate: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let version: String
    public let fileName: String
    public let downloadURL: URL
    public let sourceURL: URL
    public let upstreamURL: URL?
    public let upstreamRelationship: String
    public let buildEvidenceURL: URL
    public let patchURL: URL?
    public let sbomURL: URL?
    public let commit: String
    public let licenseIdentifier: String
    public let sha256: String
    public let minecraftVersions: [String]
    public let loaders: [String]
    public let requiredModAPIs: [String]
    public let platforms: [NativePayloadPlatform]
    public let architectures: [String]
    public let delivery: ReplacementDelivery
    public let trustTier: ReplacementTrustTier
    public let trustScore: ReplacementTrustScore
    public let maintenanceHistoryMonths: Int
    public let hasPublicSource: Bool
    public let hasPublicBuild: Bool

    public init(
        id: String,
        name: String,
        version: String,
        fileName: String,
        downloadURL: URL,
        sourceURL: URL,
        upstreamURL: URL? = nil,
        upstreamRelationship: String = "官方原版",
        buildEvidenceURL: URL,
        patchURL: URL? = nil,
        sbomURL: URL? = nil,
        commit: String,
        licenseIdentifier: String,
        sha256: String,
        minecraftVersions: [String],
        loaders: [String],
        requiredModAPIs: [String] = [],
        platforms: [NativePayloadPlatform] = [.macOS],
        architectures: [String],
        delivery: ReplacementDelivery = .userSelectedAlternative,
        trustTier: ReplacementTrustTier,
        trustScore: ReplacementTrustScore,
        maintenanceHistoryMonths: Int,
        hasPublicSource: Bool = true,
        hasPublicBuild: Bool = true
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.sourceURL = sourceURL
        self.upstreamURL = upstreamURL
        self.upstreamRelationship = upstreamRelationship
        self.buildEvidenceURL = buildEvidenceURL
        self.patchURL = patchURL
        self.sbomURL = sbomURL
        self.commit = commit
        self.licenseIdentifier = licenseIdentifier
        self.sha256 = sha256.lowercased()
        self.minecraftVersions = minecraftVersions
        self.loaders = loaders
        self.requiredModAPIs = requiredModAPIs
        self.platforms = platforms
        self.architectures = architectures
        self.delivery = delivery
        self.trustTier = trustTier
        self.trustScore = trustScore
        self.maintenanceHistoryMonths = max(maintenanceHistoryMonths, 0)
        self.hasPublicSource = hasPublicSource
        self.hasPublicBuild = hasPublicBuild
    }

    /// Community and project-built artifacts must pass the provenance gate
    /// before they are even shown. Official artifacts still require a source
    /// URL and exact SHA-256.
    public var isEligibleForListing: Bool {
        let hasExactHash = sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
        let hasFixedCommit = commit.count >= 7 && commit.allSatisfy(\.isHexDigit)
        let safeFileName = !fileName.isEmpty
            && fileName == (fileName as NSString).lastPathComponent
            && fileName.lowercased().hasSuffix(".jar")
        let declaresCompatibility = !minecraftVersions.isEmpty
            && !loaders.isEmpty
            && platforms.contains(.macOS)
            && !architectures.isEmpty
        guard hasExactHash,
              hasFixedCommit,
              safeFileName,
              declaresCompatibility,
              !licenseIdentifier.isEmpty,
              !upstreamRelationship.isEmpty else { return false }
        if trustTier == .official { return hasPublicSource }
        if trustTier == .projectBuilt {
            return hasPublicSource && hasPublicBuild && patchURL != nil && sbomURL != nil
        }
        return hasPublicSource && hasPublicBuild
    }

    public func isCompatible(with context: ReplacementCompatibilityContext) -> Bool {
        guard isEligibleForListing,
              let minecraftVersion = context.minecraftVersion,
              minecraftVersions.contains(where: { $0.caseInsensitiveCompare(minecraftVersion) == .orderedSame }),
              let loader = context.loader,
              loaders.contains(where: { $0.caseInsensitiveCompare(loader) == .orderedSame }),
              platforms.contains(.macOS) else { return false }

        let normalizedArchitectures = Set(architectures.map { Self.normalizedArchitecture($0) })
        let targetArchitecture = Self.normalizedArchitecture(context.architecture)
        guard normalizedArchitectures.contains("universal") || normalizedArchitectures.contains(targetArchitecture) else {
            return false
        }
        return Set(requiredModAPIs.map { $0.lowercased() }).isSubset(of: context.installedModAPIs)
    }

    /// No candidate is selected here. This method only filters and orders the
    /// list that the user will choose from.
    public static func ranked(_ candidates: [ReplacementCandidate]) -> [ReplacementCandidate] {
        candidates.filter(\.isEligibleForListing).sorted { lhs, rhs in
            if lhs.trustTier != rhs.trustTier { return lhs.trustTier > rhs.trustTier }
            if lhs.trustScore.total != rhs.trustScore.total { return lhs.trustScore.total > rhs.trustScore.total }
            if lhs.trustScore.reproducibility != rhs.trustScore.reproducibility {
                return lhs.trustScore.reproducibility > rhs.trustScore.reproducibility
            }
            if lhs.trustScore.sourceAndUpstream != rhs.trustScore.sourceAndUpstream {
                return lhs.trustScore.sourceAndUpstream > rhs.trustScore.sourceAndUpstream
            }
            if lhs.maintenanceHistoryMonths != rhs.maintenanceHistoryMonths {
                return lhs.maintenanceHistoryMonths > rhs.maintenanceHistoryMonths
            }
            let leftName = lhs.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let rightName = rhs.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if leftName != rightName { return leftName < rightName }
            return lhs.id < rhs.id
        }
    }

    public static func ranked(
        _ candidates: [ReplacementCandidate],
        compatibleWith context: ReplacementCompatibilityContext
    ) -> [ReplacementCandidate] {
        ranked(candidates.filter { $0.isCompatible(with: context) })
    }

    public func isAutomaticOfficialArtifact(for issue: NativeCompatibilityIssue) -> Bool {
        trustTier == .official
            && delivery == .officialSameReleaseArtifact
            && issue.modVersion != nil
            && version == issue.modVersion
    }

    private static func normalizedArchitecture(_ value: String) -> String {
        switch value.lowercased() {
        case "aarch64": return "arm64"
        case "amd64", "x64": return "x86_64"
        case "fat", "fatfile": return "universal"
        default: return value.lowercased()
        }
    }
}

/// A reviewed compatibility catalog entry. Official support statements use
/// `.officialMetadata`; exact hashes can pin a rule to one immutable artifact.
public struct NativeCompatibilityRule: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let fileNameContains: [String]
    public let modIDs: Set<String>
    public let versions: Set<String>
    public let requiredEntries: Set<String>
    public let sha256s: Set<String>
    public let requiresWindowsOnlyNativePayloads: Bool
    public let action: CompatibilityAction
    public let reason: String
    public let evidenceKind: NativeCompatibilityEvidenceKind
    public let evidenceSource: URL?
    public let candidates: [ReplacementCandidate]

    public init(
        id: String,
        fileNameContains: [String] = [],
        modIDs: Set<String> = [],
        versions: Set<String> = [],
        requiredEntries: Set<String> = [],
        sha256s: Set<String> = [],
        requiresWindowsOnlyNativePayloads: Bool = true,
        action: CompatibilityAction = .disableMod,
        reason: String,
        evidenceKind: NativeCompatibilityEvidenceKind,
        evidenceSource: URL? = nil,
        candidates: [ReplacementCandidate] = []
    ) {
        self.id = id
        self.fileNameContains = fileNameContains.map { $0.lowercased() }
        self.modIDs = Set(modIDs.map { $0.lowercased() })
        self.versions = versions
        self.requiredEntries = Set(requiredEntries.map { $0.lowercased() })
        self.sha256s = Set(sha256s.map { $0.lowercased() })
        self.requiresWindowsOnlyNativePayloads = requiresWindowsOnlyNativePayloads
        self.action = action
        self.reason = reason
        self.evidenceKind = evidenceKind
        self.evidenceSource = evidenceSource
        self.candidates = candidates
    }
}

public struct NativeCompatibilityIssue: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let ruleID: String?
    public let modID: String?
    public let modName: String
    public let modVersion: String?
    public let relativePath: String
    public let sha256: String
    public let severity: NativeCompatibilitySeverity
    public let confidence: NativeCompatibilityConfidence
    public let reason: String
    public let evidence: [NativeCompatibilityEvidence]
    public let nativePayloads: [NativePayload]
    public let action: CompatibilityAction
    public let autoFixEligible: Bool
    public var isApplied: Bool
    public var disabledRelativePath: String?
    public var installedReplacementCandidateID: String?
    public var installedReplacementRelativePath: String?
    public var isUserRestored: Bool
    public var isAcknowledged: Bool
    public var fixError: String?
    public let replacementCandidates: [ReplacementCandidate]

    public var needsAttention: Bool { !isApplied && !isUserRestored && severity >= .warning }
}

public struct NativeCompatibilityReport: Codable, Sendable, Hashable {
    public static let schemaVersion = 3

    public let schemaVersion: Int
    public let instancePath: String
    public let analyzedAt: Date
    public let targetArchitecture: String
    public var issues: [NativeCompatibilityIssue]

    public init(instancePath: String, analyzedAt: Date = Date(), targetArchitecture: String, issues: [NativeCompatibilityIssue]) {
        self.schemaVersion = Self.schemaVersion
        self.instancePath = instancePath
        self.analyzedAt = analyzedAt
        self.targetArchitecture = targetArchitecture
        self.issues = issues
    }

    public var disabledCount: Int {
        issues.filter { $0.action == .disableMod && $0.isApplied }.count
    }
    public var installedOfficialArtifactCount: Int {
        issues.filter { $0.action == .installOfficialArtifact && $0.isApplied }.count
    }
    public var unresolvedCount: Int { issues.filter(\.needsAttention).count }
    public var unacknowledgedIssues: [NativeCompatibilityIssue] {
        issues.filter { $0.needsAttention && !$0.isAcknowledged }
    }
}

public enum NativeCompatibilityError: LocalizedError {
    case invalidInstancePath
    case originalModMissing(String)
    case restoreDestinationOccupied(String)
    case replacementNotEligible(String)
    case replacementRequiresUserSelection

    public var errorDescription: String? {
        switch self {
        case .invalidInstancePath:
            return "兼容操作试图访问实例目录之外的文件。"
        case .originalModMissing(let name):
            return "找不到原始 Mod：\(name)"
        case .restoreDestinationOccupied(let name):
            return "无法恢复 \(name)：原位置已有同名文件。"
        case .replacementNotEligible(let name):
            return "替代包 \(name) 缺少完整来源、构建或哈希证据。"
        case .replacementRequiresUserSelection:
            return "社区或重编译替代包必须由用户明确选择。"
        }
    }
}

public actor NativeCompatibilityService {
    public static let shared = NativeCompatibilityService()
    public static let stateFileName = ".PCL_Mac_compatibility.json"

    private static let stateSchemaVersion = 3
    private static let ruleVersion = 3

    private static let defaultRules: [NativeCompatibilityRule] = [
        .init(
            id: "windows-only.input-method-blocker.v1",
            fileNameContains: ["inputmethodblocker"],
            requiredEntries: [
                "com/github/skystardust/inputmethodblocker/inputmethodblocker.class",
                "inputmethodblocker-native-x64.dll",
                "inputmethodblocker-native-x86.dll"
            ],
            reason: "该 Mod 的输入法功能仅实现了 Windows DLL，在 macOS 上无法加载。",
            evidenceKind: .builtInRule,
            evidenceSource: URL(string: "https://modrinth.com/mod/inputmethodblocker"),
            candidates: []
        )
    ]

    private let compatibilityRules: [NativeCompatibilityRule]

    private struct JarInspection: Codable, Sendable {
        var modID: String?
        var modName: String?
        var modVersion: String?
        var entryMarkers: Set<String>
        var nativePayloads: [NativePayload]
        var mandatoryEntrypoints: [String]
        var hasMandatoryNativeLoad: Bool
        var hasPlatformGuard: Bool
    }

    private struct CachedInspection: Codable, Sendable {
        let fileSize: Int
        let modifiedAt: TimeInterval
        let inspection: JarInspection
    }

    private enum AppliedFixStatus: String, Codable, Sendable {
        case disabled
        case restored
    }

    private enum OfficialArtifactStatus: String, Codable, Sendable {
        case installed
        case restored
    }

    private struct AppliedFix: Codable, Sendable {
        let issueID: String
        let originalRelativePath: String
        let disabledRelativePath: String
        let originalSHA256: String
        let ruleID: String?
        let evidence: [NativeCompatibilityEvidence]
        let appliedAt: Date
        var status: AppliedFixStatus
        var restoredAt: Date?
        var replacementRelativePath: String?
        var replacementDisabledRelativePath: String?
        var replacementSHA256: String?
        var replacementCandidateID: String?
    }

    private struct InstalledOfficialArtifact: Codable, Sendable {
        let issueID: String
        let candidateID: String
        let relativePath: String
        let sha256: String
        let installedAt: Date
        var status: OfficialArtifactStatus
        var restoredAt: Date?
        var restoredRelativePath: String?
    }

    private struct PersistedState: Codable, Sendable {
        var schemaVersion: Int = NativeCompatibilityService.stateSchemaVersion
        var ruleVersion: Int = NativeCompatibilityService.ruleVersion
        var lastReport: NativeCompatibilityReport?
        var appliedFixes: [AppliedFix] = []
        var installedOfficialArtifacts: [InstalledOfficialArtifact] = []
        var acknowledgedIssueIDs: Set<String> = []
        var restoredIssueIDs: Set<String> = []
        var scanCache: [String: CachedInspection] = [:]
    }

    public init(additionalRules: [NativeCompatibilityRule] = []) {
        // A newer, more specific catalog rule (typically pinned by hash) may
        // supersede an older structural fallback such as InputMethodBlocker.
        compatibilityRules = additionalRules + Self.defaultRules
    }

    public func analyze(instance: MinecraftInstance, targetArchitecture: Architecture) async throws -> NativeCompatibilityReport {
        let installedModAPIs = Set(recursivelyEnumeratedJars(at: instance.runningDirectory.appending(path: "mods"))
            .compactMap { Mod.loadMod(url: $0)?.id.nilIfEmpty?.lowercased() })
        let context = ReplacementCompatibilityContext(
            minecraftVersion: instance.version?.displayName,
            loader: instance.clientBrand?.rawValue,
            installedModAPIs: installedModAPIs,
            architecture: architectureName(targetArchitecture)
        )
        return try await analyze(
            instanceURL: instance.runningDirectory,
            targetArchitecture: targetArchitecture,
            compatibilityContext: context
        )
    }

    /// URL overload keeps the scanner independently testable and usable while
    /// an imported instance is still being finalized.
    public func analyze(instanceURL: URL, targetArchitecture: Architecture) async throws -> NativeCompatibilityReport {
        try await analyze(instanceURL: instanceURL, targetArchitecture: targetArchitecture, compatibilityContext: nil)
    }

    private func analyze(
        instanceURL: URL,
        targetArchitecture: Architecture,
        compatibilityContext: ReplacementCompatibilityContext?
    ) async throws -> NativeCompatibilityReport {
        let root = instanceURL.standardizedFileURL
        let modsURL = root.appending(path: "mods")
        var state = loadState(instanceURL: root)
        state.ruleVersion = Self.ruleVersion
        var issues: [NativeCompatibilityIssue] = []
        var refreshedCache: [String: CachedInspection] = [:]
        let crashEvidence = loadNativeCrashEvidence(instanceURL: root)

        for jarURL in recursivelyEnumeratedJars(at: modsURL) {
            try Task.checkCancellation()
            let relativePath = try relativePath(of: jarURL, under: root)
            guard let fingerprint = fingerprint(for: jarURL) else { continue }

            let inspection: JarInspection
            if let cached = state.scanCache[relativePath],
               cached.fileSize == fingerprint.fileSize,
               cached.modifiedAt == fingerprint.modifiedAt {
                inspection = cached.inspection
            } else {
                do {
                    inspection = try inspectJar(at: jarURL)
                } catch {
                    // A single truncated/corrupt JAR must not suppress fixes for
                    // every other Mod in the instance.
                    warn("无法检查原生组件，已跳过 \(jarURL.lastPathComponent)：\(error.localizedDescription)")
                    continue
                }
            }
            refreshedCache[relativePath] = .init(
                fileSize: fingerprint.fileSize,
                modifiedAt: fingerprint.modifiedAt,
                inspection: inspection
            )

            guard !inspection.nativePayloads.isEmpty else { continue }
            let hash = try streamingSHA256(jarURL)
            if let issue = makeIssue(
                jarURL: jarURL,
                relativePath: relativePath,
                sha256: hash,
                inspection: inspection,
                targetArchitecture: targetArchitecture,
                crashEvidence: crashEvidence,
                acknowledged: state.acknowledgedIssueIDs,
                restored: state.restoredIssueIDs,
                compatibilityContext: compatibilityContext
            ) {
                issues.append(issue)
            }
        }

        // Preserve reversible fixes in the report even though their source JAR
        // is no longer enabled and therefore was not part of the scan above.
        for fix in state.appliedFixes where fix.status == .disabled {
            let disabledURL = try safeURL(relativePath: fix.disabledRelativePath, under: root)
            guard FileManager.default.fileExists(atPath: disabledURL.path) else { continue }
            if var previous = state.lastReport?.issues.first(where: { $0.id == fix.issueID }) {
                previous.isApplied = true
                previous.disabledRelativePath = fix.disabledRelativePath
                previous.isAcknowledged = true
                issues.removeAll { $0.id == previous.id }
                issues.append(previous)
            }
        }

        for artifact in state.installedOfficialArtifacts where artifact.status == .installed {
            let artifactURL = try safeURL(relativePath: artifact.relativePath, under: root)
            guard FileManager.default.fileExists(atPath: artifactURL.path) else { continue }
            if let index = issues.firstIndex(where: { $0.id == artifact.issueID }) {
                issues[index].isApplied = true
                issues[index].isAcknowledged = true
                issues[index].installedReplacementCandidateID = artifact.candidateID
                issues[index].installedReplacementRelativePath = artifact.relativePath
            } else if var previous = state.lastReport?.issues.first(where: { $0.id == artifact.issueID }) {
                previous.isApplied = true
                previous.isAcknowledged = true
                previous.installedReplacementCandidateID = artifact.candidateID
                previous.installedReplacementRelativePath = artifact.relativePath
                issues.append(previous)
            }
        }

        issues.sort {
            if $0.isApplied != $1.isApplied { return $0.isApplied && !$1.isApplied }
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.modName.localizedStandardCompare($1.modName) == .orderedAscending
        }

        let report = NativeCompatibilityReport(
            instancePath: root.path,
            targetArchitecture: architectureName(targetArchitecture),
            issues: issues
        )
        state.lastReport = report
        state.scanCache = refreshedCache
        try saveState(state, instanceURL: root)
        return report
    }

    /// Applies deterministic, reversible fixes. Community/project candidates
    /// are never selected here. The only permitted automatic download is an
    /// official artifact for the exact same Mod release.
    @discardableResult
    public func applyTrustedFixes(report input: NativeCompatibilityReport) async throws -> NativeCompatibilityReport {
        let root = URL(fileURLWithPath: input.instancePath).standardizedFileURL
        var state = loadState(instanceURL: root)
        var report = input
        var completedMoves: [(from: URL, to: URL)] = []

        for index in report.issues.indices {
            guard report.issues[index].autoFixEligible,
                  report.issues[index].action == .disableMod,
                  !report.issues[index].isApplied,
                  !state.restoredIssueIDs.contains(report.issues[index].id) else { continue }

            let issue = report.issues[index]
            let source = try safeURL(relativePath: issue.relativePath, under: root)
            guard FileManager.default.fileExists(atPath: source.path) else {
                report.issues[index].fixError = NativeCompatibilityError.originalModMissing(issue.modName).localizedDescription
                continue
            }

            do {
                let currentHash = try streamingSHA256(source)
                guard currentHash == issue.sha256 else {
                    throw HashError.mismatch(expected: issue.sha256, actual: currentHash, file: source)
                }
                let destination = uniqueDisabledURL(for: source)
                try FileManager.default.moveItem(at: source, to: destination)
                completedMoves.append((from: source, to: destination))

                let disabledRelativePath = try relativePath(of: destination, under: root)
                report.issues[index].isApplied = true
                report.issues[index].isAcknowledged = true
                report.issues[index].disabledRelativePath = disabledRelativePath
                report.issues[index].fixError = nil
                state.acknowledgedIssueIDs.insert(issue.id)
                state.restoredIssueIDs.remove(issue.id)
                state.appliedFixes.removeAll { $0.issueID == issue.id }
                state.appliedFixes.append(.init(
                    issueID: issue.id,
                    originalRelativePath: issue.relativePath,
                    disabledRelativePath: disabledRelativePath,
                    originalSHA256: issue.sha256,
                    ruleID: issue.ruleID,
                    evidence: issue.evidence,
                    appliedAt: Date(),
                    status: .disabled,
                    restoredAt: nil,
                    replacementRelativePath: nil,
                    replacementDisabledRelativePath: nil,
                    replacementSHA256: nil,
                    replacementCandidateID: nil
                ))
                log("已隔离 Windows-only Mod：\(issue.modName) → \(destination.lastPathComponent)")
            } catch {
                report.issues[index].fixError = error.localizedDescription
                err("无法隔离 \(issue.modName)：\(error.localizedDescription)")
            }
        }

        state.lastReport = report
        do {
            try saveState(state, instanceURL: root)
        } catch {
            for move in completedMoves.reversed() where FileManager.default.fileExists(atPath: move.to.path) {
                try? FileManager.default.moveItem(at: move.to, to: move.from)
            }
            throw error
        }

        for index in report.issues.indices {
            let issue = report.issues[index]
            let shouldInstall = switch issue.action {
            case .disableMod: issue.isApplied
            case .installOfficialArtifact:
                issue.autoFixEligible && !issue.isApplied && !state.restoredIssueIDs.contains(issue.id)
            default: false
            }
            guard shouldInstall else { continue }
            let automaticArtifacts = issue.replacementCandidates.filter {
                $0.isAutomaticOfficialArtifact(for: issue)
            }
            guard automaticArtifacts.count == 1, let candidate = automaticArtifacts.first else { continue }
            do {
                try await installCandidate(
                    candidate,
                    for: issue.id,
                    instanceURL: root,
                    authority: .automaticOfficialArtifact
                )
                report.issues[index].installedReplacementCandidateID = candidate.id
                report.issues[index].installedReplacementRelativePath = "mods/\(candidate.fileName)"
                if issue.action == .installOfficialArtifact {
                    report.issues[index].isApplied = true
                    report.issues[index].isAcknowledged = true
                }
                report.issues[index].fixError = nil
            } catch {
                // A partial or unverifiable artifact is never enabled. For a
                // replacement, the original remains disabled and recoverable;
                // for dependency completion, the original remains untouched.
                report.issues[index].fixError = "官方 Mac 组件安装失败：\(error.localizedDescription)"
                err("无法安装官方 Mac 组件 \(candidate.name)：\(error.localizedDescription)")
            }
        }

        state = loadState(instanceURL: root)
        state.lastReport = report
        try saveState(state, instanceURL: root)
        return report
    }

    public func restore(issueID: String, instance: MinecraftInstance) async throws {
        try await restore(issueID: issueID, instanceURL: instance.runningDirectory)
    }

    public func restore(issueID: String, instanceURL: URL) async throws {
        let root = instanceURL.standardizedFileURL
        var state = loadState(instanceURL: root)
        if let artifactIndex = state.installedOfficialArtifacts.firstIndex(where: {
            $0.issueID == issueID && $0.status == .installed
        }) {
            let artifact = state.installedOfficialArtifacts[artifactIndex]
            let installed = try safeURL(relativePath: artifact.relativePath, under: root)
            guard FileManager.default.fileExists(atPath: installed.path) else {
                throw NativeCompatibilityError.originalModMissing(installed.lastPathComponent)
            }
            let currentHash = try streamingSHA256(installed)
            guard currentHash == artifact.sha256 else {
                throw HashError.mismatch(expected: artifact.sha256, actual: currentHash, file: installed)
            }
            let restored = uniqueDisabledURL(for: installed)
            try FileManager.default.moveItem(at: installed, to: restored)
            do {
                state.installedOfficialArtifacts[artifactIndex].status = .restored
                state.installedOfficialArtifacts[artifactIndex].restoredAt = Date()
                state.installedOfficialArtifacts[artifactIndex].restoredRelativePath = try relativePath(
                    of: restored,
                    under: root
                )
                state.acknowledgedIssueIDs.insert(issueID)
                state.restoredIssueIDs.insert(issueID)
                if let reportIndex = state.lastReport?.issues.firstIndex(where: { $0.id == issueID }) {
                    state.lastReport?.issues[reportIndex].isApplied = false
                    state.lastReport?.issues[reportIndex].installedReplacementCandidateID = nil
                    state.lastReport?.issues[reportIndex].installedReplacementRelativePath = nil
                    state.lastReport?.issues[reportIndex].isUserRestored = true
                    state.lastReport?.issues[reportIndex].isAcknowledged = true
                }
                try saveState(state, instanceURL: root)
                log("已移除官方 Mac 组件：\(installed.lastPathComponent)")
                return
            } catch {
                if FileManager.default.fileExists(atPath: restored.path) {
                    try? FileManager.default.moveItem(at: restored, to: installed)
                }
                throw error
            }
        }

        guard let index = state.appliedFixes.firstIndex(where: {
            $0.issueID == issueID && $0.status == .disabled
        }) else { return }
        let fix = state.appliedFixes[index]
        let original = try safeURL(relativePath: fix.originalRelativePath, under: root)
        let disabled = try safeURL(relativePath: fix.disabledRelativePath, under: root)
        guard FileManager.default.fileExists(atPath: disabled.path) else {
            throw NativeCompatibilityError.originalModMissing(disabled.lastPathComponent)
        }
        guard !FileManager.default.fileExists(atPath: original.path) else {
            throw NativeCompatibilityError.restoreDestinationOccupied(original.lastPathComponent)
        }

        var disabledReplacement: (enabled: URL, disabled: URL)?
        if let replacementPath = fix.replacementRelativePath {
            let replacement = try safeURL(relativePath: replacementPath, under: root)
            if FileManager.default.fileExists(atPath: replacement.path) {
                let replacementDisabled = uniqueDisabledURL(for: replacement)
                try FileManager.default.moveItem(at: replacement, to: replacementDisabled)
                disabledReplacement = (replacement, replacementDisabled)
            }
        }

        do {
            try FileManager.default.moveItem(at: disabled, to: original)
            state.appliedFixes[index].status = .restored
            state.appliedFixes[index].restoredAt = Date()
            if let replacement = disabledReplacement {
                state.appliedFixes[index].replacementDisabledRelativePath = try relativePath(
                    of: replacement.disabled,
                    under: root
                )
            }
            state.acknowledgedIssueIDs.insert(issueID)
            state.restoredIssueIDs.insert(issueID)
            if let reportIndex = state.lastReport?.issues.firstIndex(where: { $0.id == issueID }) {
                state.lastReport?.issues[reportIndex].isApplied = false
                state.lastReport?.issues[reportIndex].disabledRelativePath = nil
                state.lastReport?.issues[reportIndex].isUserRestored = true
                state.lastReport?.issues[reportIndex].isAcknowledged = true
            }
            try saveState(state, instanceURL: root)
            log("已恢复 Mod：\(original.lastPathComponent)")
        } catch {
            if FileManager.default.fileExists(atPath: original.path) {
                try? FileManager.default.moveItem(at: original, to: disabled)
            }
            if let replacement = disabledReplacement,
               FileManager.default.fileExists(atPath: replacement.disabled.path) {
                try? FileManager.default.moveItem(at: replacement.disabled, to: replacement.enabled)
            }
            throw error
        }
    }

    /// Called only after a user clicks a concrete candidate. Sorting never calls
    /// this method and no candidate is implicitly selected.
    public func installReplacement(
        _ candidate: ReplacementCandidate,
        for issueID: String,
        instance: MinecraftInstance
    ) async throws {
        try await installReplacement(candidate, for: issueID, instanceURL: instance.runningDirectory)
    }

    public func installReplacement(
        _ candidate: ReplacementCandidate,
        for issueID: String,
        instanceURL: URL
    ) async throws {
        try await installCandidate(candidate, for: issueID, instanceURL: instanceURL, authority: .userSelection)
    }

    private enum CandidateInstallationAuthority {
        case userSelection
        case automaticOfficialArtifact
    }

    private func installCandidate(
        _ candidate: ReplacementCandidate,
        for issueID: String,
        instanceURL: URL,
        authority: CandidateInstallationAuthority
    ) async throws {
        guard candidate.isEligibleForListing else {
            throw NativeCompatibilityError.replacementNotEligible(candidate.name)
        }
        let root = instanceURL.standardizedFileURL
        var state = loadState(instanceURL: root)
        guard let reportedIssue = state.lastReport?.issues.first(where: { $0.id == issueID }),
              reportedIssue.replacementCandidates.contains(where: {
                  $0.id == candidate.id && $0.sha256 == candidate.sha256
              }) else {
            throw NativeCompatibilityError.replacementRequiresUserSelection
        }
        let isOfficialDependencyCompletion = reportedIssue.action == .installOfficialArtifact
        let fixIndex: Int?
        if isOfficialDependencyCompletion {
            fixIndex = nil
        } else {
            fixIndex = state.appliedFixes.firstIndex(where: {
                $0.issueID == issueID && $0.status == .disabled
            })
            guard fixIndex != nil else {
                throw NativeCompatibilityError.originalModMissing(issueID)
            }
        }
        if authority == .automaticOfficialArtifact,
           !candidate.isAutomaticOfficialArtifact(for: reportedIssue) {
            throw NativeCompatibilityError.replacementRequiresUserSelection
        }

        let modsURL = root.appending(path: "mods")
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        let destination = try safeURL(relativePath: "mods/\(candidate.fileName)", under: root)
        if isOfficialDependencyCompletion {
            if state.installedOfficialArtifacts.contains(where: {
                $0.issueID == issueID && $0.candidateID == candidate.id && $0.status == .installed
            }), FileManager.default.fileExists(atPath: destination.path) {
                return
            }
        } else if let fixIndex,
                  state.appliedFixes[fixIndex].replacementCandidateID == candidate.id,
                  FileManager.default.fileExists(atPath: destination.path) {
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NativeCompatibilityError.restoreDestinationOccupied(destination.lastPathComponent)
        }
        let staging = modsURL.appending(path: ".pcl-native-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: staging) }

        if candidate.downloadURL.isFileURL {
            try FileManager.default.copyItem(at: candidate.downloadURL, to: staging)
        } else {
            let (temporaryURL, response) = try await URLSession.shared.download(from: candidate.downloadURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MyLocalizedError(reason: "替代包下载失败：HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: temporaryURL, to: staging)
        }
        try FileHash.verify(staging, expected: candidate.sha256, algorithm: .sha256)
        try FileManager.default.moveItem(at: staging, to: destination)

        do {
            let relative = try relativePath(of: destination, under: root)
            if isOfficialDependencyCompletion {
                state.installedOfficialArtifacts.removeAll { $0.issueID == issueID }
                state.installedOfficialArtifacts.append(.init(
                    issueID: issueID,
                    candidateID: candidate.id,
                    relativePath: relative,
                    sha256: candidate.sha256,
                    installedAt: Date(),
                    status: .installed,
                    restoredAt: nil,
                    restoredRelativePath: nil
                ))
                state.acknowledgedIssueIDs.insert(issueID)
                state.restoredIssueIDs.remove(issueID)
            } else if let fixIndex {
                state.appliedFixes[fixIndex].replacementRelativePath = relative
                state.appliedFixes[fixIndex].replacementSHA256 = candidate.sha256
                state.appliedFixes[fixIndex].replacementCandidateID = candidate.id
            }
            if let reportIndex = state.lastReport?.issues.firstIndex(where: { $0.id == issueID }) {
                state.lastReport?.issues[reportIndex].isApplied = true
                state.lastReport?.issues[reportIndex].isAcknowledged = true
                state.lastReport?.issues[reportIndex].installedReplacementCandidateID = candidate.id
                state.lastReport?.issues[reportIndex].installedReplacementRelativePath = relative
                state.lastReport?.issues[reportIndex].fixError = nil
            }
            try saveState(state, instanceURL: root)
            let source = authority == .automaticOfficialArtifact ? "官方同版本 Mac 组件" : "用户选择的兼容替代包"
            log("已安装\(source)：\(candidate.name) \(candidate.version)")
        } catch {
            try? FileManager.default.moveItem(at: destination, to: uniqueDisabledURL(for: destination))
            throw error
        }
    }

    public func acknowledge(issueIDs: [String], instance: MinecraftInstance) async throws {
        try await acknowledge(issueIDs: issueIDs, instanceURL: instance.runningDirectory)
    }

    public func acknowledge(issueIDs: [String], instanceURL: URL) async throws {
        var state = loadState(instanceURL: instanceURL)
        state.acknowledgedIssueIDs.formUnion(issueIDs)
        if var report = state.lastReport {
            for index in report.issues.indices where issueIDs.contains(report.issues[index].id) {
                report.issues[index].isAcknowledged = true
            }
            state.lastReport = report
        }
        try saveState(state, instanceURL: instanceURL)
    }

    public func reenableAutomaticFix(issueID: String, instance: MinecraftInstance) async throws {
        try await reenableAutomaticFix(issueID: issueID, instanceURL: instance.runningDirectory)
    }

    public func reenableAutomaticFix(issueID: String, instanceURL: URL) async throws {
        var state = loadState(instanceURL: instanceURL)
        state.restoredIssueIDs.remove(issueID)
        state.acknowledgedIssueIDs.remove(issueID)
        if let index = state.lastReport?.issues.firstIndex(where: { $0.id == issueID }) {
            state.lastReport?.issues[index].isUserRestored = false
            state.lastReport?.issues[index].isAcknowledged = false
        }
        try saveState(state, instanceURL: instanceURL)
    }

    public func lastReport(instance: MinecraftInstance) async -> NativeCompatibilityReport? {
        loadState(instanceURL: instance.runningDirectory).lastReport
    }

    public func lastReport(instanceURL: URL) async -> NativeCompatibilityReport? {
        loadState(instanceURL: instanceURL).lastReport
    }

    // MARK: - Inspection

    private func inspectJar(at url: URL) throws -> JarInspection {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        let lowerEntries = Set(entries.map { $0.path.lowercased() })
        var nativePayloads: [NativePayload] = []

        for entry in entries where isNativeEntry(entry.path) {
            let header = try archivePrefix(entry, archive: archive, limit: 4096)
            nativePayloads.append(inspectNativePayload(path: entry.path, header: header))
        }

        var mandatoryEntrypoints: [String] = []
        if let fabricEntry = archive["fabric.mod.json"],
           let object = try? JSONSerialization.jsonObject(with: archiveData(fabricEntry, archive: archive)) as? [String: Any] {
            let environment = (object["environment"] as? String)?.lowercased()
            if environment != "server" {
                mandatoryEntrypoints.append(contentsOf: fabricEntrypoints(from: object))
            }
        }
        if let annotationsEntry = archive["META-INF/fml_cache_annotation.json"],
           let object = try? JSONSerialization.jsonObject(with: archiveData(annotationsEntry, archive: archive)) as? [String: Any] {
            mandatoryEntrypoints.append(contentsOf: forgeEntrypoints(from: object))
        }
        if let manifestEntry = archive["META-INF/MANIFEST.MF"],
           let manifest = String(data: try archiveData(manifestEntry, archive: archive), encoding: .utf8) {
            mandatoryEntrypoints.append(contentsOf: manifestEntrypoints(from: manifest))
        }
        mandatoryEntrypoints = Array(Set(mandatoryEntrypoints.map(normalizeClassName))).sorted()

        let relevantClassEntries = relevantClasses(in: entries, entrypoints: mandatoryEntrypoints)
        var combinedClassBytes = Data()
        for entry in relevantClassEntries.prefix(32) where entry.uncompressedSize <= 1_048_576 {
            let remaining = max(2_097_152 - combinedClassBytes.count, 0)
            guard remaining > 0 else { break }
            combinedClassBytes.append(try archivePrefix(entry, archive: archive, limit: remaining))
        }
        let classStrings = String(decoding: combinedClassBytes, as: UTF8.self).lowercased()
        let hasSystemLoad = classStrings.contains("java/lang/system")
            && (classStrings.contains("loadlibrary") || classStrings.contains("load"))
        let hasDLLReference = classStrings.contains(".dll") || nativePayloads.contains { payload in
            let basename = (payload.path as NSString).lastPathComponent.lowercased()
            return !basename.isEmpty && classStrings.contains(basename)
        }
        let guardMarkers = ["os.name", "darwin", "mac os", "macos", "linux", "iswindows", "jna/platform"]
        let hasPlatformGuard = guardMarkers.contains { classStrings.contains($0) }
        let optionalFallbackMarkers = ["unsatisfiedlinkerror", "optional", "fallback", "tryload"]
        let hasOptionalFallback = optionalFallbackMarkers.contains { classStrings.contains($0) }
        let hasMandatoryNativeLoad = !mandatoryEntrypoints.isEmpty
            && hasSystemLoad
            && hasDLLReference
            && !hasPlatformGuard
            && !hasOptionalFallback

        let loadedMod = nativePayloads.isEmpty ? nil : Mod.loadMod(url: url)
        return JarInspection(
            modID: loadedMod?.id.nilIfEmpty,
            modName: loadedMod?.name.nilIfEmpty,
            modVersion: loadedMod?.version.nilIfEmpty,
            entryMarkers: lowerEntries,
            nativePayloads: nativePayloads,
            mandatoryEntrypoints: mandatoryEntrypoints,
            hasMandatoryNativeLoad: hasMandatoryNativeLoad,
            hasPlatformGuard: hasPlatformGuard
        )
    }

    private func rule(
        _ rule: NativeCompatibilityRule,
        matches fileName: String,
        inspection: JarInspection,
        sha256: String
    ) -> Bool {
        let hasSelector = !rule.fileNameContains.isEmpty
            || !rule.modIDs.isEmpty
            || !rule.versions.isEmpty
            || !rule.requiredEntries.isEmpty
            || !rule.sha256s.isEmpty
        guard hasSelector else { return false }

        let lowerName = fileName.lowercased()
        if !rule.fileNameContains.isEmpty,
           !rule.fileNameContains.contains(where: { lowerName.contains($0) }) {
            return false
        }
        if !rule.modIDs.isEmpty,
           !rule.modIDs.contains(inspection.modID?.lowercased() ?? "") {
            return false
        }
        if !rule.versions.isEmpty,
           !rule.versions.contains(inspection.modVersion ?? "") {
            return false
        }
        if !rule.requiredEntries.isSubset(of: inspection.entryMarkers) { return false }
        if !rule.sha256s.isEmpty, !rule.sha256s.contains(sha256.lowercased()) { return false }
        if rule.requiresWindowsOnlyNativePayloads {
            let platforms = Set(inspection.nativePayloads.map(\.platform))
            guard !platforms.isEmpty, platforms == [.windows] else { return false }
        }
        return true
    }

    private func makeIssue(
        jarURL: URL,
        relativePath: String,
        sha256: String,
        inspection: JarInspection,
        targetArchitecture: Architecture,
        crashEvidence: String,
        acknowledged: Set<String>,
        restored: Set<String>,
        compatibilityContext: ReplacementCompatibilityContext?
    ) -> NativeCompatibilityIssue? {
        let modName = inspection.modName ?? jarURL.deletingPathExtension().lastPathComponent
        let issueID = stableIssueID(relativePath: relativePath, sha256: sha256)
        let platforms = Set(inspection.nativePayloads.map(\.platform))
        let windowsPayloads = inspection.nativePayloads.filter { $0.platform == .windows }
        let macPayloads = inspection.nativePayloads.filter { $0.platform == .macOS }
        let onlyWindowsPayloads = !windowsPayloads.isEmpty && platforms == [.windows]

        if let rule = compatibilityRules.first(where: {
            rule($0, matches: jarURL.lastPathComponent, inspection: inspection, sha256: sha256)
        }) {
            let evidence: [NativeCompatibilityEvidence] = [
                .init(kind: rule.evidenceKind, detail: "匹配兼容规则 \(rule.id)", sourceURL: rule.evidenceSource),
                .init(kind: .nativePayload, detail: "检测到 \(inspection.nativePayloads.count) 个原生组件")
            ]
            if rule.action == .installOfficialArtifact {
                return makeOfficialArtifactIssue(
                    issueID: issueID,
                    rule: rule,
                    inspection: inspection,
                    modName: modName,
                    relativePath: relativePath,
                    sha256: sha256,
                    evidence: evidence,
                    acknowledged: acknowledged,
                    restored: restored,
                    compatibilityContext: compatibilityContext
                )
            }
            return makeWindowsOnlyIssue(
                issueID: issueID,
                ruleID: rule.id,
                inspection: inspection,
                modName: modName,
                relativePath: relativePath,
                sha256: sha256,
                confidence: .certain,
                reason: rule.reason,
                evidence: evidence,
                acknowledged: acknowledged,
                restored: restored,
                candidates: rule.candidates,
                compatibilityContext: compatibilityContext
            )
        }

        if onlyWindowsPayloads && inspection.hasMandatoryNativeLoad {
            return makeWindowsOnlyIssue(
                issueID: issueID,
                ruleID: "structural.mandatory-pe-only.v1",
                inspection: inspection,
                modName: modName,
                relativePath: relativePath,
                sha256: sha256,
                confidence: .high,
                reason: "Mod 的强制入口会加载原生库，但包内仅提供 Windows PE DLL，且没有检测到 macOS 回退。",
                evidence: [
                    .init(kind: .mandatoryNativeEntrypoint, detail: "强制入口：\(inspection.mandatoryEntrypoints.joined(separator: "、"))"),
                    .init(kind: .nativePayload, detail: "没有 Mach-O 或纯 Java 回退实现")
                ],
                acknowledged: acknowledged,
                restored: restored,
                candidates: [],
                compatibilityContext: compatibilityContext
            )
        }

        if onlyWindowsPayloads && crashLog(crashEvidence, implicates: jarURL, inspection: inspection) {
            return makeWindowsOnlyIssue(
                issueID: issueID,
                ruleID: "crash.unsatisfied-link.v1",
                inspection: inspection,
                modName: modName,
                relativePath: relativePath,
                sha256: sha256,
                confidence: .certain,
                reason: "最近的崩溃日志确认该 Mod 在 macOS 上尝试加载 Windows DLL。",
                evidence: [
                    .init(kind: .crashLog, detail: "UnsatisfiedLinkError 已与该 Mod 或其 DLL 建立关联"),
                    .init(kind: .nativePayload, detail: "包内没有 macOS 原生实现")
                ],
                acknowledged: acknowledged,
                restored: restored,
                candidates: [],
                compatibilityContext: compatibilityContext
            )
        }

        if !macPayloads.isEmpty {
            let targetName = architectureName(targetArchitecture)
            let compatible = macPayloads.contains { payload in
                payload.architectures.contains(targetName)
                    || payload.architectures.contains("universal")
            }
            if compatible { return nil }

            let x64Available = macPayloads.contains { $0.architectures.contains("x86_64") || $0.architectures.contains("universal") }
            let action: CompatibilityAction = targetArchitecture == .arm64 && x64Available ? .useRosetta : .manualOnly
            let reason = action == .useRosetta
                ? "该 Mod 只提供 x86_64 macOS 原生库，需要让整个游戏使用 x64 Java/Rosetta。"
                : "该 Mod 的 macOS 原生库与当前游戏进程架构不兼容。"
            return .init(
                id: issueID,
                ruleID: nil,
                modID: inspection.modID,
                modName: modName,
                modVersion: inspection.modVersion,
                relativePath: relativePath,
                sha256: sha256,
                severity: .warning,
                confidence: .high,
                reason: reason,
                evidence: [.init(kind: .architecture, detail: "目标架构 \(targetName)，可用架构 \(macPayloads.flatMap(\.architectures).joined(separator: "、"))")],
                nativePayloads: inspection.nativePayloads,
                action: action,
                autoFixEligible: false,
                isApplied: false,
                disabledRelativePath: nil,
                installedReplacementCandidateID: nil,
                installedReplacementRelativePath: nil,
                isUserRestored: restored.contains(issueID),
                isAcknowledged: acknowledged.contains(issueID),
                fixError: nil,
                replacementCandidates: []
            )
        }

        let reason: String
        if onlyWindowsPayloads {
            reason = "该 Mod 仅携带 Windows DLL，但暂时无法证明它是强制功能，因此不会自动停用。"
        } else {
            reason = "该 Mod 包含原生组件，但没有可确认的 macOS 实现。"
        }
        return .init(
            id: issueID,
            ruleID: nil,
            modID: inspection.modID,
            modName: modName,
            modVersion: inspection.modVersion,
            relativePath: relativePath,
            sha256: sha256,
            severity: .warning,
            confidence: .medium,
            reason: reason,
            evidence: [.init(kind: .nativePayload, detail: "检测到：\(inspection.nativePayloads.map(\.path).joined(separator: "、"))")],
            nativePayloads: inspection.nativePayloads,
            action: .manualOnly,
            autoFixEligible: false,
            isApplied: false,
            disabledRelativePath: nil,
            installedReplacementCandidateID: nil,
            installedReplacementRelativePath: nil,
            isUserRestored: restored.contains(issueID),
            isAcknowledged: acknowledged.contains(issueID),
            fixError: nil,
            replacementCandidates: []
        )
    }

    private func makeOfficialArtifactIssue(
        issueID: String,
        rule: NativeCompatibilityRule,
        inspection: JarInspection,
        modName: String,
        relativePath: String,
        sha256: String,
        evidence: [NativeCompatibilityEvidence],
        acknowledged: Set<String>,
        restored: Set<String>,
        compatibilityContext: ReplacementCompatibilityContext?
    ) -> NativeCompatibilityIssue {
        let visibleCandidates = compatibilityContext.map {
            ReplacementCandidate.ranked(rule.candidates, compatibleWith: $0)
        } ?? []
        let automaticCandidates = visibleCandidates.filter {
            $0.trustTier == .official
                && $0.delivery == .officialSameReleaseArtifact
                && inspection.modVersion != nil
                && $0.version == inspection.modVersion
        }
        return .init(
            id: issueID,
            ruleID: rule.id,
            modID: inspection.modID,
            modName: modName,
            modVersion: inspection.modVersion,
            relativePath: relativePath,
            sha256: sha256,
            severity: .blocking,
            confidence: .certain,
            reason: rule.reason,
            evidence: evidence,
            nativePayloads: inspection.nativePayloads,
            action: .installOfficialArtifact,
            autoFixEligible: automaticCandidates.count == 1,
            isApplied: false,
            disabledRelativePath: nil,
            installedReplacementCandidateID: nil,
            installedReplacementRelativePath: nil,
            isUserRestored: restored.contains(issueID),
            isAcknowledged: acknowledged.contains(issueID),
            fixError: nil,
            replacementCandidates: visibleCandidates
        )
    }

    private func makeWindowsOnlyIssue(
        issueID: String,
        ruleID: String,
        inspection: JarInspection,
        modName: String,
        relativePath: String,
        sha256: String,
        confidence: NativeCompatibilityConfidence,
        reason: String,
        evidence: [NativeCompatibilityEvidence],
        acknowledged: Set<String>,
        restored: Set<String>,
        candidates: [ReplacementCandidate],
        compatibilityContext: ReplacementCompatibilityContext?
    ) -> NativeCompatibilityIssue {
        let visibleCandidates = compatibilityContext.map {
            ReplacementCandidate.ranked(candidates, compatibleWith: $0)
        } ?? []
        return .init(
            id: issueID,
            ruleID: ruleID,
            modID: inspection.modID,
            modName: modName,
            modVersion: inspection.modVersion,
            relativePath: relativePath,
            sha256: sha256,
            severity: .blocking,
            confidence: confidence,
            reason: reason,
            evidence: evidence,
            nativePayloads: inspection.nativePayloads,
            action: .disableMod,
            autoFixEligible: true,
            isApplied: false,
            disabledRelativePath: nil,
            installedReplacementCandidateID: nil,
            installedReplacementRelativePath: nil,
            isUserRestored: restored.contains(issueID),
            isAcknowledged: acknowledged.contains(issueID),
            fixError: nil,
            replacementCandidates: visibleCandidates
        )
    }

    // MARK: - Archive metadata

    private func fabricEntrypoints(from object: [String: Any]) -> [String] {
        guard let groups = object["entrypoints"] as? [String: Any] else { return [] }
        return groups.values.flatMap { value -> [String] in
            let entries = value as? [Any] ?? [value]
            return entries.compactMap { item in
                if let string = item as? String { return string.components(separatedBy: "::").first }
                if let dictionary = item as? [String: Any], let string = dictionary["value"] as? String {
                    return string.components(separatedBy: "::").first
                }
                return nil
            }
        }
    }

    private func forgeEntrypoints(from object: [String: Any]) -> [String] {
        object.compactMap { className, value in
            guard let dictionary = value as? [String: Any],
                  let annotations = dictionary["annotations"] as? [[String: Any]],
                  annotations.contains(where: { ($0["name"] as? String) == "Lnet/minecraftforge/fml/common/Mod;" }) else {
                return nil
            }
            return className
        }
    }

    private func manifestEntrypoints(from manifest: String) -> [String] {
        let accepted = ["FMLCorePlugin", "Premain-Class", "Main-Class"]
        return manifest.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, accepted.contains(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func relevantClasses(in entries: [Entry], entrypoints: [String]) -> [Entry] {
        guard !entrypoints.isEmpty else { return [] }
        let exact = Set(entrypoints.map { normalizeClassName($0) + ".class" })
        return entries.filter { entry in
            let lower = entry.path.lowercased()
            guard lower.hasSuffix(".class") else { return false }
            return exact.contains(lower)
        }
    }

    private func normalizeClassName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func archiveData(_ entry: Entry, archive: Archive) throws -> Data {
        var result = Data()
        _ = try archive.extract(entry) { result.append($0) }
        return result
    }

    private func archivePrefix(_ entry: Entry, archive: Archive, limit: Int) throws -> Data {
        var result = Data()
        _ = try archive.extract(entry) { chunk in
            guard result.count < limit else { return }
            result.append(chunk.prefix(limit - result.count))
        }
        return result
    }

    private func isNativeEntry(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".dll") || lower.hasSuffix(".dylib") || lower.hasSuffix(".jnilib") || lower.hasSuffix(".so")
    }

    private func inspectNativePayload(path: String, header: Data) -> NativePayload {
        if isPE(header) {
            return .init(path: path, platform: .windows, architectures: peArchitectures(header))
        }
        if isELF(header) {
            return .init(path: path, platform: .linux, architectures: elfArchitectures(header))
        }
        if let architectures = machOArchitectures(header) {
            return .init(path: path, platform: .macOS, architectures: architectures)
        }
        let lower = path.lowercased()
        if lower.hasSuffix(".dll") { return .init(path: path, platform: .windows) }
        if lower.hasSuffix(".dylib") || lower.hasSuffix(".jnilib") { return .init(path: path, platform: .macOS) }
        if lower.hasSuffix(".so") { return .init(path: path, platform: .linux) }
        return .init(path: path, platform: .unknown)
    }

    private func isPE(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0x4D && data[1] == 0x5A
    }

    private func peArchitectures(_ data: Data) -> [String] {
        guard data.count >= 0x40 else { return [] }
        let offset = Int(readUInt32(data, at: 0x3C, bigEndian: false) ?? 0)
        guard offset >= 0, data.count >= offset + 6,
              data[offset] == 0x50, data[offset + 1] == 0x45 else { return [] }
        let machine = readUInt16(data, at: offset + 4, bigEndian: false)
        switch machine {
        case 0x8664: return ["x86_64"]
        case 0x014C: return ["x86"]
        case 0xAA64: return ["arm64"]
        default: return []
        }
    }

    private func isELF(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x7F && data[1] == 0x45 && data[2] == 0x4C && data[3] == 0x46
    }

    private func elfArchitectures(_ data: Data) -> [String] {
        guard data.count >= 20 else { return [] }
        let bigEndian = data[5] == 2
        switch readUInt16(data, at: 18, bigEndian: bigEndian) {
        case 0x003E: return ["x86_64"]
        case 0x0003: return ["x86"]
        case 0x00B7: return ["arm64"]
        default: return []
        }
    }

    /// Returns nil when the header is not Mach-O, otherwise its known slices.
    private func machOArchitectures(_ data: Data) -> [String]? {
        guard data.count >= 8 else { return nil }
        let magic = Array(data.prefix(4))
        if magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCE, 0xFA, 0xED, 0xFE] {
            return architectureForCPU(readUInt32(data, at: 4, bigEndian: false))
        }
        if magic == [0xFE, 0xED, 0xFA, 0xCF] || magic == [0xFE, 0xED, 0xFA, 0xCE] {
            return architectureForCPU(readUInt32(data, at: 4, bigEndian: true))
        }
        let isBigEndianFat = magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xCA, 0xFE, 0xBA, 0xBF]
        let isLittleEndianFat = magic == [0xBE, 0xBA, 0xFE, 0xCA] || magic == [0xBF, 0xBA, 0xFE, 0xCA]
        guard isBigEndianFat || isLittleEndianFat,
              let count = readUInt32(data, at: 4, bigEndian: isBigEndianFat) else { return nil }
        let is64 = magic == [0xCA, 0xFE, 0xBA, 0xBF] || magic == [0xBF, 0xBA, 0xFE, 0xCA]
        let recordSize = is64 ? 32 : 20
        var found: [String] = []
        for index in 0..<min(Int(count), 32) {
            let offset = 8 + index * recordSize
            guard let cpu = readUInt32(data, at: offset, bigEndian: isBigEndianFat) else { break }
            found.append(contentsOf: architectureForCPU(cpu))
        }
        let unique = Array(Set(found)).sorted()
        return unique.contains("arm64") && unique.contains("x86_64") ? ["universal", "arm64", "x86_64"] : unique
    }

    private func architectureForCPU(_ cpu: UInt32?) -> [String] {
        switch cpu {
        case 0x01000007: return ["x86_64"]
        case 0x0100000C: return ["arm64"]
        case 0x00000007: return ["x86"]
        default: return []
        }
    }

    private func readUInt16(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt16? {
        guard offset >= 0, data.count >= offset + 2 else { return nil }
        if bigEndian { return UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        if bigEndian {
            return UInt32(data[offset]) << 24
                | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8
                | UInt32(data[offset + 3])
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    // MARK: - Persistence and paths

    private func loadState(instanceURL: URL) -> PersistedState {
        let url = instanceURL.appending(path: Self.stateFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(PersistedState.self, from: data),
              state.schemaVersion == Self.stateSchemaVersion else {
            return PersistedState()
        }
        return state
    }

    private func saveState(_ state: PersistedState, instanceURL: URL) throws {
        try FileManager.default.createDirectory(at: instanceURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: instanceURL.appending(path: Self.stateFileName), options: .atomic)
    }

    private func recursivelyEnumeratedJars(at root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "jar" else { return nil }
            return url
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func fingerprint(for url: URL) -> (fileSize: Int, modifiedAt: TimeInterval)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return (values.fileSize ?? 0, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    private func safeURL(relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw NativeCompatibilityError.invalidInstancePath
        }
        let standardizedRoot = root.standardizedFileURL
        let result = standardizedRoot.appending(path: relativePath).standardizedFileURL
        guard result.path.hasPrefix(standardizedRoot.path + "/") else {
            throw NativeCompatibilityError.invalidInstancePath
        }
        return result
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let standardizedRoot = root.standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL.path
        guard standardizedURL.hasPrefix(standardizedRoot + "/") else {
            throw NativeCompatibilityError.invalidInstancePath
        }
        return String(standardizedURL.dropFirst(standardizedRoot.count + 1))
    }

    private func uniqueDisabledURL(for source: URL) -> URL {
        let preferred = source.appendingPathExtension("disabled")
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var index = 2
        while true {
            let candidate = directory.appending(path: "\(base)-pcl-\(index).\(ext).disabled")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func streamingSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stableIssueID(relativePath: String, sha256: String) -> String {
        let value = Data("\(relativePath)|\(sha256)".utf8)
        return SHA256.hash(data: value).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func architectureName(_ architecture: Architecture) -> String {
        switch architecture {
        case .arm64: return "arm64"
        case .x64: return "x86_64"
        case .fatFile: return "universal"
        case .unknown: return "unknown"
        }
    }

    private func loadNativeCrashEvidence(instanceURL: URL) -> String {
        var urls: [URL] = [
            instanceURL.appending(path: "logs/latest.log"),
            instanceURL.appending(path: "logs/debug.log")
        ]
        let reportsURL = instanceURL.appending(path: "crash-reports")
        if let reports = try? FileManager.default.contentsOfDirectory(
            at: reportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), let latest = reports.filter({ $0.pathExtension.lowercased() == "txt" }).max(by: {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }) {
            urls.append(latest)
        }
        return urls.compactMap(readTail).joined(separator: "\n").lowercased()
    }

    private func readTail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let limit: UInt64 = 2_097_152
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func crashLog(_ crashLog: String, implicates jarURL: URL, inspection: JarInspection) -> Bool {
        guard crashLog.contains("unsatisfiedlinkerror") && crashLog.contains(".dll") else { return false }
        var markers = inspection.nativePayloads
            .filter { $0.platform == .windows }
            .map { ($0.path as NSString).lastPathComponent.lowercased() }
        if let modID = inspection.modID?.lowercased(), modID.count >= 4 { markers.append(modID) }
        let stem = jarURL.deletingPathExtension().lastPathComponent
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .first.map(String.init) ?? ""
        if stem.count >= 5 { markers.append(stem) }

        // Attribution is deliberately local to the exception. Seeing a Mod ID
        // somewhere else in a long debug log is not strong enough evidence to
        // disable it automatically.
        let lines = crashLog.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices where lines[index].contains("unsatisfiedlinkerror") {
            let lowerBound = max(lines.startIndex, index - 20)
            let upperBound = min(lines.endIndex, index + 21)
            let window = lines[lowerBound..<upperBound].joined(separator: "\n")
            guard window.contains(".dll") else { continue }
            if markers.contains(where: { marker in
                window.contains(marker)
                    || window.contains(marker.replacingOccurrences(of: "-native-x64.dll", with: ""))
            }) {
                return true
            }
        }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
