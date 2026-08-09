//
//  OfficialWebDownloadCoordinator.swift
//  PCL.Mac
//
//  Receives downloads from a CurseForge page. The normal path remains
//  user-driven; a separately enabled accessibility mode may ask the embedded
//  browser to open the exact, trusted file route for a queued item.
//

import Combine
import Foundation
import WebKit

/// A file that cannot be retrieved through a launcher download URL, but can be
/// obtained after the user confirms the download on its official project page.
struct OfficialWebDownloadRequest: Codable, Hashable, Sendable, Identifiable {
    let projectID: Int
    let fileID: Int
    let fileName: String
    let destination: String
    let expectedSHA1: String?
    let curseForgePage: URL?

    var id: String { "\(projectID)-\(fileID)-\(destination)" }
}

/// Backward-compatible internal spelling used by the persisted manifest.
typealias OfficialWebDownloadRecord = OfficialWebDownloadRequest

/// Persistent queue format. Its record shape intentionally matches the old
/// `.PCL_Mac_manual_downloads.json` format so existing recoveries can be used.
struct OfficialWebDownloadManifest: Codable, Sendable {
    let schemaVersion: Int
    let reason: String
    let generatedAt: Date
    let files: [OfficialWebDownloadRecord]

    init(files: [OfficialWebDownloadRecord]) {
        self.schemaVersion = 1
        self.reason = "这些 CurseForge 文件需要在官方页面由用户确认下载。PCL.Mac 会自动校验、归位并继续导入。"
        self.generatedAt = Date()
        self.files = files
    }

    static func read(from url: URL) throws -> OfficialWebDownloadManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OfficialWebDownloadManifest.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try url.ensureParentDirectoryExists()
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum OfficialWebDownloadBlockReason: Equatable, Sendable {
    case missingOfficialPage
    case unsafeOfficialPage
    case missingSHA1
    case unsafeDestination

    var localizedDescription: String {
        switch self {
        case .missingOfficialPage: "整合包未提供该文件的官方 CurseForge 页面链接。"
        case .unsafeOfficialPage: "整合包提供的下载页面不是可信的 CurseForge 官方页面。"
        case .missingSHA1: "该文件缺少可用于安全归位的 SHA-1 校验值。"
        case .unsafeDestination: "整合包提供的目标路径不安全。"
        }
    }
}

struct OfficialWebDownloadBlock: Hashable, Sendable, Identifiable {
    let record: OfficialWebDownloadRecord
    let reason: OfficialWebDownloadBlockReason

    var id: String { record.id }
}

enum CurseForgeURLPolicy {
    static func isOfficialHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "curseforge.com" || host.hasSuffix(".curseforge.com")
    }

    static func isOfficialProjectPage(_ url: URL) -> Bool {
        projectPath(for: url) != nil
    }

    /// Returns the stable `/minecraft/<kind>/<slug>` portion of an official
    /// project URL. File-list subpages intentionally normalize to the same
    /// project so a queue item cannot accept a download from another project.
    static func projectPath(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", isOfficialHost(url) else { return nil }
        let components = url.path
            .lowercased()
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3, components[0] == "minecraft" else { return nil }
        return "/" + components.prefix(3).joined(separator: "/")
    }

    static func isSameOfficialProjectPage(_ candidate: URL, as expected: URL) -> Bool {
        guard let candidatePath = projectPath(for: candidate),
              let expectedPath = projectPath(for: expected) else { return false }
        return candidatePath == expectedPath
    }
}

/// A short-lived, one-shot authorization created when the queued project page
/// starts a navigation. CurseForge may render a countdown page, use script or
/// redirect before starting the real download, so WebKit's click and
/// `isUserInitiated` classifications are intentionally not part of this trust
/// decision.
struct OfficialWebDownloadProjectAuthorization: Sendable {
    static let validityWindow: TimeInterval = 60

    let projectPageURL: URL
    let originalRequestURL: URL?
    let issuedAtUptime: TimeInterval

    static func issue(
        from sourceURL: URL?,
        requestURL: URL?,
        navigationType _: WKNavigationType,
        expectedProjectPageURL: URL,
        issuedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Self? {
        guard let sourceURL,
              CurseForgeURLPolicy.isSameOfficialProjectPage(sourceURL, as: expectedProjectPageURL) else {
            return nil
        }
        return .init(
            projectPageURL: sourceURL,
            originalRequestURL: requestURL,
            issuedAtUptime: issuedAtUptime
        )
    }

    func isValid(
        for expectedProjectPageURL: URL,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let age = nowUptime - issuedAtUptime
        return age >= 0
            && age <= Self.validityWindow
            && CurseForgeURLPolicy.isSameOfficialProjectPage(projectPageURL, as: expectedProjectPageURL)
    }
}

/// Builds the one official CurseForge route that belongs to a validated queue
/// record. It intentionally has no fallback selectors or unbounded links, so
/// enabling the accessibility feature cannot turn a page into a general
/// browser automation surface.
enum OfficialWebDownloadBrowserAutomation {
    static func downloadURL(for group: OfficialWebDownloadGroup) -> URL? {
        guard let record = group.records.first,
              record.fileID > 0,
              let projectPath = CurseForgeURLPolicy.projectPath(for: group.pageURL),
              var components = URLComponents(url: group.pageURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "\(projectPath)/download/\(record.fileID)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func isExpectedDownloadURL(_ candidate: URL, for group: OfficialWebDownloadGroup) -> Bool {
        guard let expected = downloadURL(for: group) else { return false }
        return candidate.scheme?.lowercased() == expected.scheme?.lowercased()
            && candidate.host?.lowercased() == expected.host?.lowercased()
            && candidate.port == expected.port
            && candidate.path == expected.path
            && candidate.query == nil
            && candidate.fragment == nil
    }
}

/// A short-lived capability created only after the user opted into the
/// accessibility mode for the current queue. It authorizes one WebKit download
/// after CurseForge's countdown/redirect flow, even when WebKit reports that
/// final download as not directly user initiated.
struct OfficialWebDownloadBrowserAutomationAuthorization: Sendable {
    static let validityWindow: TimeInterval = 90

    let projectPageURL: URL
    let downloadURL: URL
    let issuedAtUptime: TimeInterval

    func isValid(
        for expectedProjectPageURL: URL,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let age = nowUptime - issuedAtUptime
        return age >= 0
            && age <= Self.validityWindow
            && CurseForgeURLPolicy.isSameOfficialProjectPage(projectPageURL, as: expectedProjectPageURL)
    }
}

struct OfficialWebDownloadGroup: Hashable, Sendable, Identifiable {
    let id: String
    let expectedSHA1: String
    let pageURL: URL
    let records: [OfficialWebDownloadRecord]

    var displayName: String { records[0].fileName }
}

struct OfficialWebDownloadPlan: Sendable {
    let groups: [OfficialWebDownloadGroup]
    let blocked: [OfficialWebDownloadBlock]
    let alreadySatisfiedCount: Int

    var isReady: Bool { blocked.isEmpty }
}

enum OfficialWebDownloadPlanner {
    static func plan(
        manifest: OfficialWebDownloadManifest,
        instanceRoot: URL
    ) -> OfficialWebDownloadPlan {
        var grouped: [String: [OfficialWebDownloadRecord]] = [:]
        var pageBySHA1: [String: URL] = [:]
        var order: [String] = []
        var blocked: [OfficialWebDownloadBlock] = []
        var alreadySatisfiedCount = 0

        for record in manifest.files {
            guard let sha1 = record.expectedSHA1?.lowercased(), isSHA1(sha1) else {
                blocked.append(.init(record: record, reason: .missingSHA1))
                continue
            }
            guard let page = record.curseForgePage else {
                blocked.append(.init(record: record, reason: .missingOfficialPage))
                continue
            }
            guard CurseForgeURLPolicy.isOfficialProjectPage(page) else {
                blocked.append(.init(record: record, reason: .unsafeOfficialPage))
                continue
            }
            guard let destination = try? destinationURL(for: record.destination, under: instanceRoot) else {
                blocked.append(.init(record: record, reason: .unsafeDestination))
                continue
            }
            if fileIsValid(at: destination, sha1: sha1) {
                alreadySatisfiedCount += 1
                continue
            }
            if grouped[sha1] == nil {
                grouped[sha1] = []
                pageBySHA1[sha1] = page
                order.append(sha1)
            }
            grouped[sha1]?.append(record)
        }

        let groups = order.compactMap { sha1 -> OfficialWebDownloadGroup? in
            guard let records = grouped[sha1],
                  let pageURL = pageBySHA1[sha1],
                  !records.isEmpty else { return nil }
            return .init(id: sha1, expectedSHA1: sha1, pageURL: pageURL, records: records)
        }
        return .init(groups: groups, blocked: blocked, alreadySatisfiedCount: alreadySatisfiedCount)
    }

    /// Resolves a manifest-provided relative path without allowing archive
    /// traversal or an existing symlink to escape the current instance.
    static func destinationURL(for relativePath: String, under root: URL) throws -> URL {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw OfficialWebDownloadError.unsafeDestination(relativePath)
        }

        let standardizedRoot = root.standardizedFileURL
        let destination = standardizedRoot.appending(path: normalized).standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw OfficialWebDownloadError.unsafeDestination(relativePath)
        }

        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolvedDestination.path.hasPrefix(resolvedPrefix) else {
            throw OfficialWebDownloadError.unsafeDestination(relativePath)
        }

        // `resolvingSymlinksInPath()` is not guaranteed to traverse an
        // existing symlink when the final destination does not exist yet.
        // Check each supplied component as well, so `mods -> /outside` cannot
        // make a future `mods/file.jar` escape the instance.
        var traversedPath = standardizedRoot
        for component in components {
            traversedPath.appendPathComponent(String(component))
            let resolvedComponent = traversedPath.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedComponent.path.hasPrefix(resolvedPrefix) else {
                throw OfficialWebDownloadError.unsafeDestination(relativePath)
            }
        }
        return destination
    }

    static func isSHA1(_ value: String) -> Bool {
        guard value.count == 40 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }

    static func fileIsValid(at url: URL, sha1: String) -> Bool {
        guard isSHA1(sha1), FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileHash.verify(url, expected: sha1, algorithm: .sha1)) != nil
    }
}

struct OfficialWebDownloadQueue: Sendable {
    let parallelLimit: Int
    private(set) var pending: [OfficialWebDownloadGroup]
    private(set) var active: [OfficialWebDownloadGroup] = []
    private(set) var completedIDs = Set<String>()
    private(set) var failures: [String: String] = [:]

    init(groups: [OfficialWebDownloadGroup], parallelLimit: Int = 3) {
        self.parallelLimit = min(max(parallelLimit, 1), 3)
        self.pending = groups
    }

    mutating func startOrResume() -> [OfficialWebDownloadGroup] {
        fillActiveSlots()
        return active
    }

    mutating func markCompleted(_ id: String) -> [OfficialWebDownloadGroup] {
        active.removeAll { $0.id == id }
        completedIDs.insert(id)
        failures.removeValue(forKey: id)
        fillActiveSlots()
        return active
    }

    mutating func markFailed(_ id: String, reason: String) {
        failures[id] = reason
    }

    mutating func retry(_ id: String) {
        failures.removeValue(forKey: id)
    }

    mutating func pause() {
        pending = active + pending
        active.removeAll()
    }

    var isFinished: Bool { pending.isEmpty && active.isEmpty }

    private mutating func fillActiveSlots() {
        while active.count < parallelLimit, !pending.isEmpty {
            active.append(pending.removeFirst())
        }
    }
}

enum OfficialWebDownloadError: LocalizedError, Sendable {
    case unsafeDestination(String)
    case paused
    case noOfficialDownloads
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeDestination(path): "官方网页下载的目标路径不安全：\(path)"
        case .paused: "官方网页下载已暂停；已完成的文件会保留。"
        case .noOfficialDownloads: "没有可在官方页面继续下载的文件。"
        case let .downloadFailed(reason): "官方下载失败：\(reason)"
        }
    }
}

/// Validates a staged WebKit download and only then exposes it in the instance.
struct OfficialWebDownloadPlacementService {
    func place(
        stagedFile: URL,
        group: OfficialWebDownloadGroup,
        instanceRoot: URL
    ) throws {
        let manager = FileManager.default
        do {
            try FileHash.verify(stagedFile, expected: group.expectedSHA1, algorithm: .sha1)
        } catch {
            try? manager.removeItem(at: stagedFile)
            throw error
        }
        var stagedDestinations = Set<URL>()

        for record in group.records {
            let destination = try OfficialWebDownloadPlanner.destinationURL(for: record.destination, under: instanceRoot)
            guard stagedDestinations.insert(destination.standardizedFileURL).inserted else { continue }
            if OfficialWebDownloadPlanner.fileIsValid(at: destination, sha1: group.expectedSHA1) {
                continue
            }

            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporaryDestination = destination.deletingLastPathComponent()
                .appending(path: ".\(destination.lastPathComponent).pclofficial-\(UUID().uuidString)")
            do {
                try manager.copyItem(at: stagedFile, to: temporaryDestination)
                try FileHash.verify(temporaryDestination, expected: group.expectedSHA1, algorithm: .sha1)
                if manager.fileExists(atPath: destination.path) {
                    _ = try manager.replaceItemAt(destination, withItemAt: temporaryDestination, backupItemName: nil, options: [])
                } else {
                    try manager.moveItem(at: temporaryDestination, to: destination)
                }
            } catch {
                try? manager.removeItem(at: temporaryDestination)
                throw error
            }
        }
        try? manager.removeItem(at: stagedFile)
    }
}

struct OfficialWebDownloadActiveItem: Identifiable {
    enum State: Equatable {
        case waiting
        case automating
        case downloading
        case failed(String)

        var description: String {
            switch self {
            case .waiting: "等待在官方页面确认下载"
            case .automating: "正在通过无障碍自动化确认下载"
            case .downloading: "正在接收官方文件"
            case let .failed(reason): reason
            }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let group: OfficialWebDownloadGroup
    var reloadID = UUID()
    var state: State = .waiting

    var id: String { group.id }
}

/// Serializes placement against pause/cancel. `close()` waits for a currently
/// running placement before the importer is allowed to delete its instance.
private final class OfficialWebDownloadPlacementPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true

    func perform<T>(_ operation: () throws -> T) -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return nil }
        return Result(catching: operation)
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }
}

/// Identifies one concrete WebKit download attempt. Delegates must echo this
/// value back so a late callback from a reloaded page cannot affect the
/// replacement attempt for the same queue item.
struct OfficialWebDownloadAttempt: Hashable {
    let id: UUID
    let stagingURL: URL
}

private struct OfficialWebDownloadRegistration {
    let attempt: OfficialWebDownloadAttempt
    let download: WKDownload
}

/// Coordinates a small set of user-driven official browser downloads. It is
/// deliberately state-driven rather than awaiting the import task, so closing
/// its sheet leaves the existing import checkpoint recoverable.
@MainActor
final class OfficialWebDownloadCoordinator: ObservableObject {
    static let shared = OfficialWebDownloadCoordinator()

    @Published private(set) var activeItems: [OfficialWebDownloadActiveItem] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    /// Snapshot at queue creation. The setting is off by default and changes
    /// only affect later queues, so a visible session is never switched from
    /// manual to automated halfway through a download.
    @Published private(set) var browserAutomationEnabled = false
    @Published var isPresented = false

    private var queue: OfficialWebDownloadQueue?
    private var instanceRoot: URL?
    private var stagingDirectory: URL?
    private var downloads: [String: OfficialWebDownloadRegistration] = [:]
    private var placementPermit: OfficialWebDownloadPlacementPermit?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var isFinishing = false

    private init() {}

    func present(
        groups: [OfficialWebDownloadGroup],
        instanceRoot: URL,
        browserAutomationEnabled: Bool = false,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if self.completion != nil {
            pause(silently: true)
        }
        guard !groups.isEmpty else {
            completion(.failure(OfficialWebDownloadError.noOfficialDownloads))
            return
        }

        self.queue = .init(groups: groups, parallelLimit: 3)
        self.instanceRoot = instanceRoot
        self.stagingDirectory = SharedConstants.shared.temperatureURL
            .appending(path: "official-web-download-\(UUID().uuidString)")
        self.placementPermit = OfficialWebDownloadPlacementPermit()
        self.completion = completion
        self.isFinishing = false
        self.totalCount = groups.count
        self.completedCount = 0
        self.browserAutomationEnabled = browserAutomationEnabled
        self.activeItems = queue?.startOrResume().map { OfficialWebDownloadActiveItem(group: $0) } ?? []
        self.pendingCount = queue?.pending.count ?? 0
        self.isPresented = true
    }

    /// The delegate calls this only for a WKDownload delivered by the current
    /// page's WebKit instance. A second download for the same queue item is
    /// refused so it cannot replace an in-flight staging target.
    func stagingDestination(for groupID: String, download: WKDownload) -> OfficialWebDownloadAttempt? {
        guard activeItems.contains(where: { $0.id == groupID }),
              downloads[groupID] == nil,
              let stagingDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            fail(groupID: groupID, error: error)
            return nil
        }
        let attempt = OfficialWebDownloadAttempt(
            id: UUID(),
            stagingURL: stagingDirectory.appending(path: "\(groupID)-\(UUID().uuidString)")
        )
        downloads[groupID] = .init(attempt: attempt, download: download)
        return attempt
    }

    func downloadStarted(for groupID: String, attemptID: UUID) {
        guard registrationMatches(groupID, attemptID: attemptID) else { return }
        update(groupID) { $0.state = .downloading }
    }

    func browserAutomationStarted(for groupID: String, reloadID: UUID) {
        guard browserAutomationEnabled,
              let item = activeItems.first(where: { $0.id == groupID }),
              item.reloadID == reloadID,
              item.state == .waiting else { return }
        update(groupID) { $0.state = .automating }
    }

    func completeDownload(for groupID: String, attemptID: UUID, stagedFile: URL) {
        guard let group = activeItems.first(where: { $0.id == groupID })?.group,
              let instanceRoot,
              let placementPermit,
              let registration = downloads[groupID],
              registration.attempt.id == attemptID,
              registration.attempt.stagingURL.standardizedFileURL == stagedFile.standardizedFileURL else { return }

        let placementTask = Task.detached(priority: .userInitiated) { () -> Result<Void, Error>? in
            placementPermit.perform {
                try OfficialWebDownloadPlacementService().place(
                    stagedFile: stagedFile,
                    group: group,
                    instanceRoot: instanceRoot
                )
            }
        }
        Task { @MainActor [weak self] in
            guard let result = await placementTask.value,
                  let self,
                  self.placementPermit === placementPermit,
                  self.registrationMatches(groupID, attemptID: attemptID),
                  self.completion != nil else { return }
            switch result {
            case .success:
                self.markCompleted(groupID, attemptID: attemptID)
            case let .failure(error):
                self.fail(groupID: groupID, attemptID: attemptID, error: error)
            }
        }
    }

    func downloadFailed(for groupID: String, attemptID: UUID, error: Error) {
        guard registrationMatches(groupID, attemptID: attemptID) else { return }
        fail(groupID: groupID, attemptID: attemptID, error: error)
    }

    func pageFailed(for groupID: String, reloadID: UUID, error: Error) {
        guard let item = activeItems.first(where: { $0.id == groupID }),
              item.reloadID == reloadID,
              item.state == .waiting || item.state == .automating else { return }
        fail(groupID: groupID, error: error)
    }

    func retry(groupID: String) {
        queue?.retry(groupID)
        if let registration = downloads.removeValue(forKey: groupID) {
            registration.download.cancel { _ in }
            try? FileManager.default.removeItem(at: registration.attempt.stagingURL)
        }
        update(groupID) {
            $0.state = .waiting
            $0.reloadID = UUID()
        }
    }

    func pause() {
        pause(silently: false)
    }

    func sheetDismissed() {
        guard !isFinishing, completion != nil else { return }
        pause()
    }

    private func markCompleted(_ groupID: String, attemptID: UUID) {
        guard registrationMatches(groupID, attemptID: attemptID) else { return }
        downloads.removeValue(forKey: groupID)
        _ = queue?.markCompleted(groupID)
        completedCount += 1
        refreshActiveItems()
        if queue?.isFinished == true {
            finish(.success(()))
        }
    }

    private func fail(groupID: String, attemptID: UUID? = nil, error: Error) {
        if let attemptID, !registrationMatches(groupID, attemptID: attemptID) {
            return
        }
        downloads.removeValue(forKey: groupID)
        let message = error.localizedDescription
        queue?.markFailed(groupID, reason: message)
        update(groupID) { $0.state = .failed(message) }
    }

    private func refreshActiveItems() {
        let existing = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })
        activeItems = queue?.active.map { group in
            existing[group.id] ?? OfficialWebDownloadActiveItem(group: group)
        } ?? []
        pendingCount = queue?.pending.count ?? 0
    }

    private func update(_ groupID: String, mutate: (inout OfficialWebDownloadActiveItem) -> Void) {
        guard let index = activeItems.firstIndex(where: { $0.id == groupID }) else { return }
        mutate(&activeItems[index])
    }

    private func registrationMatches(_ groupID: String, attemptID: UUID) -> Bool {
        downloads[groupID]?.attempt.id == attemptID
    }

    private func pause(silently: Bool) {
        guard completion != nil else { return }
        queue?.pause()
        downloads.values.forEach { registration in
            registration.download.cancel { _ in }
        }
        finish(.failure(OfficialWebDownloadError.paused), setPresented: !silently)
    }

    private func finish(_ result: Result<Void, Error>, setPresented: Bool = true) {
        guard let completion else { return }
        self.completion = nil
        isFinishing = true
        if setPresented {
            isPresented = false
        }
        downloads.removeAll()
        placementPermit?.close()
        placementPermit = nil
        activeItems.removeAll()
        pendingCount = 0
        browserAutomationEnabled = false
        queue = nil
        instanceRoot = nil
        if let stagingDirectory {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        stagingDirectory = nil
        completion(result)
    }
}
