//
//  ModrinthProjectSearcher.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/12.
//

import Foundation
import SwiftyJSON

public enum ProjectType: String {
    case mod, modpack, resourcepack, shader
    
    public func getName() -> String {
        switch self {
        case .mod: "Mod"
        case .modpack: "整合包"
        case .resourcepack: "资源包"
        case .shader: "光影包"
        }
    }

    public var modrinthPath: String {
        switch self {
        case .mod: "mod"
        case .modpack: "modpack"
        case .resourcepack: "resourcepack"
        case .shader: "shader"
        }
    }
}

public class ModrinthProjectSearcher {
    public static let shared: ModrinthProjectSearcher = .init()
    
    public let dateFormatter: ISO8601DateFormatter
    private let dateFormatterLock = NSLock()
    private let dependencyCacheLock = NSLock()
    private var dependencyCache: [String: ProjectSummary?] = [:]
    
    private init() {
        self.dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parseDate(from value: String) -> Date? {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        if let date = dateFormatter.date(from: value) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
    
    public func get(_ id: String) async throws -> ProjectSummary {
        let json = try await Requests.get("https://api.modrinth.com/v2/project/\(id)", ignoredFailureStatusCodes: [404], category: .gameDownload).getJSONOrThrow()
        guard let summary = ProjectSummary(json: json) else {
            throw MyLocalizedError(reason: "Modrinth 项目响应格式异常：\(id)")
        }
        return summary
    }

    private func cachedDependency(_ id: String) -> (exists: Bool, summary: ProjectSummary?) {
        dependencyCacheLock.lock()
        defer { dependencyCacheLock.unlock() }
        guard let value = dependencyCache[id] else { return (false, nil) }
        return (true, value)
    }

    private func cacheDependency(_ summary: ProjectSummary?, for id: String) {
        dependencyCacheLock.lock()
        dependencyCache[id] = summary
        dependencyCacheLock.unlock()
    }
    
    private func getDependencies(_ json: JSON) async -> [ProjectDependency] {
        var dependencies: [ProjectDependency] = []
        for dependency in json["dependencies"].arrayValue {
            guard let projectId = dependency["project_id"].string else { continue }
            guard dependency["dependency_type"] != "incompatible" else { continue }
            
            let dependencySummary: ProjectSummary?
            let cached = cachedDependency(projectId)
            if cached.exists {
                dependencySummary = cached.summary
            } else {
                dependencySummary = try? await get(projectId)
                cacheDependency(dependencySummary, for: projectId)
            }
            
            if let dependencySummary = dependencySummary {
                dependencies.append(
                    .init(
                        summary: dependencySummary,
                        versionId: dependency["version_id"].string,
                        type: .init(rawValue: dependency["dependency_type"].stringValue) ?? .required
                    )
                )
            }
        }
        return dependencies
    }
    
    public func getVersion(_ version: String) async throws -> ProjectVersion {
        let json = try await Requests.get("https://api.modrinth.com/v2/version/\(version)", category: .gameDownload).getJSONOrThrow()
        guard let projectID = json["project_id"].string, !projectID.isEmpty else {
            throw MyLocalizedError(reason: "Modrinth 版本响应缺少 project_id")
        }
        let summary = try await get(projectID)
        return try await makeVersion(json: json, summary: summary)
    }

    private func makeVersion(json: JSON, summary: ProjectSummary) async throws -> ProjectVersion {
        let files = json["files"].arrayValue
        guard let updateDate = parseDate(from: json["date_published"].stringValue),
              let file = files.first(where: { $0["primary"].boolValue }) ?? files.first,
              let downloadURL = file["url"].url else {
            throw MyLocalizedError(reason: "Modrinth 版本响应缺少有效日期或下载地址")
        }

        return .init(
            versionId: json["id"].stringValue,
            projectType: summary.type,
            projectId: json["project_id"].stringValue,
            name: json["name"].stringValue,
            versionNumber: json["version_number"].stringValue,
            type: json["version_type"].stringValue,
            downloads: json["downloads"].intValue,
            updateDate: updateDate,
            gameVersions: json["game_versions"].arrayValue.map { MinecraftVersion(displayName: $0.stringValue) },
            loaders: json["loaders"].arrayValue.map { ClientBrand(rawValue: $0.stringValue) ?? .vanilla },
            dependencies: await getDependencies(json),
            downloadURL: downloadURL,
            downloadSHA1: file["hashes"]["sha1"].string
        )
    }

    public func getVersions(
        id: String,
        gameVersion: MinecraftVersion,
        loader: ClientBrand
    ) async throws -> [ProjectVersion] {
        let loaders = try jsonArrayString([loader.rawValue])
        let gameVersions = try jsonArrayString([gameVersion.displayName])
        let json = try await Requests.get(
            "https://api.modrinth.com/v2/project/\(id)/version",
            body: ["loaders": loaders, "game_versions": gameVersions],
            encodeMethod: .urlEncoded,
            category: .gameDownload
        ).getJSONOrThrow()
        let summary = try await get(id)
        var versions: [ProjectVersion] = []
        for versionJSON in json.arrayValue {
            versions.append(try await makeVersion(json: versionJSON, summary: summary))
        }
        return versions.sorted { $0.updateDate > $1.updateDate }
    }

    public struct InstalledVersionMatch: Sendable {
        public let projectID: String
        public let versionID: String
        public let versionNumber: String
        public let versionType: String
    }

    /// 使用 Modrinth 的 SHA-1 文件接口识别本地 JAR，避免按显示名称误配项目。
    public func matchVersionFiles(sha1Hashes: [String]) async throws -> [String: InstalledVersionMatch] {
        guard !sha1Hashes.isEmpty else { return [:] }
        let json = try await Requests.post(
            URL(string: "https://api.modrinth.com/v2/version_files")!,
            body: ["hashes": sha1Hashes, "algorithm": "sha1"],
            encodeMethod: .json,
            category: .gameDownload
        ).getJSONOrThrow()
        var result: [String: InstalledVersionMatch] = [:]
        for (hash, value) in json.dictionaryValue {
            guard let projectID = value["project_id"].string,
                  let versionID = value["id"].string else { continue }
            result[hash] = .init(
                projectID: projectID,
                versionID: versionID,
                versionNumber: value["version_number"].stringValue,
                versionType: value["version_type"].stringValue
            )
        }
        return result
    }

    private func jsonArrayString(_ values: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MyLocalizedError(reason: "无法编码 Modrinth 请求条件")
        }
        return string
    }
    
    public func getVersionMap(id: String) async throws -> ProjectVersionMap {
        let json = try await Requests.get("https://api.modrinth.com/v2/project/\(id)/version", category: .gameDownload).getJSONOrThrow()
        let versions = json.arrayValue
        guard let projectID = versions.first?["project_id"].string, !projectID.isEmpty else {
            return [:]
        }
        let summary = try await get(projectID)
        var versionMap: ProjectVersionMap = [:]
        
        for versionJSON in versions {
            let version = try await makeVersion(json: versionJSON, summary: summary)
            
            for gameVersion in version.gameVersions {
                for loader in version.loaders {
                    let key = ProjectPlatformKey(loader: loader, minecraftVersion: gameVersion)
                    if versionMap[key] == nil {
                        versionMap[key] = []
                    }
                    versionMap[key, default: []].append(version)
                }
            }
        }
        
        return versionMap
    }
    
    public func search(type: ProjectType, query: String, version: MinecraftVersion? = nil, loader: ClientBrand? = nil, limit: Int = 40) async throws -> [ProjectSummary] {
        var facets = [
            ["project_type:\(type)"],
        ]
        
        if let version = version {
            facets.append(["versions:\(version.displayName)"])
        }
        if let loader = loader {
            facets.append(["categories:\(loader.rawValue)"])
        }
        
        let facetsData = try JSONSerialization.data(withJSONObject: facets)
        guard let facetsString = String(data: facetsData, encoding: .utf8) else {
            throw MyLocalizedError(reason: "无法编码 Modrinth 搜索条件")
        }
        
        let json = try await Requests.get(
            "https://api.modrinth.com/v2/search",
            body: [
                "query": query,
                "facets": facetsString,
                "limit": limit
            ],
            encodeMethod: .urlEncoded
        ).getJSONOrThrow()
        
        return json["hits"].arrayValue.compactMap(ProjectSummary.init(json:))
    }
}
