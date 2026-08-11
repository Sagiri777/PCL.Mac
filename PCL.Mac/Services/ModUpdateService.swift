import Foundation

struct ModUpdateCandidate: Identifiable {
    var id: String { projectID }
    let projectID: String
    let modName: String
    let currentFileURL: URL
    let currentVersionID: String
    let currentVersionNumber: String
    let currentVersionType: String
    let targetVersion: ProjectVersion
    let requiredDependencies: [ProjectVersion]
}

struct ModUpdateReport {
    let checkedAt: Date
    let installedFileCount: Int
    let recognizedFileCount: Int
    let candidates: [ModUpdateCandidate]
    let warnings: [String]
}

enum ModUpdateError: LocalizedError {
    case gameIsRunning
    case unsafeModPath
    case destinationConflict(String)
    case invalidDownloadName
    case incompatibleDependency(String)

    var errorDescription: String? {
        switch self {
        case .gameIsRunning: "游戏运行时不能更新 Mod。"
        case .unsafeModPath: "更新计划包含实例 mods 目录之外的文件。"
        case .destinationConflict(let name): "目标文件 \(name) 已存在，更新已停止以避免覆盖其他 Mod。"
        case .invalidDownloadName: "Modrinth 返回了无效的下载文件名。"
        case .incompatibleDependency(let name): "必需依赖 \(name) 没有适用于当前实例的版本。"
        }
    }
}

enum ModUpdatePlanner {
    static func latestCompatibleVersion(
        currentVersionID: String,
        currentVersionType: String,
        versions: [ProjectVersion]
    ) -> ProjectVersion? {
        let allowedTypes: Set<String>
        switch currentVersionType {
        case "release": allowedTypes = ["release"]
        case "beta": allowedTypes = ["release", "beta"]
        default: allowedTypes = ["release", "beta", "alpha"]
        }
        let ordered = versions.sorted { $0.updateDate > $1.updateDate }
        guard let currentIndex = ordered.firstIndex(where: { $0.versionId == currentVersionID }),
              currentIndex > 0 else { return nil }
        return ordered[..<currentIndex].first { allowedTypes.contains($0.type) }
    }
}

enum ModUpdateService {
    private struct LocalModFile: Sendable {
        let url: URL
        let sha1: String
        let displayName: String
    }

    static func check(for instance: MinecraftInstance) async throws -> ModUpdateReport {
        let modsDirectory = instance.runningDirectory.appending(path: "mods")
        let localFiles = try await Task.detached(priority: .utility) {
            try scanLocalFiles(in: modsDirectory)
        }.value
        guard !localFiles.isEmpty else {
            return .init(
                checkedAt: Date(),
                installedFileCount: 0,
                recognizedFileCount: 0,
                candidates: [],
                warnings: []
            )
        }

        var matches: [String: ModrinthProjectSearcher.InstalledVersionMatch] = [:]
        for chunk in localFiles.map(\.sha1).chunked(size: 100) {
            let response = try await ModrinthProjectSearcher.shared.matchVersionFiles(sha1Hashes: chunk)
            matches.merge(response) { _, newest in newest }
        }
        let installedProjectIDs = Set(matches.values.map(\.projectID))
        var candidates: [ModUpdateCandidate] = []
        var warnings: [String] = []

        let recognizedFiles = localFiles.compactMap { file -> (LocalModFile, ModrinthProjectSearcher.InstalledVersionMatch)? in
            matches[file.sha1].map { (file, $0) }
        }
        let filesByProject = Dictionary(grouping: recognizedFiles, by: { $0.1.projectID })
        let duplicateProjectIDs = Set<String>(filesByProject.compactMap { projectID, files in
            guard files.count > 1 else { return nil }
            let names = files.map { $0.0.url.lastPathComponent }.joined(separator: "、")
            warnings.append("\(files[0].0.displayName)：检测到同一项目的多个文件（\(names)），为避免误删已跳过自动更新。")
            return projectID
        })

        for file in localFiles {
            guard let current = matches[file.sha1] else { continue }
            guard !duplicateProjectIDs.contains(current.projectID) else { continue }
            do {
                let versions = try await ModrinthProjectSearcher.shared.getVersions(
                    id: current.projectID,
                    gameVersion: instance.version,
                    loader: instance.clientBrand
                )
                guard let target = ModUpdatePlanner.latestCompatibleVersion(
                    currentVersionID: current.versionID,
                    currentVersionType: current.versionType,
                    versions: versions
                ) else { continue }
                let dependencies = try await requiredDependencies(
                    of: target,
                    installedProjectIDs: installedProjectIDs,
                    gameVersion: instance.version,
                    loader: instance.clientBrand
                )
                candidates.append(.init(
                    projectID: current.projectID,
                    modName: file.displayName,
                    currentFileURL: file.url,
                    currentVersionID: current.versionID,
                    currentVersionNumber: current.versionNumber,
                    currentVersionType: current.versionType,
                    targetVersion: target,
                    requiredDependencies: dependencies
                ))
            } catch {
                warnings.append("\(file.displayName)：\(error.localizedDescription)")
            }
        }

        return .init(
            checkedAt: Date(),
            installedFileCount: localFiles.count,
            recognizedFileCount: recognizedFiles.count,
            candidates: candidates.sorted {
                $0.modName.localizedStandardCompare($1.modName) == .orderedAscending
            },
            warnings: warnings
        )
    }

    static func install(_ candidates: [ModUpdateCandidate], for instance: MinecraftInstance) async throws {
        guard !candidates.isEmpty else { return }
        guard instance.process?.isRunning != true else { throw ModUpdateError.gameIsRunning }
        let modsDirectory = instance.runningDirectory.appending(path: "mods").standardizedFileURL
        try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
        for candidate in candidates {
            let current = candidate.currentFileURL.standardizedFileURL
            guard current.deletingLastPathComponent() == modsDirectory else {
                throw ModUpdateError.unsafeModPath
            }
        }

        var versionsByProject: [String: ProjectVersion] = [:]
        for candidate in candidates {
            versionsByProject[candidate.projectID] = candidate.targetVersion
            for dependency in candidate.requiredDependencies {
                versionsByProject[dependency.projectId] = dependency
            }
        }
        let versions = Array(versionsByProject.values)
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "pcl-mod-updates-\(UUID().uuidString)")
        let rollback = FileManager.default.temporaryDirectory
            .appending(path: "pcl-mod-updates-rollback-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: rollback)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)

        var stagedByProject: [String: URL] = [:]
        let downloadItems: [DownloadItem] = try versions.map { version in
            let fileName = try safeDownloadName(version.downloadURL)
            let stagedURL = staging.appending(path: "\(version.projectId)-\(fileName)")
            stagedByProject[version.projectId] = stagedURL
            return DownloadItem(
                version.downloadURL,
                stagedURL,
                sha1: version.downloadSHA1,
                fallbackURLs: []
            )
        }
        try await MultiFileDownloader(
            items: downloadItems,
            concurrentLimit: min(6, downloadItems.count),
            replaceMethod: .replace,
            networkCategory: .gameDownload
        ).start()

        _ = try await InstanceSnapshotService.shared.createSnapshot(
            for: instance,
            reason: candidates.count == 1 ? "更新 \(candidates[0].modName) 前" : "批量更新 \(candidates.count) 个 Mod 前"
        )

        let currentByProject = candidates.reduce(into: [String: URL]()) { result, candidate in
            result[candidate.projectID] = candidate.currentFileURL
        }
        var installedDestinations: [URL] = []
        var rollbackMoves: [(from: URL, to: URL)] = []
        do {
            for version in versions {
                guard let stagedURL = stagedByProject[version.projectId] else { continue }
                let fileName = try safeDownloadName(version.downloadURL)
                let destination = modsDirectory.appending(path: fileName)
                let currentURL = currentByProject[version.projectId]

                if FileManager.default.fileExists(atPath: destination.path), destination != currentURL {
                    throw ModUpdateError.destinationConflict(fileName)
                }
                if let currentURL, FileManager.default.fileExists(atPath: currentURL.path) {
                    let backup = rollback.appending(path: "\(version.projectId)-\(currentURL.lastPathComponent)")
                    try FileManager.default.moveItem(at: currentURL, to: backup)
                    rollbackMoves.append((backup, currentURL))
                }
                try FileManager.default.moveItem(at: stagedURL, to: destination)
                installedDestinations.append(destination)
            }
        } catch {
            installedDestinations.forEach { try? FileManager.default.removeItem(at: $0) }
            for move in rollbackMoves.reversed() where FileManager.default.fileExists(atPath: move.from.path) {
                try? FileManager.default.moveItem(at: move.from, to: move.to)
            }
            throw error
        }
    }

    private static func requiredDependencies(
        of version: ProjectVersion,
        installedProjectIDs: Set<String>,
        gameVersion: MinecraftVersion,
        loader: ClientBrand
    ) async throws -> [ProjectVersion] {
        var result: [ProjectVersion] = []
        var resolved = installedProjectIDs
        var pending = version.dependencies.filter { $0.type == .required }
        while !pending.isEmpty {
            let dependency = pending.removeFirst()
            let projectID = dependency.summary.projectId
            guard !resolved.contains(projectID) else { continue }
            // 先标记，既避免循环依赖，也避免同一依赖在队列中被重复请求。
            resolved.insert(projectID)
            let selected: ProjectVersion?
            if let versionID = dependency.versionId {
                selected = try await ModrinthProjectSearcher.shared.getVersion(versionID)
            } else {
                selected = try await ModrinthProjectSearcher.shared.getVersions(
                    id: projectID,
                    gameVersion: gameVersion,
                    loader: loader
                ).first
            }
            guard let selected,
                  selected.gameVersions.contains(gameVersion),
                  selected.loaders.contains(loader) else {
                throw ModUpdateError.incompatibleDependency(dependency.summary.name)
            }
            result.append(selected)
            pending.append(contentsOf: selected.dependencies.filter { $0.type == .required })
        }
        return result
    }

    private static func scanLocalFiles(in modsDirectory: URL) throws -> [LocalModFile] {
        guard FileManager.default.fileExists(atPath: modsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: modsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "jar" }
        .map { url in
            let parsedName = Mod.loadMod(url: url)?.name ?? ""
            let displayName = parsedName.isEmpty ? url.deletingPathExtension().lastPathComponent : parsedName
            return LocalModFile(url: url, sha1: try Util.sha1OfFile(url: url), displayName: displayName)
        }
    }

    private static func safeDownloadName(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.lowercased().hasSuffix(".jar") else {
            throw ModUpdateError.invalidDownloadName
        }
        return name
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
