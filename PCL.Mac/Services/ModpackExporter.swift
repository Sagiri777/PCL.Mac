//
//  ModpackExporter.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 PageInstanceExport.xaml.vb / ModModpack.vb 中的整合包导出逻辑。
//  支持四种格式：Modrinth(.mrpack) / CurseForge / HMCL / 纯压缩。
//  采用“本地内容自包含”策略（与 PCL2 的“包含资源文件”选项一致）：
//  所有被选中的游戏目录子目录原样写入 overrides，无需联网回填下载地址。
//

import Foundation
import ZIPFoundation
import SwiftyJSON

public enum ModpackExporter {
    /// 整合包格式。与 PCL2 PageInstanceExport 提供的导出选项一一对应。
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case modrinth        // .mrpack（zip 内含 modrinth.index.json + overrides/）
        case curseforge      // .zip（zip 内含 manifest.json + overrides/）
        case hmcl           // .zip（zip 内含 manifest.json + override/）
        case compress       // .zip 纯压缩（无 manifest）

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .modrinth: return "Modrinth 整合包 (.mrpack)"
            case .curseforge: return "CurseForge 整合包 (.zip)"
            case .hmcl: return "HMCL 整合包 (.zip)"
            case .compress: return "纯压缩包 (.zip)"
            }
        }
        public var fileExtension: String {
            switch self {
            case .modrinth: return "mrpack"
            default: return "zip"
            }
        }
    }

    /// 导出选项，对应 PCL2 PageInstanceExport 上的勾选项。
    public struct Options {
        public var name: String
        public var version: String
        public var author: String
        public var format: Format = .modrinth
        public var includeMods: Bool = true
        public var includeConfig: Bool = true
        public var includeSaves: Bool = false
        public var includeResourcePacks: Bool = false
        public var includeShaderPacks: Bool = false
        public var includeShaderPackSettings: Bool = true
        public var includeVersionJSON: Bool = true   // 对应 PCL2“整合包配置文件”勾选

        public init(name: String, version: String = "1.0.0", author: String = "") {
            self.name = name
            self.version = version
            self.author = author
        }
    }

    /// 导出入口：把实例打包到 destURL。
    public static func export(instance: MinecraftInstance, options: Options, to destURL: URL) async throws {
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try destURL.ensureParentDirectoryExists()

        let contentFiles = collectContentFiles(instance: instance, options: options)
        let loaderInfo = loaderInfo(for: instance)

        let archive = try Archive(url: destURL, accessMode: .create)

        // 1. 写入资源文件（按格式决定 overrides 子目录前缀）。
        let overridesPrefix: String? = {
            switch options.format {
            case .modrinth, .curseforge: return "overrides/"
            case .hmcl: return "override/"
            case .compress: return nil
            }
        }()

        for file in contentFiles {
            let relInArchive: String = {
                if let prefix = overridesPrefix {
                    return prefix + file.relativePath
                } else {
                    return file.relativePath
                }
            }()
            try addFile(at: file.absoluteURL, as: relInArchive, into: archive)
        }

        // 2. 写入 manifest（压缩包无 manifest）。
        switch options.format {
        case .modrinth:
            let manifest = try buildModrinthManifest(instance: instance, options: options, files: contentFiles, loaderInfo: loaderInfo)
            try addData(manifest, as: "modrinth.index.json", into: archive)
        case .curseforge:
            let manifest = try buildCurseForgeManifest(instance: instance, options: options, loaderInfo: loaderInfo)
            try addData(manifest, as: "manifest.json", into: archive)
        case .hmcl:
            let manifest = try buildHMCLManifest(instance: instance, options: options, loaderInfo: loaderInfo)
            try addData(manifest, as: "manifest.json", into: archive)
        case .compress:
            break
        }

        log("整合包导出完成：\(destURL.path)（\(options.format.displayName)，\(contentFiles.count) 个文件）")
    }

    // MARK: - 内容收集

    /// 待打包的内容文件。relativePath 相对于 .minecraft 根目录。
    private struct ContentFile {
        let relativePath: String
        let absoluteURL: URL
    }

    private static func collectContentFiles(instance: MinecraftInstance, options: Options) -> [ContentFile] {
        // 游戏实际以 runningDirectory 作为 game_directory 启动，Mod、配置、存档等
        // 都属于当前实例。这里若从 minecraftDirectory.rootURL 收集，会误把共享目录中
        // 其它实例的内容打进整合包，也会漏掉当前隔离实例的文件。
        let root = instance.runningDirectory
        // 对应 PageInstanceExport 中可选的子目录，以及“整合包配置文件”。
        let gameSubdirs: [(name: String, enabled: Bool, excludes: [String])] = [
            ("mods",            options.includeMods,            [".Disabled"]),
            ("config",           options.includeConfig,          []),
            ("saves",            options.includeSaves,           []),
            ("resourcepacks",    options.includeResourcePacks,   []),
            ("shaderpacks",       options.includeShaderPacks,     []),
        ]
        var out: [ContentFile] = []
        let fm = FileManager.default
        for (sub, enabled, excludes) in gameSubdirs where enabled {
            let dir = root.appendingPathComponent(sub)
            guard fm.fileExists(atPath: dir.path) else { continue }
            var files = walk(dir: dir, root: root, excludes: excludes)
            if sub == "shaderpacks" {
                let settingNames = shaderPackSettingNames(in: dir)
                files.removeAll { file in
                    guard let settingName = topLevelShaderPackSettingName(file.relativePath) else {
                        return false
                    }
                    return !options.includeShaderPackSettings || !settingNames.contains(settingName)
                }
            }
            out.append(contentsOf: files)
        }
        if options.includeVersionJSON {
            // 对应 PCL2“整合包配置文件”：连同版本 JSON 一起带出，便于他人复现。
            let versionJSON = instance.runningDirectory.appendingPathComponent("\(instance.name).json")
            if fm.fileExists(atPath: versionJSON.path),
               isSafeArchivePath("versions/\(instance.name)/\(instance.name).json") {
                out.append(ContentFile(
                    relativePath: "versions/\(instance.name)/\(instance.name).json",
                    absoluteURL: versionJSON
                ))
            }
            let versionJar = instance.runningDirectory.appendingPathComponent("\(instance.name).jar")
            if fm.fileExists(atPath: versionJar.path),
               isSafeArchivePath("versions/\(instance.name)/\(instance.name).jar") {
                out.append(ContentFile(
                    relativePath: "versions/\(instance.name)/\(instance.name).jar",
                    absoluteURL: versionJar
                ))
            }
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    /// PCL 2.13.1.1 只导出已选择光影包对应的设置文件。
    /// Iris/OptiFine 使用 `<光影包文件名>.txt`（例如 `pack.zip.txt`）保存设置；
    /// 文件夹形式的光影包则对应 `<文件夹名>.txt`。
    private static func shaderPackSettingNames(in directory: URL) -> Set<String> {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return Set(entries.compactMap { entry in
            guard entry.pathExtension.lowercased() != "txt",
                  let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true
                    || (values.isRegularFile == true && ["zip", "rar"].contains(entry.pathExtension.lowercased())) else {
                return nil
            }
            return entry.lastPathComponent + ".txt"
        })
    }

    /// 若路径是 `shaderpacks/` 直属的 txt 文件，则返回文件名；嵌套在光影包
    /// 文件夹中的 txt 属于光影包自身内容，不应被“光影包设置”开关过滤。
    private static func topLevelShaderPackSettingName(_ relativePath: String) -> String? {
        let prefix = "shaderpacks/"
        guard relativePath.hasPrefix(prefix) else { return nil }
        let nestedPath = String(relativePath.dropFirst(prefix.count))
        guard !nestedPath.contains("/"), nestedPath.lowercased().hasSuffix(".txt") else {
            return nil
        }
        return nestedPath
    }

    private static func walk(dir: URL, root: URL, excludes: [String]) -> [ContentFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [ContentFile] = []
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in enumerator {
            guard let isRegular = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isRegular else { continue }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedURL.path.hasPrefix(resolvedRoot + "/") else { continue }
            // 排除被禁用的 mod（如 mods/.disabled/ 之类）。
            let rel = String(resolvedURL.path.dropFirst(resolvedRoot.count + 1))
            guard isSafeArchivePath(rel) else { continue }
            if excludes.contains(where: { rel.contains($0) }) { continue }
            out.append(ContentFile(relativePath: rel, absoluteURL: resolvedURL))
        }
        return out
    }

    // MARK: - Loader 信息（从已安装版本 JSON 的 libraries 推断，避免臆造版本号）

    private struct LoaderInfo {
        let minecraft: String
        let fabricLoader: String?
        let quiltLoader: String?
        let forge: String?        // Forge 通常以 <mc>-<forge版本> 形式
        let neoforge: String?
        let brand: ClientBrand
    }

    private static func loaderInfo(for instance: MinecraftInstance) -> LoaderInfo {
        var fabric: String?
        var quilt: String?
        var forge: String?
        var neoforge: String?
        for lib in instance.manifest?.libraries ?? [] {
            switch (lib.groupId, lib.artifactId) {
            case ("net.fabricmc", "fabric-loader"): fabric = lib.version
            case ("org.quiltmc", "quilt-loader"):    quilt = lib.version
            case ("net.minecraftforge", "forge"):   forge = lib.version
            case ("net.neoforged", "neoforge"):      neoforge = lib.version
            default: break
            }
        }
        return LoaderInfo(
            minecraft: instance.version?.displayName ?? instance.config?.minecraftVersion ?? "",
            fabricLoader: fabric,
            quiltLoader: quilt,
            forge: forge,
            neoforge: neoforge,
            brand: instance.clientBrand ?? .vanilla
        )
    }

    // MARK: - Manifest 构造

    private static func buildModrinthManifest(instance: MinecraftInstance, options: Options, files: [ContentFile], loaderInfo: LoaderInfo) throws -> Data {
        let filesArray: [[String: Any]] = files.map { f in
            let sha1 = (try? FileHash.compute(f.absoluteURL, algorithm: .sha1)) ?? ""
            let sha512 = (try? FileHash.compute(f.absoluteURL, algorithm: .sha512)) ?? ""
            let size = (try? f.absoluteURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // env：mods 在客户端默认必需、服务端可选；其余可两边都可选。
            let isMod = f.relativePath.hasPrefix("mods/")
            let env: [String: String] = isMod
                ? ["client": "required", "server": "optional"]
                : ["client": "optional", "server": "optional"]
            return [
                "path": f.relativePath,
                "hashes": ["sha1": sha1, "sha512": sha512],
                "downloads": [String](),
                "fileSize": size,
                "env": env,
            ]
        }
        var deps: [String: String] = ["minecraft": loaderInfo.minecraft]
        if let v = loaderInfo.fabricLoader { deps["fabric-loader"] = v }
        if let v = loaderInfo.quiltLoader { deps["quilt-loader"] = v }
        if let v = loaderInfo.neoforge { deps["neoforge"] = v }
        if let v = loaderInfo.forge { deps["forge"] = v }

        let manifest: [String: Any] = [
            "formatVersion": 1,
            "game": "minecraft",
            "versionId": options.version.isEmpty ? "1.0.0" : options.version,
            "name": options.name,
            "summary": "",
            "files": filesArray,
            "dependencies": deps,
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    private static func buildCurseForgeManifest(instance: MinecraftInstance, options: Options, loaderInfo: LoaderInfo) throws -> Data {
        let modLoaders: [[String: Any]] = {
            var out: [[String: Any]] = []
            if let v = loaderInfo.fabricLoader { out.append(["id": "fabric-\(v)", "primary": true]) }
            else if let v = loaderInfo.quiltLoader { out.append(["id": "quilt-\(v)", "primary": true]) }
            else if let v = loaderInfo.neoforge { out.append(["id": "neoforge-\(v)", "primary": true]) }
            else if let v = loaderInfo.forge { out.append(["id": "forge-\(v)", "primary": true]) }
            // loader 版本无法解析时留空：导入方需自行补装 loader（与 PCL2 行为一致）。
            return out
        }()
        let manifest: [String: Any] = [
            "minecraft": [
                "version": loaderInfo.minecraft,
                "modLoaders": modLoaders,
            ],
            "manifestType": "minecraftModpack",
            "manifestVersion": 1,
            "name": options.name,
            "version": options.version.isEmpty ? "1.0.0" : options.version,
            "author": options.author,
            "files": [[String: Any]](),   // 本地自包含：mods 直接在 overrides，按需人工补 CurseForge fileID。
            "overrides": "overrides",
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    private static func buildHMCLManifest(instance: MinecraftInstance, options: Options, loaderInfo: LoaderInfo) throws -> Data {
        let modLoaders: [[String: Any]] = {
            var out: [[String: Any]] = []
            if let v = loaderInfo.fabricLoader { out.append(["id": "fabric-loader-\(v)", "primary": true]) }
            else if let v = loaderInfo.quiltLoader { out.append(["id": "quilt-loader-\(v)", "primary": true]) }
            else if let v = loaderInfo.neoforge { out.append(["id": "neoforge-\(v)", "primary": true]) }
            else if let v = loaderInfo.forge { out.append(["id": "forge-\(v)", "primary": true]) }
            return out
        }()
        var mcinfo: [String: Any] = [
            "version": loaderInfo.minecraft,
            "modLoaders": modLoaders,
        ]
        if let v = loaderInfo.fabricLoader { mcinfo["fabricLoader"] = ["version": v] }
        if let v = loaderInfo.forge { mcinfo["forge"] = ["version": v] }
        if let v = loaderInfo.neoforge { mcinfo["neoforge"] = ["version": v] }
        if loaderInfo.brand == .liteLoader { mcinfo["liteloaderVersion"] = ["version": loaderInfo.minecraft] }
        let manifest: [String: Any] = [
            "manifestType": "minecraftModpack",
            "manifestVersion": 2,
            "name": options.name,
            "version": options.version.isEmpty ? "1.0.0" : options.version,
            "author": options.author,
            "minecraft": mcinfo,
            "files": [[String: Any]](),
            "overrideTotalSize": 0,
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    // MARK: - 归档写入辅助

    private static func addFile(at url: URL, as path: String, into archive: Archive) throws {
        guard isSafeArchivePath(path) else {
            throw MyLocalizedError(reason: "整合包导出路径不安全：\(path)")
        }
        let data = try Data(contentsOf: url)
        try archive.addEntry(with: path, type: .file,
                             uncompressedSize: Int64(data.count)) { _, _ in data }
    }

    private static func addData(_ data: Data, as path: String, into archive: Archive) throws {
        guard isSafeArchivePath(path) else {
            throw MyLocalizedError(reason: "整合包导出路径不安全：\(path)")
        }
        try archive.addEntry(with: path, type: .file,
                             uncompressedSize: Int64(data.count)) { _, _ in data }
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { return false }
        return !normalized.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
