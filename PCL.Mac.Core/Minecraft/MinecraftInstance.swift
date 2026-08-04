//
//  MinecraftVersion.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation
import SwiftyJSON
import ZIPFoundation
import Cocoa

public class MinecraftInstance: Identifiable, Equatable, Hashable {
    /// 实例缓存。`create` 会被 view init、`DataManager.defaultInstance` 以及
    /// `loadInnerInstances` 的后台 Task 同时调用，必须加锁：并发 miss 会重复跑
    /// 整套清单解析，还可能损坏字典。
    private static var cache: [URL : MinecraftInstance] = [:]
    private static let cacheLock = NSLock()


    private static let RequiredJava16: MinecraftVersion = MinecraftVersion(displayName: "21w19a", type: .snapshot)
    private static let RequiredJava17: MinecraftVersion = MinecraftVersion(displayName: "1.18-pre2", type: .snapshot)
    private static let RequiredJava21: MinecraftVersion = MinecraftVersion(displayName: "24w14a", type: .snapshot)
    
    public let runningDirectory: URL
    public let minecraftDirectory: MinecraftDirectory
    public let configPath: URL
    public private(set) var version: MinecraftVersion! = nil
    public var process: Process?
    public private(set) var manifest: ClientManifest!
    public var config: MinecraftConfig!
    public var clientBrand: ClientBrand!
    public var isUsingRosetta: Bool = false
    public var name: String { runningDirectory.lastPathComponent }
    
    public let id: UUID = UUID()
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: MinecraftInstance, rhs: MinecraftInstance) -> Bool {
        lhs.id == rhs.id
    }
    
    public static func create(_ minecraftDirectory: MinecraftDirectory, _ name: String, config: MinecraftConfig? = nil) -> MinecraftInstance? {
        create(minecraftDirectory, minecraftDirectory.versionsURL.appending(path: name), config: config)
    }
    
    public static func create(_ minecraftDirectory: MinecraftDirectory, _ runningDirectory: URL, config: MinecraftConfig? = nil) -> MinecraftInstance? {
        cacheLock.lock()
        let cached = cache[runningDirectory]
        cacheLock.unlock()
        if let cached { return cached }

        let instance: MinecraftInstance = .init(minecraftDirectory: minecraftDirectory, runningDirectory: runningDirectory, config: config)
        guard instance.setup() else {
            err("实例初始化失败")
            return nil
        }

        cacheLock.lock()
        // 解析期间可能有别的线程已经放进来了，以先到的为准，保证同一目录只有一个实例对象。
        if let raced = cache[runningDirectory] {
            cacheLock.unlock()
            return raced
        }
        cache[runningDirectory] = instance
        cacheLock.unlock()
        return instance
    }

    public static func clearCache(for runningDirectory: URL) {
        cacheLock.lock()
        cache.removeValue(forKey: runningDirectory)
        cacheLock.unlock()
        log("已清理实例缓存: \(runningDirectory.lastPathComponent)")
    }
    

    
    private init(minecraftDirectory: MinecraftDirectory, runningDirectory: URL, config: MinecraftConfig? = nil) {
        self.runningDirectory = runningDirectory
        self.minecraftDirectory = minecraftDirectory
        self.configPath = runningDirectory.appending(path: ".PCL_Mac.json")
        self.config = config
    }
    
    private func setup() -> Bool {
        // 若配置文件存在，从文件加载配置
        let hadConfigFile = FileManager.default.fileExists(atPath: configPath.path)
        if hadConfigFile {
            do {
                try loadConfig()
            } catch {
                err("无法加载配置: \(error.localizedDescription)")
                debug(configPath.path)
            }
        }
        // `loadConfig()` 已经把旧实例配置读入 self.config。原来的无条件赋值
        // 会在这里把它覆盖成空默认值，导致 Java、内存、跳过校验和版本信息在
        // 每次启动/打开实例时丢失。显式传入的 config 仍优先，损坏或缺失的旧
        // 配置才回退到默认值。
        if let config {
            self.config = config
        } else if self.config == nil {
            self.config = MinecraftConfig(version: nil)
        }

        if !loadManifest() { return false }

        var configChanged = !hadConfigFile
        if let version = self.config.minecraftVersion, !version.isEmpty {
            self.version = .init(displayName: version)
        } else {
            detectVersion()
            guard let detectedVersion = self.version else {
                err("实例配置和客户端清单都缺少有效的 Minecraft 版本")
                return false
            }
            self.config.minecraftVersion = detectedVersion.displayName
            configChanged = true
        }

        // 寻找可用 Java
        if self.config.javaURL == nil, let jvm = MinecraftInstance.findSuitableJava(requiredVersion: requiredJavaVersion) {
            self.config.javaURL = jvm.executableURL
            configChanged = true
        }

        // 只在配置真的变了才落盘。打开版本列表会为目录里每个实例调用一次 setup，
        // 无条件 saveConfig 意味着每次进入列表都要写 N 个 JSON 文件。
        if configChanged {
            self.saveConfig()
        }
        return true
    }
    
    public func loadConfig() throws {
        self.config = .init(try .init(data: Data(contentsOf: configPath)))
    }
    
    public func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            try FileManager.default.createDirectory(
                at: runningDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try encoder.encode(config).write(to: configPath, options: .atomic)
        } catch {
            err("无法保存配置: \(error.localizedDescription)")
        }
    }
    
    private static func getClientBrand(_ manifestString: String) -> ClientBrand {
        if manifestString.contains("neoforged") {
            return .neoforge
        } else if manifestString.contains("fabric") {
            return .fabric
        } else if manifestString.contains("forge") {
            return .forge
        } else {
            return .vanilla
        }
    }
    
    public static func getMinJavaVersion(_ version: MinecraftVersion) -> Int {
        if version >= RequiredJava21 {
            return 21
        } else if version >= RequiredJava17 {
            return 17
        } else if version >= RequiredJava16 {
            return 16
        } else {
            return 8
        }
    }
    
    /// 当前实例实际要求的 Java 主版本。新版 Minecraft 应以版本清单为准，
    /// 旧版清单缺少该字段时再回退到发布时间推断。
    public var requiredJavaVersion: Int {
        max(manifest?.javaVersion ?? 0, MinecraftInstance.getMinJavaVersion(version))
    }

    public static func findSuitableJava(_ version: MinecraftVersion) -> JavaVirtualMachine? {
        findSuitableJava(requiredVersion: getMinJavaVersion(version))
    }

    public static func findSuitableJava(requiredVersion: Int) -> JavaVirtualMachine? {
        let candidates = DataManager.shared.javaVirtualMachines
            .filter { !$0.isError && $0.version >= requiredVersion && $0.callMethod != .incompatible }
            .sorted {
                if ($0.callMethod == .direct) != ($1.callMethod == .direct) {
                    return $0.callMethod == .direct
                }
                return $0.version < $1.version
            }
        let suitableJava = candidates.first

        if suitableJava == nil {
            warn("未找到可用 Java")
            debug("最低 Java 版本: \(requiredVersion)")
        }

        return suitableJava
    }
    
    public func launch(_ launchOptions: LaunchOptions) async {
        if let account = launchOptions.account {
            launchOptions.playerName = account.name
            launchOptions.uuid = account.uuid
            log("正在登录")
            await account.putAccessToken(options: launchOptions)
            if case .yggdrasil = account {
                try? await MinecraftLauncher.downloadAuthlibInjector() // 后面改成可抛出 + 多阶段
            }
        }
        launchOptions.javaPath = config.javaURL

        guard loadManifest(), let manifest = self.manifest,
              self.version != nil,
              let javaPath = launchOptions.javaPath else {
            err("无法启动：实例配置、客户端清单或 Java 路径无效")
            hint("无法启动：请检查版本清单和 Java 设置。", .critical)
            return
        }

        if Architecture.getArchOfFile(javaPath).isCompatiableWithSystem() {
            ArtifactVersionMapper.map(manifest)
            isUsingRosetta = false
        } else {
            ArtifactVersionMapper.map(manifest, arch: .x64)
            isUsingRosetta = true
            warn("正在使用 Rosetta 运行 Minecraft")
        }

        if !config.skipResourcesCheck && !launchOptions.skipResourceCheck {
            log("正在进行资源完整性检查")
            await withCheckedContinuation { continuation in
                guard let task = MinecraftInstaller.createCompleteTask(self, continuation.resume) else {
                    continuation.resume()
                    return
                }
                task.start()
            }
            log("资源完整性检查完成")
        }
        
        guard let launcher = MinecraftLauncher(self) else {
            err("无法创建 Minecraft 启动器")
            hint("无法启动 Minecraft：启动器初始化失败。", .critical)
            return
        }
        launcher.launch(launchOptions) { exitCode in
            if exitCode != 0 {
                log("检测到非 0 退出代码")
                hint("检测到 Minecraft 出现错误，错误分析已开始……")
                Task {
                    if await PopupManager.shared.showAsync(
                        .init(.error, "Minecraft 出现错误", "很抱歉，PCL.Mac 暂时没有分析功能。\n如果要寻求帮助，请把错误报告文件发给对方，而不是发送这个窗口的照片或者截图。\n不要截图！不要截图！！不要截图！！！", [.ok, .init(label: "导出错误报告", style: .accent)])
                    ) == 1 {
                        let savePanel = NSSavePanel()
                        savePanel.title = "选择导出位置"
                        savePanel.prompt = "导出"
                        savePanel.allowedContentTypes = [.zip]
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-M-d_HH.mm.ss"
                        savePanel.nameFieldStringValue = "错误报告-\(formatter.string(from: .init()))"
                        guard let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
                            err("无法导出错误报告：没有可用的宿主窗口")
                            return
                        }
                        savePanel.beginSheetModal(for: hostWindow) { [weak self] result in
                            if result == .OK {
                                if let self, let url = savePanel.url {
                                    MinecraftCrashHandler.exportErrorReport(self, launcher, to: url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    @discardableResult
    private func loadManifest() -> Bool {
        do {
            let manifestPath = runningDirectory.appending(path: runningDirectory.lastPathComponent + ".json")
            
            let data = try Data(contentsOf: manifestPath)
            self.clientBrand = MinecraftInstance.getClientBrand(String(data: data, encoding: .utf8) ?? "")
            
            guard let manifest = try ClientManifest.parse(
                url: manifestPath, minecraftDirectory: minecraftDirectory
            ), !manifest.id.isEmpty else {
                err("客户端清单缺少有效的版本 id")
                return false
            }
            self.manifest = manifest
        } catch {
            err("无法加载客户端清单: \(error.localizedDescription)")
            return false
        }
        
        return true
    }
    
    private func detectVersion() {
        guard version == nil else {
            return
        }
        do {
            let archive = try Archive(url: runningDirectory.appending(path: "\(name).jar"), accessMode: .read)
            guard let entry = archive["version.json"] else {
                throw MyLocalizedError(reason: "version.json 不存在")
            }
            
            var data = Data()
            _ = try archive.extract(entry, consumer: { (chunk) in
                data.append(chunk)
            })
            
            let version = MinecraftVersion(displayName: try JSON(data: data)["id"].stringValue)
            self.version = version
        } catch {
            err("无法检测版本: \(error.localizedDescription)，正在使用清单版本")
            self.version = .init(displayName: manifest.id)
        }
    }
    
    public func getIconName() -> String {
        if self.clientBrand == .vanilla {
            return self.version.getIconName()
        }
        return "\(self.clientBrand.rawValue.capitalized)Icon"
    }
}

public struct MinecraftConfig: Codable {
    public var additionalLibraries: Set<String> = []
    public var javaURL: URL? {
        get {
            return javaURLString == "" ? nil : URL(fileURLWithPath: javaURLString)
        }
        set (value) {
            javaURLString = value?.path ?? ""
        }
    }
    public var skipResourcesCheck: Bool = false
    public var maxMemory: Int32 = 4096
    public var qualityOfService: QualityOfService = .default
    public var minecraftVersion: String?
    
    private var javaURLString: String
    
    enum CodingKeys: String, CodingKey {
        case additionalLibraries
        case javaURLString = "javaURL"
        case skipResourcesCheck
        case maxMemory
        case qualityOfService
        case minecraftVersion
    }
    
    public init(_ json: JSON) {
        self.additionalLibraries = .init(json["additionalLibraries"].array?.map { $0.stringValue } ?? [])
        self.javaURLString = json["javaURL"].stringValue // 旧版本字段
        self.skipResourcesCheck = json["skipResourcesCheck"].boolValue
        self.maxMemory = json["maxMemory"].int32 ?? 4096
        self.qualityOfService = .init(rawValue: json["qualityOfService"].intValue) ?? .default
        self.minecraftVersion = json["minecraftVersion"].stringValue
        if qualityOfService.rawValue == 0 {
            qualityOfService = .default
        }
    }
    
    public init(version: MinecraftVersion?) {
        self.minecraftVersion = version?.displayName
        self.javaURLString = ""
    }
}

public enum ClientBrand: String, Codable, Hashable {
    case vanilla = "vanilla"
    case fabric = "fabric"
    case quilt = "quilt"
    case forge = "forge"
    case neoforge = "neoforge"
    case optiFine = "optifine"
    case liteLoader = "liteloader"

    public func getName() -> String {
        switch self {
        case .neoforge: return "NeoForge"
        case .optiFine: return "OptiFine"
        case .liteLoader: return "LiteLoader"
        default: return self.rawValue.capitalized
        }
    }

    public var index: Int {
        switch self {
        case .vanilla: 0
        case .fabric: 1
        case .quilt: 2
        case .forge: 3
        case .neoforge: 4
        case .optiFine: 5
        case .liteLoader: 6
        }
    }
}

extension QualityOfService: @retroactive Codable { }
