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

    fileprivate func destinationIsValid() -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        guard let sha1, !sha1.isEmpty else { return true }
        return ((try? Util.sha1OfFile(url: destination)) ?? "").caseInsensitiveCompare(sha1) == .orderedSame
    }
}

public class MultiFileDownloader {
    private let task: InstallTask?
    private let items: [DownloadItem]
    private let concurrentLimit: Int
    private let replaceMethod: ReplaceMethod
    private let networkCategory: NetworkCategory
    private let progress: ((Double, Int) -> Void)?
    private let total: Int
    private let maxRetryCount: Int = 3
    private var totalProgress: Double = 0
    private var finishedCount: Int = 0
    
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
        self.concurrentLimit = concurrentLimit
        self.replaceMethod = replaceMethod
        self.networkCategory = networkCategory
        self.progress = progress
        self.total = items.count
    }
    
    public func start() async throws {
        guard !items.isEmpty else { return }
        if concurrentLimit == 1 {
            for item in items {
                try await attemptDownload(item)
            }
            return
        }
        
        var tickerTask: Task<Void, Error>? = nil
        if progress != nil || task != nil {
            tickerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.1))
                    if Task.isCancelled { break }
                    await MainActor.run {
                        progress?(self.totalProgress / Double(self.total), self.finishedCount)
                        task?.currentStagePercentage = self.totalProgress / Double(self.total)
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
        
        await MainActor.run {
            progress?(self.totalProgress / Double(self.total), self.finishedCount)
            task?.currentStagePercentage = self.totalProgress / Double(self.total)
        }
    }
    
    private func attemptDownload(_ item: DownloadItem) async throws {
        if FileManager.default.fileExists(atPath: item.destination.path) && replaceMethod == .throw {
            throw MyLocalizedError(reason: "\(item.destination.lastPathComponent) 已存在。")
        }
        if replaceMethod == .skip && item.destinationIsValid() {
            finishedCount += 1
            totalProgress += 1
            await MainActor.run {
                task?.completeOneFile()
            }
            return
        }
        
        var lastError: Error?
        var lastProgress: Double = 0
        for candidate in item.candidates {
            for retryIndex in 0...maxRetryCount {
                do {
                    try await SingleFileDownloader.download(url: candidate, destination: item.destination, replaceMethod: .replace, networkCategory: networkCategory) { progress in
                        let normalizedProgress = progress < 0 ? lastProgress : progress
                        self.totalProgress += (normalizedProgress - lastProgress)
                        lastProgress = normalizedProgress
                    }
                    if let sha1 = item.sha1, !sha1.isEmpty {
                        let actual = try Util.sha1OfFile(url: item.destination)
                        guard actual.caseInsensitiveCompare(sha1) == .orderedSame else {
                            try? FileManager.default.removeItem(at: item.destination)
                            throw MyLocalizedError(reason: "\(item.destination.lastPathComponent) 校验失败。")
                        }
                    }
                    finishedCount += 1
                    await MainActor.run {
                        task?.completeOneFile()
                    }
                    return
                } catch {
                    lastError = error
                    try? FileManager.default.removeItem(at: item.destination)
                    totalProgress -= lastProgress
                    lastProgress = 0
                    if retryIndex < maxRetryCount {
                        warn("下载 \(candidate.lastPathComponent) 失败：\(error.localizedDescription)，重试 \(retryIndex + 1)/\(maxRetryCount)")
                        try await Task.sleep(for: .seconds(Double(retryIndex + 1) * 0.5))
                    } else {
                        warn("下载 \(candidate.lastPathComponent) 失败：\(error.localizedDescription)")
                    }
                }
            }
        }

        throw lastError ?? MyLocalizedError(reason: "\(item.destination.lastPathComponent) 下载失败。")
    }
}

public enum ReplaceMethod {
    case skip, replace, `throw`
}
