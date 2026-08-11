//
//  LiteLoaderInstaller.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 ModModpack.vb / ModMinecraft.vb 中 LiteLoader 安装逻辑。
//

import Foundation
import SwiftyJSON

private let liteLoaderMirrorRoot = URL(string: "https://bmclapi.bangbang93.com/maven/com/mumfrey/liteloader/")!

/// LiteLoader 的旧清单仍可能返回 HTTP Maven 地址。只升级已知官方仓库，
/// 未知的明文地址直接拒绝，避免重新放宽整个应用的 ATS 策略。
private func secureLiteLoaderRepositoryURL(_ rawValue: String) -> URL? {
    guard var components = URLComponents(string: rawValue), let host = components.host?.lowercased() else {
        return nil
    }
    if components.scheme?.lowercased() == "http" {
        guard ["repo.maven.apache.org", "repo1.maven.org", "dl.liteloader.com"].contains(host) else {
            return nil
        }
        components.scheme = "https"
    }
    guard components.scheme?.lowercased() == "https" else { return nil }
    return components.url
}

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
        // 旧清单可能提供 HTTP 地址；解析时已将已知仓库升级为 HTTPS。
        secureLiteLoaderRepositoryURL(repo.url) ?? liteLoaderMirrorRoot
    }
}

/// LiteLoader 安装器。
/// 数据源使用 BMCLAPI 的 HTTPS LiteLoader 清单镜像。
public enum LiteLoaderInstaller {
    private static let listURL = liteLoaderMirrorRoot.appending(path: "versions.json")

    /// 拉取版本清单（解析上游 LiteLoader 的 versions.json）。
    public static func fetchVersionList() async throws -> [LiteLoaderVersion] {
        let response = await Requests.get(listURL, category: .gameDownload)
        guard response.statusCode == 200 else {
            throw response.error ?? MyLocalizedError(reason: "LiteLoader 版本清单请求失败（HTTP \(response.statusCode)）")
        }
        let json = try response.getJSONOrThrow()
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
            guard let repositoryURL = secureLiteLoaderRepositoryURL(repo["url"].stringValue) else {
                debug("忽略包含不安全仓库地址的 LiteLoader 版本：\(mc)")
                continue
            }
            let r = LiteLoaderVersion.Repo(
                stream: repo["stream"].string ?? "RELEASE",
                type: repo["type"].string ?? "m2",
                url: repositoryURL.absoluteString
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
        guard let repositoryURL = secureLiteLoaderRepositoryURL(version.repo.url) else {
            throw MyLocalizedError(reason: "LiteLoader 下载地址无效")
        }
        let downloadURL = repositoryURL
            .appending(path: "com/mumfrey/liteloader")
            .appending(path: version.artefact)
            .appending(path: "\(version.artefact).jar")
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
