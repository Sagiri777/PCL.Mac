//
//  MinecraftCrashHandler.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/14.
//  Extended with PCL-compatible crash pattern analysis 2026-07-22.
//

import Foundation
import ZIPFoundation

// MARK: - CrashReason 枚举

/// 已知的崩溃原因。对应 PCL 上游 ModCrash.vb 中 `CrashReason` 枚举。
public enum CrashReason: String, Codable, Sendable, CaseIterable {
    case javaVersionTooHigh = "Java 版本过高"
    case javaVersionTooLow = "Java 版本过低"
    case usingJDK = "使用了 JDK（JRE 才是游戏所需的）"
    case usingOpenJ9 = "使用了 OpenJ9（不受支持，请使用 HotSpot）"
    case optifineIncompatibleWithForge = "OptiFine 与当前版本的 Forge 不兼容"
    case modConfigCorrupted = "Mod 配置文件导致游戏崩溃"
    case javaArgsInvalid = "Java 虚拟机参数有误"
    case duplicateForgeInJson = "版本 JSON 中存在多个 Forge"
    case openGLUnsupported = "显卡不支持 OpenGL"
    case intelGraphicsWorkaround = "Mojang 的 Intel 显卡性能补丁引发问题"
    case extractedModJars = "Mod 文件被错误地解压，请使用 .jar 格式"
    case forgeCrashed = "Forge 报错"
    case fabricCrashedWithSolution = "Fabric 报错并给出解决方案"
    case mixinFailed = "Mixin 注入失败"
    case suspectedMod = "怀疑某个 Mod 导致崩溃"
    case modLoaderFailed = "Mod 加载器报错"
    case modInitFailed = "Mod 初始化失败"
    case specificBlock = "特定方块导致崩溃"
    case specificEntity = "特定实体导致崩溃"
    case modIncompatible = "Mod 与当前 Minecraft 版本不兼容"
    case missingDependency = "缺少 Mod 依赖"
    case windowsNativeLibrary = "Mod 尝试在 macOS 加载 Windows DLL"
    case nativeArchitectureMismatch = "原生组件与游戏进程架构不兼容"
    case noModInstalled = "未安装 Mod，不进行堆栈分析"
    case unknown = "未知崩溃原因"

    /// 修复建议（中文）
    public var solution: String {
        switch self {
        case .javaVersionTooHigh:
            return "请安装 Java 17 或 Java 21。OpenJDK 21 + macOS Apple Silicon 是推荐组合。"
        case .javaVersionTooLow:
            return "Minecraft 1.17+ 需要 Java 17+；1.20.5+ 推荐 Java 21。请到设置 → Java 安装。"
        case .usingJDK:
            return "JRE 才是游戏所需的。请用 JRE 而不是 JDK，或在设置 → Java 里选择带 JRE 的 JDK。"
        case .usingOpenJ9:
            return "OpenJ9 与 Minecraft 不兼容。请使用 HotSpot 实现的 OpenJDK / Temurin / Zulu。"
        case .optifineIncompatibleWithForge:
            return "该 OptiFine 版本与 Forge 不兼容。尝试更新 Forge 到推荐版本，或换用 Embeddium / Rubidium。"
        case .modConfigCorrupted:
            return "删除 config/<modid>.json 后重启游戏，或恢复该 Mod 的默认配置。"
        case .javaArgsInvalid:
            return "检查启动参数。常见错误：手滑输入了非法的 -X... / -D... 参数。"
        case .duplicateForgeInJson:
            return "删除 versions/<ver>/*.json 中多余的 forgeVersion 条目；或重新安装 Forge。"
        case .openGLUnsupported:
            return "更新显卡驱动；macOS 13+ 已默认支持 Metal/OpenGL 4.1，但极旧 Intel HD Graphics 可能不够。"
        case .intelGraphicsWorkaround:
            return "在启动参数添加 -Dforge.forceVanillaLighting=true 或删除 MojangTricksIntelDriversForPerformance_javaw。"
        case .extractedModJars:
            return "mods/ 下的文件必须是 .jar 格式而不是解压后的文件夹。重新下载为 .jar。"
        case .forgeCrashed:
            return "查看完整堆栈信息；常见原因是 Mod 与 Minecraft 版本不兼容。"
        case .fabricCrashedWithSolution:
            return "Fabric Loader 已经给出建议；按其提示操作即可。"
        case .mixinFailed:
            return "通常是 Mod 的 Mixin 与当前 Minecraft / Loader 不兼容。尝试删除冲突的 Mod。"
        case .suspectedMod:
            return "Forge crash-report 已列出怀疑的 Mod。临时移除 mods/<name>.jar 后重试。"
        case .modLoaderFailed:
            return "Forge / Fabric / NeoForge 加载链失败。检查启动参数、Java 版本、Mod 完整性。"
        case .modInitFailed:
            return "某个 Mod 初始化失败。看崩溃报告的 \"Suspected Mod\" 段，临时移除对应 Mod。"
        case .specificBlock:
            return "某个方块（多半是 Mod 添加的）导致崩溃。删除对应世界或替换该方块。"
        case .specificEntity:
            return "某个实体（多半是 Mod 添加的）导致崩溃。删除对应世界。"
        case .modIncompatible:
            return "Mod 与当前 Minecraft 版本不兼容。更新 Mod 或降级 Minecraft。"
        case .missingDependency:
            return "缺少某个 Mod 依赖。安装完整依赖后重试。"
        case .windowsNativeLibrary:
            return "PCL.Mac 会在下次启动前定位并可逆隔离已确认的 Windows-only Mod；也可在版本设置的 Mod 页面查看证据。"
        case .nativeArchitectureMismatch:
            return "选择与原生组件一致的 Java 架构；只有 x86_64 macOS 组件时，可让整个游戏通过 Rosetta 运行。"
        case .noModInstalled:
            return "未安装任何 Mod，不需要排查 Mod 问题。"
        case .unknown:
            return "暂未匹配到已知模式。请把崩溃日志提交到 https://github.com/PCL-Community/PCL.Mac/issues。"
        }
    }
}

// MARK: - CrashReport 数据模型

public struct CrashReport: Sendable {
    /// 主要原因（按可能性从高到低）
    public let primaryReasons: [CrashReason]
    /// 详细堆栈分析出的可能 Mod 列表
    public let suspectedMods: [String]
    /// Fabric 给出的官方修复建议
    public let fabricSolutions: [String]
    /// 涉及的崩溃日志文件路径
    public let logFiles: [URL]
    /// Java 检测
    public let javaVersion: String?
    /// Minecraft 检测
    public let minecraftVersion: String?
    /// Mod Loader 检测
    public let modLoader: String?
    /// 完整原始分析（用于调试）
    public let rawAnalysis: String

    public init(primaryReasons: [CrashReason],
                suspectedMods: [String],
                fabricSolutions: [String],
                logFiles: [URL],
                javaVersion: String?,
                minecraftVersion: String?,
                modLoader: String?,
                rawAnalysis: String) {
        self.primaryReasons = primaryReasons
        self.suspectedMods = suspectedMods
        self.fabricSolutions = fabricSolutions
        self.logFiles = logFiles
        self.javaVersion = javaVersion
        self.minecraftVersion = minecraftVersion
        self.modLoader = modLoader
        self.rawAnalysis = rawAnalysis
    }

    public var summary: String {
        var lines: [String] = []
        if !primaryReasons.isEmpty {
            lines.append("主要崩溃原因（按可能性排序）：")
            for r in primaryReasons {
                lines.append("• \(r.rawValue)")
                lines.append("    建议：\(r.solution)")
            }
        }
        if !suspectedMods.isEmpty {
            lines.append("怀疑的 Mod：\(suspectedMods.joined(separator: ", "))")
        }
        if !fabricSolutions.isEmpty {
            lines.append("Fabric 建议：")
            for s in fabricSolutions { lines.append("• \(s)") }
        }
        if let j = javaVersion { lines.append("Java 版本：\(j)") }
        if let m = minecraftVersion { lines.append("Minecraft 版本：\(m)") }
        if let ml = modLoader { lines.append("Mod Loader：\(ml)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - MinecraftCrashHandler

public class MinecraftCrashHandler {
    public static var lastLaunchCommand: String = "未设置"

    // MARK: - 错误报告导出（原功能保留）

    public static func exportErrorReport(_ instance: MinecraftInstance, _ launcher: MinecraftLauncher, to destination: URL) {
        log("以下是 PCL.Mac 检测到的环境信息:")
        log("架构: \(Architecture.system)")
        log("分支: \(SharedConstants.shared.branch)")
        if let javaURL = instance.config?.javaURL {
            log("Java 架构: \(Architecture.getArchOfFile(javaURL))")
        } else {
            warn("无法确定 Java 架构：实例未配置有效 Java")
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: instance.runningDirectory.appending(path: "natives"),
                includingPropertiesForKeys: nil
            )
            for fileURL in contents {
                if fileURL.pathExtension != "dylib" { continue }
                log("\(fileURL.lastPathComponent) 架构: \(Architecture.getArchOfFile(fileURL))")
            }
        } catch {
            err("无法获取本地库: \(error.localizedDescription)")
        }

        debug("正在导出错误报告")

        let tmp = TemperatureDirectory(name: "ErrorReport")
        try? FileManager.default.createDirectory(at: tmp.root, withIntermediateDirectories: true)

        tmp.createFile(path: "启动命令.command", data: lastLaunchCommand.data(using: .utf8))

        try? FileManager.default.copyItem(at: SharedConstants.shared.logURL, to: tmp.root.appending(path: "PCL.Mac 启动器日志.log"))
        try? FileManager.default.copyItem(at: launcher.logURL, to: tmp.root.appending(path: "游戏崩溃前的输出.txt"))
        copyGameLogs(instance: instance, report: tmp.root)

        try? FileManager.default.copyItem(at: instance.runningDirectory.appending(path: instance.name + ".json"), to: tmp.root.appending(path: instance.name + ".json"))
        try? FileManager.default.zipItem(at: tmp.root, to: destination, shouldKeepParent: false)
        debug("错误报告导出完成")
        try? FileManager.default.removeItem(at: launcher.logURL)
        Util.clearTemp()
    }

    private static func copyGameLogs(instance: MinecraftInstance, report: URL) {
        let logsURL = instance.runningDirectory.appending(path: "logs")
        try? FileManager.default.copyItem(at: logsURL.appending(path: "latest.log"), to: report.appending(path: "latest.log"))
        try? FileManager.default.copyItem(at: logsURL.appending(path: "debug.log"), to: report.appending(path: "debug.log"))

        do {
            let files = try FileManager.default.contentsOfDirectory(at: instance.runningDirectory.appending(path: "crash-reports"), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])

            let latestReport = files
                .filter { $0.hasDirectoryPath == false }
                .max(by: {
                    let date0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let date1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return date0 < date1
                })

            if let latestFile = latestReport {
                try FileManager.default.copyItem(at: latestFile, to: report.appending(path: latestFile.lastPathComponent))
            }
        } catch {
            err("无法复制 crash-report: \(error.localizedDescription)")
        }
    }

    // MARK: - 崩溃分析（新功能）

    /// 分析一个 Minecraft 实例的崩溃。
    /// 自动从 `latest.log`、`debug.log`、`crash-reports/*.txt`、`hs_err_pid*.log` 收集日志，
    /// 匹配上游 ModCrash.vb 1121 行的所有已知模式。
    public static func analyze(instance: MinecraftInstance) -> CrashReport {
        let runningDir = instance.runningDirectory
        let logsDir = runningDir.appending(path: "logs")
        let crashReportsDir = runningDir.appending(path: "crash-reports")

        var logFiles: [URL] = []
        var combinedLog = ""

        // 1. 收集 latest.log
        let latestLog = logsDir.appending(path: "latest.log")
        if let text = try? String(contentsOf: latestLog, encoding: .utf8) {
            combinedLog += "\n=== latest.log ===\n" + text
            logFiles.append(latestLog)
        }
        // 2. 收集 debug.log
        let debugLog = logsDir.appending(path: "debug.log")
        if let text = try? String(contentsOf: debugLog, encoding: .utf8) {
            combinedLog += "\n=== debug.log ===\n" + text
            logFiles.append(debugLog)
        }
        // 3. 收集 crash-reports/*.txt（最新一份）
        var crashReport = ""
        if let files = try? FileManager.default.contentsOfDirectory(at: crashReportsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let latest = files.filter { $0.pathExtension == "txt" }
                .max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast <
                       (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast }
            if let l = latest, let text = try? String(contentsOf: l, encoding: .utf8) {
                crashReport = text
                combinedLog += "\n=== \(l.lastPathComponent) ===\n" + text
                logFiles.append(l)
            }
        }
        // 4. 收集 hs_err_pid*.log（HotSpot 崩溃转储）
        var hsErrLog = ""
        if let files = try? FileManager.default.contentsOfDirectory(at: runningDir, includingPropertiesForKeys: nil) {
            let hs = files.filter { $0.lastPathComponent.hasPrefix("hs_err") }
            for f in hs {
                if let text = try? String(contentsOf: f, encoding: .utf8) {
                    hsErrLog += text + "\n"
                    logFiles.append(f)
                }
            }
        }
        combinedLog += "\n=== hs_err_pid*.log ===\n" + hsErrLog

        return analyze(logText: combinedLog, hsErr: hsErrLog, mcCrash: crashReport, mcLog: (try? String(contentsOf: latestLog, encoding: .utf8)) ?? "")
    }

    /// 给定已加载的日志文本做分析（便于单元测试）。
    public static func analyze(logText: String, hsErr: String, mcCrash: String, mcLog: String) -> CrashReport {
        var rawAnalysis: [String] = []
        var reasons: [CrashReason] = []
        var fabricSolutions: [String] = []
        var suspectedMods: [String] = []

        // 把全部文本当成 "LogAll"，下游模式匹配用
        let logAll = (mcLog) + "\n" + hsErr + "\n" + mcCrash

        // ----- Java 版本 -----
        if mcLog.contains("Unable to make protected final java.lang.Class java.lang.ClassLoader.defineClass")
            || mcLog.contains("java.lang.NoSuchFieldException: ucp")
            || mcLog.contains("because module java.base does not export")
            || mcLog.contains("ClassNotFoundException: jdk.nashorn.api.scripting.NashornScriptEngineFactory")
            || mcLog.contains("ClassNotFoundException: java.lang.invoke.LambdaMetafactory") {
            reasons.append(.javaVersionTooHigh)
            rawAnalysis.append("matched: java-version-too-high")
        }
        if mcLog.contains("UnsupportedClassVersionError") || mcLog.contains("Unsupported major.minor version") {
            reasons.append(.javaVersionTooLow)
            rawAnalysis.append("matched: java-version-too-low")
        }
        if mcLog.contains("java.lang.ClassCastException: java.base/jdk")
            || mcLog.contains("java.lang.ClassCastException: class jdk.") {
            reasons.append(.usingJDK)
            rawAnalysis.append("matched: using-jdk")
        }
        if mcLog.contains("Open J9 is not supported")
            || mcLog.contains("OpenJ9 is incompatible")
            || mcLog.contains(".J9VMInternals.") {
            reasons.append(.usingOpenJ9)
            rawAnalysis.append("matched: using-openj9")
        }

        // ----- OptiFine / Forge 不兼容 -----
        let optifineIncompatiblePatterns = [
            "NoSuchMethodError: 'void net.minecraft.client.renderer.texture.SpriteContents.<init>",
            "NoSuchMethodError: 'java.lang.String com.mojang.blaze3d.systems.RenderSystem.getBackendDescription",
            "NoSuchMethodError: 'void net.minecraft.client.renderer.block.model.BakedQuad.<init>",
            "NoSuchMethodError: 'void net.minecraftforge.client.gui.overlay.ForgeGui.renderSelectedItemName",
            "NoSuchMethodError: 'void net.minecraft.server.level.DistanceManager",
            "NoSuchMethodError: 'net.minecraft.network.chat.FormattedText net.minecraft.client.gui.Font.ellipsize"
        ]
        for pattern in optifineIncompatiblePatterns {
            if mcLog.contains(pattern) {
                reasons.append(.optifineIncompatibleWithForge)
                rawAnalysis.append("matched: optifine-incompatible (\(pattern.prefix(40))...)")
                break
            }
        }

        // ----- Mod 配置文件 -----
        if mcCrash.contains("Failed loading config file ") {
            reasons.append(.modConfigCorrupted)
            rawAnalysis.append("matched: mod-config-corrupted")
        }

        // ----- Java 参数 -----
        if mcLog.contains("Unrecognized option:") {
            reasons.append(.javaArgsInvalid)
            rawAnalysis.append("matched: java-args-invalid")
        }
        if mcLog.contains("Found multiple arguments for option fml.forgeVersion, but you asked for only one") {
            reasons.append(.duplicateForgeInJson)
            rawAnalysis.append("matched: duplicate-forge-in-json")
        }

        // ----- macOS 原生组件 -----
        let nativeLog = logAll.lowercased()
        if nativeLog.contains("unsatisfiedlinkerror") && nativeLog.contains(".dll") {
            reasons.append(.windowsNativeLibrary)
            rawAnalysis.append("matched: windows-native-library")
            let pattern = #"([A-Za-z0-9_+.\-]+\.dll)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: logAll, range: NSRange(logAll.startIndex..., in: logAll)),
               let range = Range(match.range(at: 1), in: logAll) {
                suspectedMods.append(String(logAll[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let architectureMarkers = [
            "mach-o, but wrong architecture",
            "no suitable image found",
            "incompatible architecture",
            "have 'x86_64', need 'arm64'",
            "have 'arm64', need 'x86_64'"
        ]
        if architectureMarkers.contains(where: nativeLog.contains) {
            reasons.append(.nativeArchitectureMismatch)
            rawAnalysis.append("matched: native-architecture-mismatch")
        }

        // ----- 显卡 -----
        if mcLog.contains("The driver does not appear to support OpenGL") {
            reasons.append(.openGLUnsupported)
            rawAnalysis.append("matched: opengl-unsupported")
        }
        if mcLog.contains("MojangTricksIntelDriversForPerformance_javaw") {
            reasons.append(.intelGraphicsWorkaround)
            rawAnalysis.append("matched: intel-graphics-workaround")
        }

        // ----- Mod 文件被解压 -----
        if mcLog.contains("The directories below appear to be extracted jar files. Fix this before you continue.")
            || mcLog.contains("Extracted mod jars found, loading will NOT continue") {
            reasons.append(.extractedModJars)
            rawAnalysis.append("matched: extracted-mod-jars")
        }

        // ----- Forge 报错 -----
        if mcLog.contains("An exception was thrown, the game will display an error screen and halt.") {
            reasons.append(.forgeCrashed)
            rawAnalysis.append("matched: forge-crashed")
        }

        // ----- Fabric 报错（带建议）-----
        let fabricMarkers = [
            "A potential solution has been determined:",
            "A potential solution has been determined, this may resolve your problem:",
            "确定了一种可能的解决方法，这样做可能会解决你的问题："
        ]
        for marker in fabricMarkers {
            if mcLog.contains(marker) {
                reasons.append(.fabricCrashedWithSolution)
                rawAnalysis.append("matched: fabric-crashed-with-solution (\(marker.prefix(30))...)")
                // 简单提取 - 后的内容
                if let range = mcLog.range(of: marker) {
                    let after = String(mcLog[range.upperBound...])
                    for line in after.split(separator: "\n").prefix(8) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("- ") {
                            fabricSolutions.append(String(trimmed.dropFirst(2)))
                        } else if trimmed.isEmpty { break }
                        else if !fabricSolutions.isEmpty { break }
                    }
                }
                break
            }
        }

        // ----- Mixin 失败 -----
        if mcLog.contains("mixin.injection.throwables") || (mcLog.contains(".json] FAILED during") && mcLog.contains("mixin")) {
            reasons.append(.mixinFailed)
            rawAnalysis.append("matched: mixin-failed")
        }

        // ----- Mod 加载器 / 初始化 -----
        if mcLog.contains("Mod resolution failed") {
            reasons.append(.modLoaderFailed)
            rawAnalysis.append("matched: mod-loader-failed")
        }
        if mcLog.contains("Failed to create mod instance.") {
            reasons.append(.modInitFailed)
            rawAnalysis.append("matched: mod-init-failed")
        }

        // ----- "due to errors, provided by" -----
        if mcLog.contains("due to errors, provided by ") {
            if let r = mcLog.range(of: "due to errors, provided by '"),
               r.upperBound < mcLog.endIndex {
                let after = mcLog[r.upperBound...]
                if let end = after.firstIndex(of: "'") {
                    let modName = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !modName.isEmpty {
                        reasons.append(.modInitFailed)
                        rawAnalysis.append("matched: due-to-errors-provided-by \(modName)")
                    }
                }
            }
        }

        // ----- Suspected Mod（Forge crash report）-----
        if mcCrash.contains("Suspected Mod") {
            reasons.append(.suspectedMod)
            rawAnalysis.append("matched: suspected-mod")
            // 提取 Suspected Mod 段
            if let startRange = mcCrash.range(of: "Suspected Mod"),
               let endRange = mcCrash.range(of: "Stacktrace", range: startRange.upperBound..<mcCrash.endIndex) {
                let segment = String(mcCrash[startRange.upperBound..<endRange.lowerBound])
                // 简单抓取 \n\tName(...) 之类
                let pattern = #"(?:\n\t|^)([A-Za-z0-9_\-\.]+?)\s*\($"#
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let matches = regex.matches(in: segment, range: NSRange(segment.startIndex..., in: segment))
                    for m in matches {
                        if let r = Range(m.range(at: 1), in: segment) {
                            suspectedMods.append(String(segment[r]))
                        }
                    }
                }
            }
        }

        // ----- 特定方块 / 实体 -----
        if mcCrash.contains("Block location: World: ") {
            reasons.append(.specificBlock)
            rawAnalysis.append("matched: specific-block")
        }
        if mcCrash.contains("Entity's Exact location: ") {
            reasons.append(.specificEntity)
            rawAnalysis.append("matched: specific-entity")
        }

        // ----- 推断 Java 版本 -----
        var javaVersion: String? = nil
        if let r = mcLog.range(of: #"Using Java at "#, options: .regularExpression) {
            javaVersion = String(mcLog[r.upperBound...]).split(separator: "\n").first.map(String.init)
        } else if let r = mcLog.range(of: #"openjdk version "([^"]+)""#, options: .regularExpression) {
            let nsString = mcLog as NSString
            let match = try? NSRegularExpression(pattern: #"openjdk version "([^"]+)""#)
            let results = match?.matches(in: mcLog, range: NSRange(location: 0, length: nsString.length)) ?? []
            for m in results where m.numberOfRanges >= 2 {
                let captured = nsString.substring(with: m.range(at: 1))
                javaVersion = captured
                _ = r // suppress unused warning
                break
            }
        }

        // ----- 推断 MC 版本 -----
        var mcVersion: String? = nil
        if let r = mcLog.range(of: #"Loading Minecraft ([0-9a-zA-Z\.\-]+)"#, options: .regularExpression) {
            let nsString = mcLog as NSString
            let match = try? NSRegularExpression(pattern: #"Loading Minecraft ([0-9a-zA-Z\.\-]+)"#)
            if let m = match?.firstMatch(in: mcLog, range: NSRange(location: 0, length: nsString.length)),
               m.numberOfRanges >= 2 {
                mcVersion = nsString.substring(with: m.range(at: 1))
            }
            _ = r
        }

        // ----- Mod Loader 推断 -----
        var modLoader: String? = nil
        if logAll.contains("Forge") && logAll.contains("forge") { modLoader = "Forge" }
        else if logAll.contains("NeoForge") { modLoader = "NeoForge" }
        else if logAll.contains("Fabric") { modLoader = "Fabric" }
        else if logAll.contains("Quilt") { modLoader = "Quilt" }

        // ----- dedupe + unknown fallback -----
        var dedup = Array(NSOrderedSet(array: reasons)) as? [CrashReason] ?? reasons
        if dedup.isEmpty {
            dedup = [.unknown]
            rawAnalysis.append("no patterns matched; falling back to .unknown")
        }

        return CrashReport(
            primaryReasons: dedup,
            suspectedMods: Array(NSOrderedSet(array: suspectedMods)) as? [String] ?? suspectedMods,
            fabricSolutions: fabricSolutions,
            logFiles: [],
            javaVersion: javaVersion,
            minecraftVersion: mcVersion,
            modLoader: modLoader,
            rawAnalysis: rawAnalysis.joined(separator: "\n")
        )
    }
}
