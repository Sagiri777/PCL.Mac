//
//  MinecraftDirectory.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/30.
//

import Foundation

public class MinecraftDirectory: Codable, Identifiable, Hashable {
    public static let `default`: MinecraftDirectory = .init(rootURL: .applicationSupportDirectory.appending(path: "minecraft"), name: "默认文件夹")
    
    public var id: UUID
    public let rootURL: URL
    public var name: String
    public var instances: [InstanceInfo] = []

    /// 加载状态机（用普通 var 即可；reload 完成会通过 DataManager.shared.objectWillChange.send()
    /// 主动通知所有订阅者）：
    /// - isLoading: 当前正在 IO；调用方应在看到这个状态时显示转圈 / spinner。
    /// - loadError: 上一次加载抛出的错误；UI 据此决定显示重试按钮 vs "无内容"占位。
    /// 关键不变量：一次 loadInnerInstances 结束（成功或失败）后，isLoading 必须回 false，
    /// loadError 与 instances 必须与之一致。**永远不要让 isLoading 在 await 后还停留在 true**，
    /// 否则 VersionListView 会一直挂在 "加载中……"。
    public var isLoading: Bool = false
    public var loadError: String? = nil
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rootURL)
    }
    
    public var versionsURL: URL {
        rootURL.appendingPathComponent("versions")
    }
    
    public var assetsURL: URL {
        rootURL.appendingPathComponent("assets")
    }
    
    public var librariesURL: URL {
        rootURL.appendingPathComponent("libraries")
    }
    
    public init(rootURL: URL, name: String) {
        self.id = .init()
        self.rootURL = rootURL
        self.name = name
    }
    
    enum CodingKeys: CodingKey {
        case id
        case rootURL
        case name
    }
    
    public static func == (lhs: MinecraftDirectory, rhs: MinecraftDirectory) -> Bool {
        lhs.rootURL == rhs.rootURL
    }
    
    public func loadInnerInstances(callback: (([InstanceInfo]) -> Void)? = nil) {
        instances.removeAll()
        loadError = nil
        isLoading = true
        // 立刻发一次，让 UI 知道我们进入加载态
        DataManager.shared.objectWillChange.send()

        let directoryURL = versionsURL
        let fm = FileManager.default
        Task {
            // 目录里没有 versions/ 子目录 —— 视为合法的"空状态"，不是错误。
            // 这样用户加一个全新的目录进来就不会被卡在"加载失败"上。
            if !fm.fileExists(atPath: directoryURL.path) {
                await MainActor.run {
                    self.isLoading = false
                    DataManager.shared.objectWillChange.send()
                    callback?(self.instances)
                }
                return
            }
            do {
                let contents = try fm.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                let instanceDirectories = contents.filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: url.appending(path: "\(url.lastPathComponent).json").path)
                    // A recoverable modpack import may already contain a valid
                    // runtime JSON, but it is not a launchable instance until
                    // all declared files and overrides are present.
                    && !fm.fileExists(atPath: url.appending(path: ".PCL_Mac_import.json").path)
                }
                // 先在后台把所有实例解析完，再一次性推给 UI。
                // 原来每个实例一次 MainActor.run，N 个实例就是 N 次跳转 +
                // N 次全界面失效（instances 变化会经 objectWillChange 传播）。
                var loadedInstances: [InstanceInfo] = []
                loadedInstances.reserveCapacity(instanceDirectories.count)
                for instanceDirectory in instanceDirectories {
                    if let instance = MinecraftInstance.create(self, instanceDirectory) {
                        loadedInstances.append(
                            InstanceInfo(
                                minecraftDirectory: self,
                                icon: instance.getIconName(),
                                name: instance.name,
                                version: instance.version,
                                runningDirectory: instanceDirectory,
                                brand: instance.clientBrand
                            )
                        )
                    }
                }
                let finalInstances = loadedInstances

                await MainActor.run {
                    self.instances = finalInstances
                    self.isLoading = false
                    DataManager.shared.objectWillChange.send()
                    callback?(self.instances)
                }
            } catch {
                // ❗关键：catch 路径必须显式 resolve 状态，否则 UI 会一直停在"加载中"。
                // 之前这个分支只写 err 日志就返回，是导致 VersionListView 永远转圈的根因。
                let message = error.localizedDescription
                await MainActor.run {
                    self.loadError = message
                    self.isLoading = false
                    DataManager.shared.objectWillChange.send()
                    err("读取版本目录失败: \(message)")
                    callback?(self.instances)
                }
            }
        }
    }
}

public struct InstanceInfo: Identifiable, Hashable {
    /// 用实例目录做标识，而不是每次 init 生成新的 UUID。
    /// 后者会让列表每次重新加载都产生全新的 ForEach 身份，导致整段列表重建 + 重播入场动画。
    public var id: URL { runningDirectory }
    public let minecraftDirectory: MinecraftDirectory
    public let icon: String
    public let name: String
    public let version: MinecraftVersion
    public let runningDirectory: URL
    public let brand: ClientBrand
}
