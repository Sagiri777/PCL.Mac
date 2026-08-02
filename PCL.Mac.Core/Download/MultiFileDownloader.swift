//
//  ProgressiveDownloader.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/24.
//

import Foundation

public struct DownloadItem {
    public let url: URL
    public let destination: URL
    public let sha1: String?
    
    fileprivate var fallbackURLs: [URL] {
        fallbackURLProvider?() ?? []
    }
    private var fallbackURLProvider: (() -> [URL])?
    
    public init(_ downloadSource: DownloadSource, _ urlProvider: @escaping (DownloadSource) -> URL, destination: URL) {
        self.url = urlProvider(downloadSource)
        self.destination = destination
        self.sha1 = nil
        self.fallbackURLProvider = {
            DownloadSourceManager.shared.candidateURLs(for: urlProvider(downloadSource)).dropFirst().map { $0 }
        }
    }

    public init(_ url: URL, _ destination: URL, sha1: String? = nil, fallbackURLs: [URL]? = nil) {
        self.url = url
        self.destination = destination
        self.sha1 = sha1
        self.fallbackURLProvider = {
            fallbackURLs ?? DownloadSourceManager.shared.candidateURLs(for: url).dropFirst().map { $0 }
        }
    }

    fileprivate var candidates: [URL] {
        var urls = [url]
        urls.append(contentsOf: fallbackURLs)
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    func destinationIsValid() -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        guard let sha1, !sha1.isEmpty else { return true }
        return ((try? Util.sha1OfFile(url: destination)) ?? "").caseInsensitiveCompare(sha1) == .orderedSame
    }
}

/// Keeps the failing file attached to an otherwise low-level URLSession error.
/// Callers can therefore show the user which mod failed instead of only saying
/// that the whole "download files" stage stopped.
public struct FileDownloadFailure: LocalizedError, Sendable {
    public let sourceURL: URL
    public let destination: URL
    public let attempts: Int
    public let reason: String

    public init(sourceURL: URL, destination: URL, attempts: Int, reason: String) {
        self.sourceURL = sourceURL
        self.destination = destination
        self.attempts = attempts
        self.reason = reason
    }

    public var errorDescription: String? {
        let host = sourceURL.host ?? "未知来源"
        return "文件 \(destination.lastPathComponent) 下载失败（\(host)，已尝试 \(attempts) 次）：\(reason)"
    }
}

/// A batch-level error includes the number of files that are already safely on
/// disk. It is deliberately value-only so it can cross async task boundaries.
public struct MultiFileDownloadFailure: LocalizedError, Sendable {
    public let completedFiles: Int
    public let totalFiles: Int
    public let reason: String

    public init(completedFiles: Int, totalFiles: Int, reason: String) {
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.reason = reason
    }

    public var errorDescription: String? {
        "\(reason)\n已保留 \(completedFiles) / \(totalFiles) 个完成文件；重试时会校验并跳过它们。"
    }
}

public class MultiFileDownloader {
    /// A high number of simultaneous URLSession tasks hurts both mirror servers and
    /// local disk I/O.  Keep the batch bounded even when a caller requests a much
    /// larger value (the asset installer used to request 256 connections).
    public static let maximumConcurrentDownloads = 16

    private let task: InstallTask?
    private let items: [DownloadItem]
    private let concurrentLimit: Int
    private let replaceMethod: ReplaceMethod
    private let networkCategory: NetworkCategory
    private let progress: ((Double, Int) -> Void)?
    private let total: Int
    private let maxRetryCount: Int = 3
    private let progressState = DownloadBatchProgress()
    /// 每个条目的候选 URL 只解析一次。`item.candidates` 会读
    /// `AppSettings.fileDownloadSource`（一次 JSON 解码），4000 个资源逐个重复解析
    /// 是纯浪费。
    private var candidatesCache: [URL: [URL]] = [:]
    private let candidatesLock = NSLock()


    public convenience init(
        task: InstallTask? = nil,
        urls: [URL],
        destinations: [URL],
        concurrentLimit: Int = DownloadSourceManager.shared.recommendedConcurrency,
        replaceMethod: ReplaceMethod = .skip,
        networkCategory: NetworkCategory = .gameDownload,
        progress: ((Double, Int) -> Void)? = nil
    ) {
        self.init(
            task: task,
            items: (0..<urls.count).map { .init(urls[$0], destinations[$0]) },
            concurrentLimit: concurrentLimit,
            replaceMethod: replaceMethod,
            networkCategory: networkCategory,
            progress: progress
        )
    }
    
    public init(
        task: InstallTask? = nil,
        items: [DownloadItem],
        concurrentLimit: Int = DownloadSourceManager.shared.recommendedConcurrency,
        replaceMethod: ReplaceMethod = .skip,
        networkCategory: NetworkCategory = .gameDownload,
        progress: ((Double, Int) -> Void)? = nil
    ) {
        self.task = task
        self.items = items
        self.concurrentLimit = min(max(1, concurrentLimit), Self.maximumConcurrentDownloads)
        self.replaceMethod = replaceMethod
        self.networkCategory = networkCategory
        self.progress = progress
        self.total = items.count
    }
    
    public func start() async throws {
        guard !items.isEmpty else { return }
        await progressState.reset()
        defer { task?.flushProgress() }
        do {
            if concurrentLimit == 1 {
                for item in items {
                    try await attemptDownload(item)
                }
            } else {
                var tickerTask: Task<Void, Error>? = nil
                if progress != nil || task != nil {
                    tickerTask = Task {
                        // 4Hz 足够让进度条看起来连续；原来的 10Hz 意味着 InstallingView
                        // 每秒重建 10 次，叠加逐文件完成回调后主线程压力明显。
                        var lastReported: Double = -1
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(0.25))
                            if Task.isCancelled { break }
                            let snapshot = await self.progressState.snapshot()
                            let normalizedProgress = snapshot.progress / Double(max(self.total, 1))
                            // 进度没有实际推进时不打扰主线程。
                            guard abs(normalizedProgress - lastReported) >= 0.0005 else { continue }
                            lastReported = normalizedProgress
                            await MainActor.run {
                                progress?(normalizedProgress, snapshot.finishedCount)
                                task?.currentStagePercentage = normalizedProgress
                            }
                        }
                    }
                }

                defer {
                    tickerTask?.cancel()
                }

                var nextIndex = 0
                try await withThrowingTaskGroup(of: Void.self) { group in
                    let initial = min(concurrentLimit, total)
                    while nextIndex < initial {
                        let item = items[nextIndex]
                        group.addTask {
                            try await self.attemptDownload(item)
                        }
                        nextIndex += 1
                    }

                    while let _ = try await group.next() {
                        if nextIndex < total {
                            let item = items[nextIndex]
                            group.addTask {
                                try await self.attemptDownload(item)
                            }
                            nextIndex += 1
                        }
                    }
                }
            }

            let snapshot = await progressState.snapshot()
            let normalizedProgress = snapshot.progress / Double(max(total, 1))
            await MainActor.run {
                progress?(normalizedProgress, snapshot.finishedCount)
                task?.currentStagePercentage = normalizedProgress
            }
        } catch {
            if Task.isCancelled || isCancellation(error) {
                throw CancellationError()
            }
            let snapshot = await progressState.snapshot()
            throw MultiFileDownloadFailure(
                completedFiles: snapshot.finishedCount,
                totalFiles: total,
                reason: error.localizedDescription
            )
        }
    }
    
    private func attemptDownload(_ item: DownloadItem) async throws {
        if FileManager.default.fileExists(atPath: item.destination.path) && replaceMethod == .throw {
            throw MyLocalizedError(reason: "\(item.destination.lastPathComponent) 已存在。")
        }
        if replaceMethod == .skip && item.destinationIsValid() {
            SingleFileDownloader.discardResumeData(for: item.destination)
            await progressState.complete()
            // completeOneFile 内部已经是线程安全的合并计数，不需要额外的 actor 跳转。
            task?.completeOneFile()
            return
        }
        
        var lastError: Error?
        var lastCandidate = item.url
        let resolvedCandidates = candidates(for: item)
        for candidate in resolvedCandidates {
            lastCandidate = candidate
            for retryIndex in 0...maxRetryCount {
                let progressID = UUID()
                do {
                    try await SingleFileDownloader.download(url: candidate, destination: item.destination, replaceMethod: .replace, networkCategory: networkCategory) { progress in
                        guard progress >= 0 else { return }
                        // SingleFileDownloader 已对该回调做了 100ms 节流，
                        // 这里的 Task 数量因此是有界的。
                        Task {
                            await self.progressState.update(id: progressID, value: progress)
                        }
                    }
                    if let sha1 = item.sha1, !sha1.isEmpty {
                        let actual = try Util.sha1OfFile(url: item.destination)
                        guard actual.caseInsensitiveCompare(sha1) == .orderedSame else {
                            try? FileManager.default.removeItem(at: item.destination)
                            SingleFileDownloader.discardResumeData(for: item.destination)
                            throw MyLocalizedError(reason: "\(item.destination.lastPathComponent) 校验失败。")
                        }
                    }
                    await progressState.complete(id: progressID)
                    task?.completeOneFile()
                    return
                } catch {
                    if Task.isCancelled || isCancellation(error) {
                        throw CancellationError()
                    }
                    lastError = error
                    try? FileManager.default.removeItem(at: item.destination)
                    await progressState.remove(id: progressID)
                    if retryIndex < maxRetryCount {
                        warn("下载 \(candidate.lastPathComponent) 失败：\(error.localizedDescription)，重试 \(retryIndex + 1)/\(maxRetryCount)")
                        try await Task.sleep(for: .seconds(Double(retryIndex + 1) * 0.5))
                    } else {
                        warn("下载 \(candidate.lastPathComponent) 失败：\(error.localizedDescription)")
                    }
                }
            }
        }

        throw FileDownloadFailure(
            sourceURL: lastCandidate,
            destination: item.destination,
            attempts: max(resolvedCandidates.count, 1) * (maxRetryCount + 1),
            reason: lastError?.localizedDescription ?? "没有可用下载源。"
        )
    }

    /// 以主 URL 为键缓存候选列表：同一批次里镜像配置不会中途变化。
    private func candidates(for item: DownloadItem) -> [URL] {
        candidatesLock.lock()
        if let cached = candidatesCache[item.url] {
            candidatesLock.unlock()
            return cached
        }
        candidatesLock.unlock()

        let resolved = item.candidates

        candidatesLock.lock()
        candidatesCache[item.url] = resolved
        candidatesLock.unlock()
        return resolved
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// Serializes aggregate progress updates from URLSession delegate queues.  The
/// downloader used to mutate two shared properties from several task-group
/// children, which produced inaccurate progress and occasional UI regressions.
private actor DownloadBatchProgress {
    private var itemProgress: [UUID: Double] = [:]
    private var closedItems: Set<UUID> = []
    private var finishedCount = 0

    func reset() {
        itemProgress.removeAll(keepingCapacity: true)
        closedItems.removeAll(keepingCapacity: true)
        finishedCount = 0
    }

    func update(id: UUID, value: Double) {
        guard !closedItems.contains(id) else { return }
        itemProgress[id] = min(max(value, 0), 1)
    }

    func remove(id: UUID) {
        closedItems.insert(id)
        itemProgress.removeValue(forKey: id)
    }

    func complete(id: UUID? = nil) {
        if let id {
            closedItems.insert(id)
            itemProgress.removeValue(forKey: id)
        }
        finishedCount += 1
    }

    func snapshot() -> (progress: Double, finishedCount: Int) {
        let completed = Double(finishedCount)
        let inFlight = itemProgress.values.reduce(0, +)
        return (completed + inFlight, finishedCount)
    }
}

public enum ReplaceMethod: Sendable {
    case skip, replace, `throw`
}
