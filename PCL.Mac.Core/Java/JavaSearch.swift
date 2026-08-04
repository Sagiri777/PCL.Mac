//
//  JavaSearch.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/18.
//
// 不改了，能跑就不要动
//          by YiZhiMCQiu at 2025/6/6 in fix & optimizations (1)
// 还是改改罢，JRE 搜索炸了
//          by YiZhiMCQiu at 2025/6/28 in main
// 改成 async + 并发探测：searchAndSet 原来在 applicationWillFinishLaunching
// 的主线程上同步跑，其中 JavaVirtualMachine.of 对缺少 release 文件的 JVM 会
// spawn `java -version` 并 waitUntilExit，每个 100~400ms，装了几个 JDK 的机器
// 启动时首屏就要卡上一秒以上。
//          2026/07

import Foundation

public class JavaSearch {
    /// 后台搜索所有 Java 并把结果推到 DataManager。
    ///
    /// 探测本身（读 release 文件 / spawn `java -version` / 读 Mach-O header）全部在
    /// 后台并发执行，只有最终赋值回到主线程。
    @discardableResult
    public static func searchAndSet() async -> [JavaVirtualMachine] {
        let before = Date().timeIntervalSince1970
        var result = (try? await searchAsync()) ?? []
        let elapsed = Int((Date().timeIntervalSince1970 - before) * 1000)

        result.append(contentsOf: await loadCustomJVMs())
        let finalResult = result

        await MainActor.run {
            DataManager.shared.javaVirtualMachines = finalResult
            DataManager.shared.lastTimeUsed = elapsed
        }
        log("搜索 Java 耗时 \(elapsed)ms，共 \(finalResult.count) 项")
        return finalResult
    }

    /// 同步版本，仅保留给必须阻塞的调用点（如 CLI）。UI 路径请用 async 版本。
    public static func searchAndSetBlocking() throws {
        let before = Date().timeIntervalSince1970
        let result = try search()
        DataManager.shared.javaVirtualMachines = result
        DataManager.shared.lastTimeUsed = Int((Date().timeIntervalSince1970 - before) * 1000)
        log("搜索 Java 耗时 \(DataManager.shared.lastTimeUsed)ms")

        for url in AppSettings.shared.userAddedJvmPaths {
            DataManager.shared.javaVirtualMachines.append(JavaVirtualMachine.of(url, true))
        }
    }

    private static func loadCustomJVMs() async -> [JavaVirtualMachine] {
        let paths = await MainActor.run { AppSettings.shared.userAddedJvmPaths }
        guard !paths.isEmpty else { return [] }
        let jvms = await withTaskGroup(of: JavaVirtualMachine?.self) { group in
            for url in paths {
                group.addTask { JavaVirtualMachine.of(url, true) }
            }
            var collected: [JavaVirtualMachine] = []
            for await jvm in group {
                if let jvm, !jvm.isError { collected.append(jvm) }
            }
            return collected
        }
        log("加载了 \(jvms.count) 个由用户添加的 Java")
        return jvms
    }

    /// 候选可执行文件路径。纯路径拼接 + 存在性检查，很便宜。
    private static func candidateExecutableURLs() throws -> [URL] {
        var executableURLs: [URL] = [
            URL(fileURLWithPath: "/usr/bin/java")
        ]

        let javaDirectoryParents = [
            "/Library/Java/JavaVirtualMachines",
            "~/Library/Java/JavaVirtualMachines",
            "/opt/homebrew/opt/java/libexec"
        ]
            .map { URL(fileURLWithUserPath: $0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }

        for javaDirectoryParent in javaDirectoryParents {
            let parentURL = URL(fileURLWithPath: javaDirectoryParent)
            for javaDirectory in try FileManager.default.contentsOfDirectory(atPath: javaDirectoryParent) {
                let javaHomeURL = parentURL.appending(path: javaDirectory).appending(path: "Contents").appending(path: "Home")
                executableURLs.append(javaHomeURL.appending(path: "bin").appending(path: "java"))
                executableURLs.append(javaHomeURL.appending(path: "jre").appending(path: "bin").appending(path: "java"))
            }
        }

        return executableURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 并发探测所有候选路径。顺序按候选顺序稳定，避免 Java 列表每次刷新都跳动。
    public static func searchAsync() async throws -> [JavaVirtualMachine] {
        let candidates = try candidateExecutableURLs()
        guard !candidates.isEmpty else { return [] }

        let indexed = await withTaskGroup(of: (Int, JavaVirtualMachine).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, JavaVirtualMachine.of(url)) }
            }
            var collected: [(Int, JavaVirtualMachine)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        return indexed
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
            .filter { !$0.isError }
    }

    public static func search() throws -> [JavaVirtualMachine] {
        try candidateExecutableURLs()
            .map { JavaVirtualMachine.of($0) }
            .filter { !$0.isError }
    }

    private static func isValidJvmDirectory(_ path: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: toJvmDirectory(path).appending(path: "java").path(), isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func toJvmDirectory(_ path: URL) -> URL {
        return path.appending(path: "Contents").appending(path: "Home").appending(path: "bin")
    }
}
