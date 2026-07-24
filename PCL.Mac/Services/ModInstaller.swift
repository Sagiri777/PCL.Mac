//
//  ModInstaller.swift
//  PCL.Mac
//
//  Created by Codex on 2026/7/24.
//
//  Mods 页拖入文件安装。处理三类来源：
//
//  - `.jar` / `.jar.disabled`：单个 mod 文件，直接拷入当前实例的 mods/。
//    mods/ 在首次写入时会自动创建（Util.openInFinder 也会，所以行为一致）。
//
//  - `.zip`：自动探测。
//    - 含 `modrinth.index.json` 或 `manifest.json`：当整合包（mrpack / CurseForge / HMCL）
//      处理，调用现有的 ModpackImporter.install，在当前 minecraftDirectory 下新建实例。
//    - 其它：当作"mods 压缩包"，把所有 .jar 抽出放到 mods/。
//
//  - `.mrpack`：Modrinth 整合包，与 .zip 一视同仁。
//
//  设计原则：失败 / 跳过的明细写到 log（err / warn），UI 层只展示汇总 hint，
// 避免按钮点击未响应时期的 "err" 被误以为是崩溃。
//

import Foundation
import ZIPFoundation

public enum ModInstaller {

    /// 单次拖入的安装结果。
    public struct Summary: Sendable {
        public var installedJars: Int = 0       // 拷入 mods/ 的 jar 数量
        public var installedPacks: Int = 0      // 整合包导入成功的数量
        public var skipped: [String] = []       // 同名跳过等原因
        public var failures: [String] = []      // 真正的失败

        public var isEmpty: Bool {
            installedJars == 0 && installedPacks == 0
        }
    }

    /// 一次拖入的预分类结果：哪些会装到当前实例的 mods/，哪些是整合包（会新建实例），
    /// 哪些识别不出来。Caller 用它来决定要不要弹确认框。
    public struct Classification: Sendable {
        public let mods: [URL]       // .jar / .zip（含 mods 压缩包）—— 安装到当前实例的 mods/
        public let modpacks: [URL]   // .mrpack / 含 manifest 的 .zip —— 新建实例
        public let unknown: [URL]    // 其它文件 / 后缀
        public var modpackCount: Int { modpacks.count }
        public var hasAny: Bool { !mods.isEmpty || !modpacks.isEmpty || !unknown.isEmpty }
    }

    /// 递归扫描目录，收集所有可作为 mod 安装的条目。
    /// - 默认上限 8 层，绝大多数 mods 文件夹远不到；
    /// - 跳过隐藏目录（`.DS_Store`、`__MACOSX` 等）；
    /// - 不跟随符号链接，避免循环。
    /// - 命中后缀：`.jar`、`.jar.disabled`、`.zip`、`.mrpack`。
    public static func expandDirectory(_ dir: URL, maxDepth: Int = 8) -> [URL] {
        let fm = FileManager.default
        var collected: [URL] = []
        var stack: [(url: URL, depth: Int)] = [(dir, 0)]
        while let (currentURL, depth) = stack.popLast() {
            if depth > maxDepth { continue }
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                warn("ModInstaller: 无法读取 \(currentURL.path): \(error.localizedDescription)")
                continue
            }
            for item in contents {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    // 不递归符号链接
                    if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        continue
                    }
                    stack.append((item, depth + 1))
                    continue
                }
                let lower = item.path.lowercased()
                let ext = item.pathExtension.lowercased()
                let isCandidate =
                    lower.hasSuffix(".jar") ||
                    lower.hasSuffix(".jar.disabled") ||
                    ext == "zip" ||
                    ext == "mrpack"
                if isCandidate {
                    collected.append(item)
                }
            }
        }
        return collected
    }

    /// 把一组拖入的 URL 全部展开后分类（支持目录递归）。
    /// 注意这是预检查，不会真正安装 / 复制任何东西，仅用于 UI 决策。
    public static func classify(_ urls: [URL]) -> Classification {
        let fm = FileManager.default
        // 先展开所有目录
        var expanded: [URL] = []
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            if url.hasDirectoryPath {
                expanded.append(contentsOf: expandDirectory(url))
            } else {
                expanded.append(url)
            }
        }
        // 再按后缀与内容分类
        var mods: [URL] = []
        var modpacks: [URL] = []
        var unknown: [URL] = []
        for url in expanded {
            let ext = url.pathExtension.lowercased()
            let lower = url.path.lowercased()
            if lower.hasSuffix(".jar") || lower.hasSuffix(".jar.disabled") {
                mods.append(url)
            } else if ext == "mrpack" {
                modpacks.append(url)
            } else if ext == "zip" {
                switch classifyZip(url) {
                case .modsPack: mods.append(url)
                case .modpack: modpacks.append(url)
                case .unknown:  unknown.append(url)
                }
            } else {
                unknown.append(url)
            }
        }
        return Classification(mods: mods, modpacks: modpacks, unknown: unknown)
    }

    // MARK: - 单独三类安装

    /// 单个 `.jar` → 当前实例的 `mods/`。
    /// 同名文件已存在则抛错，由 caller 标记为 "skipped"。
    @discardableResult
    public static func installJar(from srcURL: URL, into instance: MinecraftInstance) throws -> URL {
        let fm = FileManager.default
        let modsDir = instance.runningDirectory.appending(path: "mods")
        try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
        let dest = modsDir.appending(path: srcURL.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            throw MyLocalizedError(reason: "已存在同名 mod：\(dest.lastPathComponent)")
        }
        try fm.copyItem(at: srcURL, to: dest)
        return dest
    }

    /// 把 zip 里的所有 `.jar` 抽到 `mods/`。zip 顶层或任意子目录都行（很多模组作者会把
    /// mods 放到 `mods/` 子目录里打包；这里对所有路径下的 jar 都尝试拷出，但保留原始
    /// 文件名以避免重名）。
    @discardableResult
    public static func installModsZip(from srcURL: URL, into instance: MinecraftInstance) throws -> [URL] {
        let fm = FileManager.default
        let modsDir = instance.runningDirectory.appending(path: "mods")
        try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
        let archive = try Archive(url: srcURL, accessMode: .read)
        var installed: [URL] = []
        for entry in Array(archive) {
            let path = entry.path
            guard !path.hasSuffix("/") else { continue }
            let lower = path.lowercased()
            // 只要 .jar 或 .jar.disabled；其它格式（.zip, .txt 等）忽略
            guard lower.hasSuffix(".jar") || lower.hasSuffix(".jar.disabled") else { continue }
            // 忽略 macOS 元数据（__MACOSX/ 之类）
            if path.hasPrefix("__MACOSX/") || path.contains("/__MACOSX/") { continue }
            let baseName = (path as NSString).lastPathComponent
            let dest = modsDir.appending(path: baseName)
            if fm.fileExists(atPath: dest.path) {
                continue
            }
            _ = try archive.extract(entry) { chunk in
                if fm.fileExists(atPath: dest.path) {
                    let handle = try FileHandle(forWritingTo: dest)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: chunk)
                    try handle.close()
                } else {
                    try chunk.write(to: dest)
                }
            }
            installed.append(dest)
        }
        return installed
    }

    /// 判定一个 zip 是 "mods 压缩包" 还是 "整合包"。
    /// - 整合包必含 `manifest.json` 或 `modrinth.index.json`
    /// - mods 压缩包至少要有一个 `.jar`，且不含以上两种 manifest
    public static func classifyZip(_ zipURL: URL) -> Format {
        guard let archive = try? Archive(url: zipURL, accessMode: .read) else { return .unknown }
        let entries = Array(archive)
        if entries.contains(where: { $0.path == "modrinth.index.json" || $0.path == "manifest.json" }) {
            return .modpack
        }
        let hasJar = entries.contains { entry in
            let lower = entry.path.lowercased()
            return (lower.hasSuffix(".jar") || lower.hasSuffix(".jar.disabled")) && !entry.path.hasSuffix("/")
        }
        return hasJar ? .modsPack : .unknown
    }

    public enum Format {
        case modsPack   // 含 .jar 但不含 manifest
        case modpack    // 含 manifest.json / modrinth.index.json
        case unknown
    }

    // MARK: - 拖入统一入口

    /// 处理一组拖入的 URL，按后缀路由到对应安装路径。
    /// 不抛错——错误以 `summary.failures` 形式汇总。
    @discardableResult
    public static func install(dropped urls: [URL], into instance: MinecraftInstance) async -> Summary {
        var summary = Summary()
        let fm = FileManager.default

        // 1. 展开目录 / 过滤不存在的条目（保留 caller 的原始顺序）。
        var expanded: [URL] = []
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            if url.hasDirectoryPath {
                // 目录递归时，跳过该目录失败，不整体放弃（其它目录还能装）。
                expanded.append(contentsOf: expandDirectory(url))
            } else {
                expanded.append(url)
            }
        }
        // 去重：相同的绝对路径只装一次。
        var seen = Set<String>()
        let fileURLs = expanded.filter { url in
            let key = url.standardizedFileURL.path
            let inserted = seen.insert(key).inserted
            return inserted
        }

        if fileURLs.isEmpty {
            summary.failures.append("拖入的内容不是有效文件")
            return summary
        }

        let lower: (URL) -> String = { $0.pathExtension.lowercased() }
        let pathLower: (URL) -> String = { $0.path.lowercased() }

        // 2. 纯 .jar / .jar.disabled → 当前实例 mods/
        let jars = fileURLs.filter { url in
            let p = pathLower(url)
            return p.hasSuffix(".jar") || p.hasSuffix(".jar.disabled")
        }
        for jar in jars {
            do {
                _ = try installJar(from: jar, into: instance)
                summary.installedJars += 1
            } catch {
                let msg = "\(jar.lastPathComponent): \(error.localizedDescription)"
                if error.localizedDescription.contains("已存在同名") {
                    summary.skipped.append(msg)
                } else {
                    summary.failures.append(msg)
                }
            }
        }

        // 3. .mrpack → Modrinth 整合包
        let mrpacks = fileURLs.filter { lower($0) == "mrpack" }
        for mr in mrpacks {
            do {
                _ = try await ModpackImporter.install(zipURL: mr, into: instance.minecraftDirectory)
                summary.installedPacks += 1
            } catch {
                summary.failures.append("\(mr.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // 4. .zip → 探测 mods 压缩包 / 整合包
        let zips = fileURLs.filter { lower($0) == "zip" }
        for zip in zips {
            switch classifyZip(zip) {
            case .modsPack:
                do {
                    let installed = try installModsZip(from: zip, into: instance)
                    summary.installedJars += installed.count
                    if installed.isEmpty {
                        summary.skipped.append("\(zip.lastPathComponent): 没有新的 .jar")
                    }
                } catch {
                    summary.failures.append("\(zip.lastPathComponent): \(error.localizedDescription)")
                }
            case .modpack:
                do {
                    _ = try await ModpackImporter.install(zipURL: zip, into: instance.minecraftDirectory)
                    summary.installedPacks += 1
                } catch {
                    summary.failures.append("\(zip.lastPathComponent): \(error.localizedDescription)")
                }
            case .unknown:
                summary.failures.append("\(zip.lastPathComponent): 无法识别")
            }
        }

        return summary
    }
}
