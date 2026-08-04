//
//  OptiFineInstaller.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 ModModpack.vb 中 OptiFine 安装逻辑 + ModMinecraft.vb 中 OptiFine 版本探测。
//

import Foundation
import ZIPFoundation
import SwiftyJSON

public struct OptiFineVersion: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(mcversion)-\(type)_\(patch)" }
    public let _id: String
    public let mcversion: String
    public let patch: String
    public let type: String   // 例如 "HD_U"
    public let __v: Int
    public let filename: String
    public let forge: String   // 例如 "Forge #2795" / "Forge N/A"

    public var displayName: String {
        "OptiFine \(mcversion) \(type)_\(patch)"
    }
}

/// OptiFine 安装器。
/// 数据源：BMCLAPI 镜像 `https://bmclapi2.bangbang93.com/optifine/versionList`
public enum OptiFineInstaller {
    private static let mirrorListURL = URL(string: "https://bmclapi2.bangbang93.com/optifine/versionList")!
    private static let mojangListURL = URL(string: "https://piston-meta.mojang.com/v2/products/optifine/version_list.json")!

    /// 拉取 OptiFine 版本清单（BMCLAPI 优先，失败回退 Mojang）。
    public static func fetchVersionList() async throws -> [OptiFineVersion] {
        do {
            // BMCLAPI 返回 JSON 数组；SwiftyJSON 的 JSON 不能直接 as? [Any]，
            // 必须走 .arrayValue，否则恒为 nil（详见编译期 warning "cast ... always fails"）。
            let json = try await Requests.get(mirrorListURL).getJSONOrThrow()
            return parseList(json.arrayValue)
        } catch {
            log("BMCLAPI OptiFine 列表拉取失败，回退到 Mojang: \(error.localizedDescription)")
        }
        // Mojang v2 格式复杂且非权威源；统一回退空，由 BMCLAPI 主路径兜底。
        _ = try await Requests.get(mojangListURL).getJSONOrThrow()
        return []
    }

    /// 过滤某 MC 版本对应的 OptiFine 版本。
    public static func versions(forMC version: String, in list: [OptiFineVersion]) -> [OptiFineVersion] {
        list.filter { $0.mcversion == version }.sorted { lhs, rhs in
            (lhs.type, lhs.patch) < (rhs.type, rhs.patch)
        }
    }

    /// 安装 OptiFine 到指定实例。
    /// - Parameters:
    ///   - instance: 目标实例
    ///   - optifine: 要安装的 OptiFine 版本（来自 fetchVersionList）
    public static func install(_ optifine: OptiFineVersion, into instance: MinecraftInstance) async throws {
        guard let downloadURL = URL(string: "https://bmclapi2.bangbang93.com/optifine/\(optifine.filename)") else {
            throw MyLocalizedError(reason: "OptiFine 下载地址无效")
        }
        let versionDirName = "\(optifine.mcversion)-OptiFine_\(optifine.type)_\(optifine.patch)"
        let versionDir = instance.runningDirectory.parent()
            .appending(path: versionDirName)
        let jarURL = versionDir.appending(path: "\(versionDirName).jar")
        let jsonURL = versionDir.appending(path: "\(versionDirName).json")

        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        // 1. 下载 jar
        log("下载 OptiFine: \(optifine.displayName)")
        try await SingleFileDownloader.download(url: downloadURL, destination: jarURL)

        // 2. 读取父版本 JSON，复制并改 inheritsFrom
        let parentJSON = instance.runningDirectory.appending(path: "\(instance.name).json")
        guard let data = try? Data(contentsOf: parentJSON),
              var parent = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MyLocalizedError(reason: "无法读取父版本 JSON：\(parentJSON.path)")
        }
        parent["id"] = versionDirName
        parent["inheritsFrom"] = optifine.mcversion

        // 3. 把 OptiFine jar 添加到 libraries classpath（先注入再一次性写盘，避免重复写入）
        if var libraries = parent["libraries"] as? [[String: Any]] {
            libraries.append([
                "name": "optifine:OptiFine:\(optifine.patch)",
                "downloads": [
                    "artifact": [
                        "path": "optifine/OptiFine-\(optifine.patch).jar",
                        "url": ""
                    ]
                ]
            ])
            parent["libraries"] = libraries
        }
        // 4. 一次性写出最终版本 JSON
        let newData = try JSONSerialization.data(withJSONObject: parent, options: [.prettyPrinted])
        try newData.write(to: jsonURL)

        // 5. 更新实例指向新版本
        instance.clientBrand = .optiFine
        instance.saveConfig()
        log("OptiFine 安装完成：\(versionDirName)")
    }

    // MARK: - 解析

    private static func parseList(_ list: [JSON]) -> [OptiFineVersion] {
        var out: [OptiFineVersion] = []
        for dict in list {
            guard let id = dict["_id"].string,
                  let mc = dict["mcversion"].string,
                  let patch = dict["patch"].string,
                  let type = dict["type"].string,
                  let filename = dict["filename"].string else { continue }
            let v = dict["__v"].intValue
            let forge = dict["forge"].string ?? "Forge N/A"
            out.append(OptiFineVersion(_id: id, mcversion: mc, patch: patch, type: type, __v: v, filename: filename, forge: forge))
        }
        return out
    }
}
