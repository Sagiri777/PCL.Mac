//
//  LiteLoaderInstaller.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 ModModpack.vb / ModMinecraft.vb 中 LiteLoader 安装逻辑。
//

import Foundation
import SwiftyJSON

public struct LiteLoaderVersion: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(mcversion)-\(snapshot)" }
    public let mcversion: String
    public let snapshot: String   // "SNAPSHOT" 或 "RELEASE"
    public let artefact: String   // 主 artifact 名，如 "liteloader"
    let artefacts: [String: String]
    let repo: Repo
    let tweet: String?

    public struct Repo: Codable, Sendable, Hashable {
        let stream: String
        let type: String   // "m2" 或 "pom"
        let url: String
    }

    public var displayName: String {
        "LiteLoader \(mcversion) (\(snapshot))"
    }

    public var artifactURL: URL {
        // type=m2: 直接 maven URL
        // 例：http://repo.maven.apache.org/maven2/com/mumfrey/liteloader/<version>/liteloader-<version>.jar
        guard let url = URL(string: repo.url) else {
            return URL(string: "http://dl.liteloader.com/")!
        }
        return url
    }
}

/// LiteLoader 安装器。
/// 数据源：http://dl.liteloader.com/versions/versions.json
public enum LiteLoaderInstaller {
    private static let listURL = URL(string: "http://dl.liteloader.com/versions/versions.json")!

    /// 拉取版本清单（解析上游 LiteLoader 的 versions.json）。
    public static func fetchVersionList() async throws -> [LiteLoaderVersion] {
        let json = try await Requests.get(listURL).getJSONOrThrow()
        // versions.json 顶层是对象，其 "versions" 是 { "<mc版本>": { repo, artefacts, ... } }。
        // JSON 不能直接 as? [String: Any]，必须走 SwiftyJSON 的 .dictionaryValue，否则恒为 nil。
        let versions = json["versions"].dictionaryValue
        guard !versions.isEmpty else {
            throw MyLocalizedError(reason: "LiteLoader versions.json 格式异常")
        }
        var out: [LiteLoaderVersion] = []
        for (mc, info) in versions {
            let repo = info["repo"]
            let artefacts = info["artefacts"].dictionaryValue
            guard let artefact = artefacts["liteloader"]?.stringValue else { continue }
            let r = LiteLoaderVersion.Repo(
                stream: repo["stream"].string ?? "RELEASE",
                type: repo["type"].string ?? "m2",
                url: repo["url"].string ?? ""
            )
            let artMap = artefacts.mapValues { $0.stringValue }
            out.append(LiteLoaderVersion(
                mcversion: mc,
                snapshot: r.stream,
                artefact: artefact,
                artefacts: artMap,
                repo: r,
                tweet: info["tweet"].string
            ))
        }
        return out
    }

    public static func versions(forMC mc: String, in list: [LiteLoaderVersion]) -> [LiteLoaderVersion] {
        list.filter { $0.mcversion == mc }
    }

    /// 安装 LiteLoader。
    public static func install(_ version: LiteLoaderVersion, into instance: MinecraftInstance) async throws {
        let versionDirName = "\(version.mcversion)-LiteLoader"
        let versionDir = instance.runningDirectory.parent()
            .appending(path: versionDirName)
        let jarURL = versionDir.appending(path: "\(version.artefact).jar")
        let jsonURL = versionDir.appending(path: "\(versionDirName).json")

        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        // 1. 下载 jar
        let downloadURL = URL(string: "\(version.repo.url)/com/mumfrey/liteloader/\(version.artefact)/\(version.artefact).jar")!
        log("下载 LiteLoader: \(version.displayName)")
        try await SingleFileDownloader.download(url: downloadURL, destination: jarURL)

        // 2. 复制父版本 JSON
        let parentJSON = instance.runningDirectory.appending(path: "\(instance.name).json")
        guard let data = try? Data(contentsOf: parentJSON),
              var parent = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MyLocalizedError(reason: "无法读取父版本 JSON：\(parentJSON.path)")
        }
        parent["id"] = versionDirName
        parent["inheritsFrom"] = version.mcversion

        // 3. 把 LiteLoader jar 添加到 libraries
        var libraries = parent["libraries"] as? [[String: Any]] ?? []
        libraries.append([
            "name": "com.mumfrey:liteloader:\(version.artefact)",
            "downloads": [
                "artifact": [
                    "path": "com/mumfrey/liteloader/\(version.artefact)/\(version.artefact).jar",
                    "url": version.repo.url
                ]
            ]
        ])
        parent["libraries"] = libraries

        let newData = try JSONSerialization.data(withJSONObject: parent, options: [.prettyPrinted])
        try newData.write(to: jsonURL)

        // 4. 更新实例指向新版本
        instance.clientBrand = .liteLoader
        instance.saveConfig()
        log("LiteLoader 安装完成：\(versionDirName)")
    }
}
