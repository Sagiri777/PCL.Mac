//
//  MinecraftLauncher.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation
import Cocoa

public class MinecraftLauncher {
    private let instance: MinecraftInstance
    private let id = UUID()
    public let logURL: URL
    
    public init?(_ instance: MinecraftInstance) {
        self.instance = instance
        self.logURL = SharedConstants.shared.applicationSupportURL.appending(path: "GameLogs").appending(path: id.uuidString + ".log")
        try? FileManager.default.createDirectory(at: logURL.parent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
    }
    
    public func launch(_ options: LaunchOptions, _ callback: @MainActor @escaping (Int32) -> Void = { _ in }) {
        guard let javaPath = options.javaPath,
              let manifest = instance.manifest,
              !manifest.mainClass.isEmpty,
              let config = instance.config else {
            err("无法启动 Minecraft：Java 路径、客户端清单或实例配置无效")
            return
        }

        let process = Process()
        process.executableURL = javaPath
        process.environment = ProcessInfo.processInfo.environment
        var arguments = buildJvmArguments(options)
        arguments.append(manifest.mainClass)
        arguments.append(contentsOf: buildGameArguments(options))
        process.arguments = arguments
        let command = (javaPath.path + " " + arguments.joined(separator: " "))
            .replacingOccurrences(
                of: #"(?i)(--(?:auth[_-]?)?access[_-]?token(?:=|\s+))\S+"#,
                with: "$1<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(--client[_-]?token(?:=|\s+))\S+"#,
                with: "$1<redacted>",
                options: .regularExpression
            )
        debug(command)
        MinecraftCrashHandler.lastLaunchCommand = command
        process.currentDirectoryURL = instance.runningDirectory
        
        var qualityOfService = config.qualityOfService
        if qualityOfService.rawValue == 0 {
            instance.config.qualityOfService = .default
            qualityOfService = .default
        }
        process.qualityOfService = qualityOfService
        
        instance.process = process
        do {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let logHandle = try FileHandle(forWritingTo: logURL)
            try logHandle.seekToEnd()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

                // 整块一次写盘。之前是逐行 write + seekToEndOfFile，
                // Minecraft 启动时的日志洪峰下这就是每行一次系统调用。
                var buffer = ""
                for line in text.split(separator: "\n") {
                    let normalized = line.replacing("\t", with: "    ")
                    raw(normalized)
                    buffer += normalized + "\n"
                }
                if !buffer.isEmpty {
                    try? logHandle.write(contentsOf: Data(buffer.utf8))
                }
            }

            // 进程退出走 terminationHandler，不再用 waitUntilExit()。
            // waitUntilExit 会把当前线程占满整局游戏时长；它是从 SwiftUI 的 Task
            // 里调过来的，也就是长期霸占一个 Swift 并发协作线程池的线程。
            process.terminationHandler = { [weak instance] finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                try? logHandle.close()

                let status = finished.terminationStatus
                log("\(self.instance.name) 进程已退出, 退出代码 \(status)")
                if status == 0 {
                    debug("检测到退出代码为 0，已删除日志")
                    try? FileManager.default.removeItem(at: self.logURL)
                }
                Task { @MainActor in
                    instance?.process = nil
                    callback(status)
                }
            }

            try process.run()

            Task { // 轮询判断窗口是否出现
                while process.isRunning {
                    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
                    guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                        return
                    }

                    for info in windowInfoList {
                        if let windowPID = info["kCGWindowOwnerPID"] as? Int32,
                           windowPID == process.processIdentifier {
                            log("窗口已出现")
                            return
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            instance.process = nil
            err(error.localizedDescription)
        }
    }
    
    public func buildJvmArguments(_ options: LaunchOptions) -> [String] {
        guard let config = instance.config, let manifest = instance.manifest else { return [] }
        let values: [String: String] = [
            "natives_directory": instance.runningDirectory.appending(path: "natives").path,
            "launcher_name": "PCL.Mac",
            "launcher_version": SharedConstants.shared.version,
            "classpath": buildClasspath(),
            "classpath_separator": ":",
            "library_directory": instance.minecraftDirectory.librariesURL.path,
            "version_name": instance.name,
            "authlib_injector_path": SharedConstants.shared.authlibInjectorURL.path
        ]
        
        var args: [String] = [
            "-Xmx\(config.maxMemory)m",
            "-Djna.tmpdir=${natives_directory}"
        ]
        
        args.insert(contentsOf: options.yggdrasilArguments, at: 0)
        args.append(contentsOf: manifest.getArguments().getAllowedJVMArguments(targetArchitecture: targetArchitecture))
        
        return Util.replaceTemplateStrings(args, with: values)
    }
    
    private func buildClasspath() -> String {
        guard let manifest = instance.manifest else { return "" }
        // 去重
        ClientManifest.deduplicateLibraries(manifest)
        
        var urls: [URL] = []
        for library in manifest.getNeededLibraries(for: targetArchitecture) {
            if let artifact = library.artifact {
                urls.append(instance.minecraftDirectory.librariesURL.appending(path: artifact.path))
            }
        }
        urls.append(instance.runningDirectory.appending(path: "\(instance.name).jar"))

        return urls.map { $0.path }.joined(separator: ":")
    }
    
    func buildGameArguments(_ options: LaunchOptions) -> [String] {
        guard let manifest = instance.manifest else { return [] }
        let values: [String: String] = [
            "auth_player_name": options.playerName,
            "version_name": instance.version?.displayName ?? instance.name,
            "game_directory": instance.runningDirectory.path,
            "assets_root": instance.minecraftDirectory.assetsURL.path,
            "assets_index_name": manifest.assetIndex?.id ?? "",
            "auth_uuid": options.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "auth_access_token": options.accessToken,
            "user_type": "msa",
            "version_type": "PCL.Mac \(SharedConstants.shared.version)",
            "user_properties": "\"{}\""
        ]
        
        var args: [String] = []
        if options.isDemo {
            args.append("--demo")
        }
        
        var arguments = Util.replaceTemplateStrings(
            manifest.getArguments().getAllowedGameArguments(targetArchitecture: targetArchitecture),
            with: values
        ).union(args)
        if let serverAddress = options.serverAddress, !serverAddress.isEmpty {
            arguments.append(contentsOf: ["--server", serverAddress, "--port", String(options.serverPort)])
        }
        return arguments
    }

    private var targetArchitecture: Architecture {
        instance.isUsingRosetta ? .x64 : (Architecture.system == .arm64 ? .arm64 : .x64)
    }
    
    public static func downloadAuthlibInjector() async throws {
        if FileManager.default.fileExists(atPath: SharedConstants.shared.authlibInjectorURL.path) { return }
        let json = try await Requests.get("https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json").getJSONOrThrow()
        guard let downloadURL = json["download_url"].url else {
            throw MyLocalizedError(reason: "无效的 authlib-injector 下载 URL")
        }
        try await SingleFileDownloader.download(url: downloadURL, destination: SharedConstants.shared.authlibInjectorURL)
        log("authlib-injector 下载完成")
    }
}

public class LaunchState: ObservableObject {
    @Published public var isLaunched: Bool = false
}
