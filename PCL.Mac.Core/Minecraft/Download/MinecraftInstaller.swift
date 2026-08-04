//
//  MinecraftInstallerNew.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/31.
//

/**
 *                             _ooOoo_
 *                            o8888888o
 *                            88" . "88
 *                            (| -_- |)
 *                            O\  =  /O
 *                         ____/`---'\____
 *                       .'  \\|     |//  `.
 *                      /  \\|||  :  |||//  \
 *                     /  _||||| -:- |||||-  \
 *                     |   | \\\  -  /// |   |
 *                     | \_|  ''\---/''  |   |
 *                     \  .-\__  `-`  ___/-. /
 *                   ___`. .'  /--.--\  `. . __
 *                ."" '<  `.___\_<|>_/___.'  >'"".
 *               | | :  `- \`.;`\ _ /`;.`/ - ` : | |
 *               \  \ `-.   \_ __\ /__ _/   .-` /  /
 *          ======`-.____`-.___\_____/___.-`____.-'======
 *                             `=---='
 *          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
*/

import Foundation
import SwiftyJSON

public class MinecraftInstaller {
    private init() {}

    /// Installs a complete, launchable Minecraft instance and optionally applies
    /// the exact mod-loader version declared by a modpack.
    ///
    /// Unlike `createTask`, this entry point propagates every error to its caller,
    /// which lets modpack import roll back a half-created instance atomically.
    @discardableResult
    public static func install(
        _ minecraftVersion: MinecraftVersion,
        name: String,
        minecraftDirectory: MinecraftDirectory,
        loader: ClientBrand? = nil,
        loaderVersion: String? = nil,
        progress: ((Double, String) -> Void)? = nil
    ) async throws -> MinecraftInstance {
        let task = MinecraftInstallTask(
            minecraftVersion: minecraftVersion,
            minecraftDirectory: minecraftDirectory,
            name: name
        ) { _ in }

        try await downloadClientManifest(task)
        try Task.checkCancellation()
        progress?(0.08, "已下载游戏清单")
        try await downloadAssetIndex(task)
        try Task.checkCancellation()
        progress?(0.16, "已下载资源索引")
        updateProgress(task)
        try await downloadClientJar(task)
        try Task.checkCancellation()
        progress?(0.28, "已下载 Minecraft 客户端")

        if let loader {
            guard let loaderVersion, !loaderVersion.isEmpty else {
                throw MyLocalizedError(reason: "整合包没有提供 \(loader.getName()) 版本。")
            }
            switch loader {
            case .fabric:
                try await FabricInstaller.installFabric(
                    version: minecraftVersion,
                    minecraftDirectory: minecraftDirectory,
                    runningDirectory: task.versionURL,
                    loaderVersion
                )
            case .forge:
                guard let manifest = task.manifest else {
                    throw MyLocalizedError(reason: "客户端清单缺失，无法安装 Forge。")
                }
                try await ForgeInstaller(minecraftDirectory, task.versionURL, manifest).install(
                    minecraftVersion: minecraftVersion,
                    forgeVersion: loaderVersion
                )
            case .neoforge:
                guard let manifest = task.manifest else {
                    throw MyLocalizedError(reason: "客户端清单缺失，无法安装 NeoForge。")
                }
                try await NeoforgeInstaller(minecraftDirectory, task.versionURL, manifest).install(
                    minecraftVersion: minecraftVersion,
                    forgeVersion: loaderVersion
                )
            case .vanilla:
                break
            default:
                throw MyLocalizedError(reason: "暂不支持自动安装 \(loader.getName())。")
            }

            // Loader installers replace the version JSON.  Reparse it before
            // downloading libraries, otherwise only vanilla dependencies are
            // installed and the generated instance cannot launch.
            let manifestURL = task.versionURL.appending(path: "\(name).json")
            task.manifest = try ClientManifest.parse(url: manifestURL, minecraftDirectory: minecraftDirectory)
            guard task.manifest != nil else {
                throw MyLocalizedError(reason: "无法解析安装后的 \(loader.getName()) 客户端清单。")
            }
            try Task.checkCancellation()
            progress?(0.48, "已安装 \(loader.getName()) \(loaderVersion)")
        } else {
            progress?(0.48, "原版游戏环境已就绪")
        }

        modifyId(task)
        try await downloadHashResourcesFiles(task)
        try Task.checkCancellation()
        progress?(0.72, "已补全游戏资源")
        try await downloadLibraries(task)
        try Task.checkCancellation()
        progress?(0.86, "已补全运行库")
        try await downloadNatives(task)
        try Task.checkCancellation()
        try unzipNatives(task)
        progress?(0.96, "已准备本机依赖")
        finalWork(task)

        MinecraftInstance.clearCache(for: task.versionURL)
        guard let instance = MinecraftInstance.create(minecraftDirectory, task.versionURL) else {
            throw MyLocalizedError(reason: "Minecraft 安装完成，但生成的实例无法加载。")
        }
        progress?(1, "游戏环境安装完成")
        return instance
    }

    /// Downloads and validates all shared assets, libraries and natives required
    /// by an already imported instance.
    public static func complete(
        _ instance: MinecraftInstance,
        progress: ((Double, String) -> Void)? = nil
    ) async throws {
        let architecture: Architecture = Architecture.system == .x64
            ? .x64
            : (instance.isUsingRosetta ? .x64 : .arm64)
        guard let version = instance.version, let manifest = instance.manifest else {
            throw MyLocalizedError(reason: "实例缺少有效的 Minecraft 版本或客户端清单。")
        }
        let task = MinecraftInstallTask(
            minecraftVersion: version,
            minecraftDirectory: instance.minecraftDirectory,
            name: instance.name,
            architecture: architecture
        ) { _ in }
        task.manifest = manifest
        try await downloadAssetIndex(task)
        try Task.checkCancellation()
        progress?(0.15, "已读取资源索引")
        try await downloadClientJar(task)
        try Task.checkCancellation()
        progress?(0.30, "已补全客户端")
        try await downloadHashResourcesFiles(task)
        try Task.checkCancellation()
        progress?(0.65, "已补全游戏资源")
        try await downloadLibraries(task)
        try Task.checkCancellation()
        progress?(0.82, "已补全运行库")
        try await downloadNatives(task)
        try Task.checkCancellation()
        try unzipNatives(task)
        progress?(0.95, "已准备本机依赖")
        finalWork(task)
        progress?(1, "游戏依赖补全完成")
    }
    
    // MARK: 下载客户端清单
    private static func downloadClientManifest(_ task: MinecraftInstallTask) async throws {
        task.updateStage(.clientJson)
        let url = try DownloadSourceManager.shared.getClientManifestURL(task.minecraftVersion).unwrap("无法获取 \(task.minecraftVersion.displayName) 的 JSON 下载 URL。")
        let destination = task.versionURL.appending(path: "\(task.name).json")
        
        try await SingleFileDownloader.download(task: task, url: url, destination: destination, replaceMethod: .replace)
        task.completeOneFile()
        
        if let manifest: ClientManifest = try .parse(url: destination, minecraftDirectory: nil) {
            task.manifest = manifest
        } else {
            let content = try String(data: FileHandle(forReadingFrom: destination).readToEnd().unwrap(), encoding: .utf8).unwrap()
            err("无法解析客户端清单: \(content)")
            throw MyLocalizedError(reason: "无法解析客户端清单：\(content)")
        }
    }
    
    // MARK: 下载客户端本体
    private static func downloadClientJar(_ task: MinecraftInstallTask) async throws {
        task.updateStage(.clientJar)
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单尚未准备完成，无法获取客户端下载 URL。")
        }
        let url = try DownloadSourceManager.shared.getClientJARURL(task.minecraftVersion, manifest).unwrap("无法获取 \(task.minecraftVersion.displayName) 的客户端下载 URL。")
        
        try await SingleFileDownloader.download(
            task: task,
            url: url,
            destination: task.versionURL.appending(path: "\(task.name).jar")
        )
    }
    
    // MARK: 下载资源索引
    private static func downloadAssetIndex(_ task: MinecraftInstallTask) async throws {
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单缺失，无法下载资源索引。")
        }
        guard let assetIndex = manifest.assetIndex, !assetIndex.id.isEmpty else {
            throw MyLocalizedError(reason: "客户端清单缺少有效的 assetIndex。")
        }
        
        task.updateStage(.clientIndex)
        
        let url: URL = try DownloadSourceManager.shared.getAssetIndexURL(task.minecraftVersion, manifest).unwrap("无法获取 \(task.minecraftVersion.displayName) 的 assetIndex 下载 URL。")
        let destination: URL = task.minecraftDirectory.assetsURL.appending(component: "indexes").appending(component: "\(assetIndex.id).json")
        try await SingleFileDownloader.download(task: task, url: url, destination: destination)
        do {
            let data = try Data(contentsOf: destination)
            task.assetIndex = try .parse(data)
        } catch {
            err("在解析 JSON 时发生错误: \(error.localizedDescription)")
            throw MyLocalizedError(reason: "无法解析资源索引：\(error.localizedDescription)")
        }
    }
    
    // MARK: 下载散列资源文件
    private static func downloadHashResourcesFiles(_ task: MinecraftInstallTask) async throws {
        task.updateStage(.clientResources)
        guard let assetIndex = task.assetIndex else {
            throw MyLocalizedError(reason: "资源索引缺失，无法下载游戏资源。")
        }
        let objects = assetIndex.objects
        
        var urls: [URL] = []
        var destinations: [URL] = []
        
        for object in objects {
            urls.append(object.appendTo(URL(string: "https://resources.download.minecraft.net")!))
            destinations.append(object.appendTo(task.minecraftDirectory.assetsURL.appending(path: "objects")))
        }
        
        // MultiFileDownloader caps and serializes this batch.  A modest limit
        // avoids exhausting file descriptors on large asset indexes.
        try await MultiFileDownloader(task: task, urls: urls, destinations: destinations, concurrentLimit: MultiFileDownloader.maximumConcurrentDownloads).start()
    }
    
    // MARK: 下载依赖项
    private static func downloadLibraries(_ task: MinecraftInstallTask) async throws {
        task.updateStage(.clientLibraries)
        prepareManifest(task)

        // getNeededLibraries() 每次调用都要过滤一遍库表；取一次复用。
        let libraries = try task.manifest.unwrap().getNeededLibraries(for: task.architecture)
        // 下载源在一次安装内不变，循环外取一次即可（内部会读设置 + 可能测速）。
        let source = DownloadSourceManager.shared.getDownloadSource()

        var downloadedNames: Set<String> = []
        var items: [DownloadItem] = []

        for library in libraries {
            guard let artifact = library.artifact else { continue }
            let dest = task.minecraftDirectory.librariesURL.appending(path: artifact.path)
            let cacheKey = "\(library.name)#\(library.role.rawValue)#\(artifact.path)"
            if CacheStorage.default.copy(name: cacheKey, to: dest) {
                continue
            }
            guard let url = source.getLibraryURL(library) else { continue }
            downloadedNames.insert(library.name)
            items.append(.init(source, { _ in url }, destination: dest))
        }

        try await MultiFileDownloader(task: task, items: items).start()

        for library in libraries {
            if downloadedNames.contains(library.name), let artifact = library.artifact {
                let cacheKey = "\(library.name)#\(library.role.rawValue)#\(artifact.path)"
                CacheStorage.default.add(name: cacheKey, path: task.minecraftDirectory.librariesURL.appending(path: artifact.path))
            }
        }
    }
    
    // MARK: 下载本地库
    private static func downloadNatives(_ task: MinecraftInstallTask) async throws {
        task.updateStage(.natives)

        // 同 downloadLibraries：清单查询和下载源都在循环外取一次。
        let natives = try task.manifest.unwrap().getNeededNatives(for: task.architecture)
        let source = DownloadSourceManager.shared.getDownloadSource()

        var downloadedNames: Set<String> = []
        var items: [DownloadItem] = []

        for (library, artifact) in natives {
            let dest = task.minecraftDirectory.librariesURL.appending(path: artifact.path)
            let cacheKey = "\(library.name)#\(library.role.rawValue)#\(artifact.path)"
            if CacheStorage.default.copy(name: cacheKey, to: dest) {
                continue
            }
            guard let url = source.getLibraryURL(library) else { continue }
            downloadedNames.insert(library.name)
            items.append(.init(source, { _ in url }, destination: dest))
        }

        try? FileManager.default.createDirectory(at: task.versionURL.appending(path: "natives"), withIntermediateDirectories: true)
        try await MultiFileDownloader(task: task, items: items).start()

        for (library, artifact) in natives where downloadedNames.contains(library.name) {
            let cacheKey = "\(library.name)#\(library.role.rawValue)#\(artifact.path)"
            CacheStorage.default.add(name: cacheKey, path: task.minecraftDirectory.librariesURL.appending(path: artifact.path))
        }
    }
    
    // MARK: 解压本地库
    private static func unzipNatives(_ task: MinecraftInstallTask) throws {
        let nativesURL: URL = task.versionURL.appending(path: "natives")
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单缺失，无法解压本地库。")
        }
        for (_, native) in manifest.getNeededNatives(for: task.architecture) {
            let jarURL: URL = task.minecraftDirectory.librariesURL.appending(path: native.path)
            Util.unzip(archiveURL: jarURL, destination: nativesURL, replace: true)
        }

        // processLibs 会递归遍历整个 natives/ 目录、校验架构并清理非 dylib 文件。
        // 之前它在循环体内，于是每解压一个 jar 就重跑一整遍遍历 —— 全部解压完只做
        // 一次就够，结果完全相同。
        do {
            try processLibs(task, nativesURL)
        } catch {
            err("处理 natives 失败")
            throw error
        }
    }
    
    // MARK: 处理解压结果
    private static func processLibs(_ task: MinecraftInstallTask, _ nativesURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: nativesURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "dylib" || fileURL.pathExtension == "jnilib",
                  let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory != true else { continue }
            
            // 验证架构
            let arch = Architecture.getArchOfFile(fileURL)
            guard arch.isCompatiable(with: task.architecture) else {
                try? fileManager.removeItem(at: fileURL)
                log("已清除架构不匹配的可执行文件: \(fileURL.lastPathComponent)")
                continue
            }
            
            // 拷贝到 natives 根目录
            let destinationURL = nativesURL.appendingPathComponent(fileURL.lastPathComponent)
            if destinationURL == fileURL { continue }
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: fileURL, to: destinationURL)
        }
        
        // 清理非 dylib 文件
        let contents = try fileManager.contentsOfDirectory(at: nativesURL, includingPropertiesForKeys: nil)
        for fileURL in contents {
            if !fileURL.pathExtension.lowercased().hasSuffix("dylib") && !fileURL.pathExtension.lowercased().hasSuffix("jnilib") {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }
    
    // MARK: 收尾
    private static func finalWork(_ task: MinecraftInstallTask) {
        let _1_12_2 = MinecraftVersion(displayName: "1.12.2")
        // 拷贝 log4j2.xml
        let targetURL: URL = task.versionURL.appending(path: "log4j2.xml")
        try? FileManager.default.copyItem(
            at: SharedConstants.shared.applicationResourcesURL.appending(path: task.minecraftVersion >= _1_12_2 ? "log4j2.xml" : "log4j2-1.12-.xml"),
            to: targetURL
        )
        
        // 初始化实例
        let instance = MinecraftInstance.create(.init(rootURL: task.versionURL.parent().parent(), name: ""), task.versionURL, config: MinecraftConfig(version: task.minecraftVersion))
        
        instance?.saveConfig()
        
        // 修改 GLFW
        if let glfw = task.manifest?.getNeededLibraries(for: task.architecture).find({ $0.name.contains("lwjgl-glfw") }),
           let artifact = glfw.artifact {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/java")
            process.environment = ProcessInfo.processInfo.environment
            process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
            process.arguments = ["-jar", SharedConstants.shared.applicationResourcesURL.appending(path: "glfw-patcher.jar").path, task.minecraftDirectory.librariesURL.appending(path: artifact.path).path]
            do {
                try process.run()
                process.waitUntilExit()
                log("已修改 lwjgl-glfw")
            } catch {
                err("无法修改 lwjgl-glfw: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: 修改客户端清单中的 id
    private static func modifyId(_ task: MinecraftInstallTask) {
        do {
            let manifestURL = task.versionURL.appending(path: "\(task.versionURL.lastPathComponent).json")
            guard FileManager.default.fileExists(atPath: manifestURL.path),
                  let data = try FileHandle(forReadingFrom: manifestURL).readToEnd(),
                  var dict = try JSON(data: data).dictionaryObject else {
                return
            }
            
            dict["id"] = task.versionURL.lastPathComponent
            
            try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted).write(to: manifestURL)
            log("已修改客户端清单中的 id")
        } catch {
            err("无法修改 id: \(error.localizedDescription)")
        }
    }
    
    // MARK: 获取进度
    public static func updateProgress(_ task: MinecraftInstallTask) {
        DispatchQueue.main.async {
            guard let assetIndex = task.assetIndex, let manifest = task.manifest else {
                err("无法计算安装进度：客户端清单或资源索引缺失")
                task.totalFiles = 0
                task.remainingFiles = 0
                return
            }
            task.totalFiles = 3 + assetIndex.objects.count
                + manifest.getNeededLibraries(for: task.architecture).count
                + manifest.getNeededNatives(for: task.architecture).count
            log("总文件数: \(task.totalFiles)")
            task.remainingFiles = task.totalFiles - 2
        }
    }

    /// Dependency normalization is explicit and architecture-aware. Keeping it
    /// out of deduplication prevents a harmless merge from silently applying an
    /// x64 mapping to an arm64 install (or vice versa).
    private static func prepareManifest(_ task: MinecraftInstallTask) {
        guard let manifest = task.manifest else { return }
        ClientManifest.deduplicateLibraries(manifest)
        ArtifactVersionMapper.map(manifest, arch: task.architecture)
        ClientManifest.deduplicateLibraries(manifest)
    }
    
    // MARK: 创建任务
    public static func createTask(_ minecraftVersion: MinecraftVersion, _ name: String, _ minecraftDirectory: MinecraftDirectory, _ callback: (() -> Void)? = nil) -> InstallTask {
        let task = MinecraftInstallTask(minecraftVersion: minecraftVersion, minecraftDirectory: minecraftDirectory, name: name) { task in
            try await downloadClientManifest(task)
            try await downloadAssetIndex(task)
            prepareManifest(task)
            updateProgress(task)
            try await downloadClientJar(task)
            
            // 安装 Mod Loader
            if let fabricTask = DataManager.shared.inprogressInstallTasks?.tasks["fabric"] as? FabricInstallTask {
                await fabricTask.install(task)
            } else if let forgeTask = DataManager.shared.inprogressInstallTasks?.tasks["forge"] as? ForgeInstallTask {
                await forgeTask.install(task)
            } else if let neoforgeTask = DataManager.shared.inprogressInstallTasks?.tasks["neoforge"] as? NeoforgeInstallTask {
                await neoforgeTask.install(task)
            }

            // Forge/NeoForge 会替换客户端清单；必须重新解析后再下载依赖。
            // FabricInstallTask 已经做了这一步，重复解析不会改变结果。
            let manifestURL = task.versionURL.appending(path: "\(task.name).json")
            task.manifest = try ClientManifest.parse(url: manifestURL, minecraftDirectory: task.minecraftDirectory)
            guard task.manifest != nil else {
                throw MyLocalizedError(reason: "无法解析 Mod Loader 客户端清单。")
            }
            prepareManifest(task)
            updateProgress(task)
            
            modifyId(task)
            try await downloadHashResourcesFiles(task)
            try await downloadLibraries(task)
            try await downloadNatives(task)
            try unzipNatives(task)
            finalWork(task)
            callback?()
        }
        return task
    }
    
    // MARK: 创建补全资源任务
    public static func createCompleteTask(_ instance: MinecraftInstance, _ callback: (() -> Void)? = nil) -> InstallTask? {
        let arch: Architecture
        if Architecture.system == .x64 { arch = .x64 }
        else { arch = instance.isUsingRosetta ? .x64 : .arm64 }
        guard let version = instance.version, let manifest = instance.manifest else {
            err("无法创建资源补全任务：实例缺少版本或客户端清单")
            return nil
        }
        let task = MinecraftInstallTask(
            minecraftVersion: version,
            minecraftDirectory: instance.minecraftDirectory,
            name: instance.name,
            architecture: arch
        ) { task in
            task.manifest = manifest
            try await downloadAssetIndex(task)
            try await downloadClientJar(task)
            try await downloadHashResourcesFiles(task)
            try await downloadLibraries(task)
            try await downloadNatives(task)
            try unzipNatives(task)
            finalWork(task)
            task.complete()
            callback?()
        }
        return task
    }
}
