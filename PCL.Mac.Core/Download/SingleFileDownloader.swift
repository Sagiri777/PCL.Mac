//
//  SingleFileDownloader.swift
//  PCL.Mac
//

import Foundation

/// Downloads files with a shared direct connection pool.  Reusing the session
/// keeps HTTP connections alive while downloading large Minecraft asset indexes;
/// proxied requests intentionally use isolated sessions so a settings change
/// cannot leak into a direct request.
public enum SingleFileDownloader {
    private static let delegate = SharedDownloadDelegate()
    private static let directSession: URLSession = {
        URLSession(
            configuration: Requests.makeConfiguration(forceUseProxy: false),
            delegate: delegate,
            delegateQueue: SharedDownloadDelegate.queue
        )
    }()

    public static func download(
        task: InstallTask? = nil,
        url: URL,
        destination: URL,
        replaceMethod: ReplaceMethod = .skip,
        networkCategory: NetworkCategory = .gameDownload,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.path) && replaceMethod == .skip {
            discardResumeData(for: destination)
            task?.completeOneFile()
            progress?(1)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("PCL.Mac/\(SharedConstants.shared.version)", forHTTPHeaderField: "User-Agent")

        let usesProxy = Requests.shouldUseProxy(for: networkCategory)
        let session: URLSession
        if usesProxy {
            session = URLSession(
                configuration: Requests.makeConfiguration(forceUseProxy: true),
                delegate: delegate,
                delegateQueue: SharedDownloadDelegate.queue
            )
        } else {
            session = directSession
        }
        defer {
            if usesProxy {
                session.invalidateAndCancel()
            }
        }

        try await delegate.start(
            request: request,
            session: session,
            destination: destination,
            replaceMethod: replaceMethod,
            task: task,
            progress: progress
        )
        task?.completeOneFile()
        progress?(1.0)
    }

    /// URLSession's opaque resume payload is kept next to the target. Completed
    /// files are still the primary cache; this additionally avoids restarting a
    /// single large file after a transient disconnect.
    public static func resumeDataURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).pclresume")
    }

    public static func discardResumeData(for destination: URL) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: destination))
        try? FileManager.default.removeItem(at: resumeSourceURL(for: destination))
    }

    private static func resumeSourceURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).pclresume.source")
    }

    static func loadResumeData(for destination: URL, sourceURL: URL) -> Data? {
        let sourceMarker = resumeSourceURL(for: destination)
        guard let savedSource = try? String(contentsOf: sourceMarker, encoding: .utf8),
              savedSource == sourceURL.absoluteString,
              let data = try? Data(contentsOf: resumeDataURL(for: destination)),
              !data.isEmpty else {
            discardResumeData(for: destination)
            return nil
        }
        return data
    }

    static func persistResumeData(_ data: Data, for destination: URL, sourceURL: URL) {
        guard !data.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(sourceURL.absoluteString.utf8).write(
                to: resumeSourceURL(for: destination),
                options: .atomic
            )
            try data.write(to: resumeDataURL(for: destination), options: .atomic)
        } catch {
            discardResumeData(for: destination)
        }
    }
}

private final class SharedDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PCL.Mac.DownloadDelegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private struct TaskKey: Hashable {
        let sessionID: ObjectIdentifier
        let taskID: Int
    }

    private final class Context: @unchecked Sendable {
        let sourceURL: URL
        let destination: URL
        let replaceMethod: ReplaceMethod
        weak var installTask: InstallTask?
        let progress: ((Double) -> Void)?
        var continuation: CheckedContinuation<Void, Error>?
        var lastWritten: Int64 = 0
        /// 上次向主线程报告进度的时间。didWriteData 每个 chunk 都会回调，
        /// 逐次 hop 到 MainActor 会在大批量下载时把主线程打满。
        var lastReportedAt: TimeInterval = 0
        var lastReportedValue: Double = -1

        init(
            sourceURL: URL,
            destination: URL,
            replaceMethod: ReplaceMethod,
            installTask: InstallTask?,
            progress: ((Double) -> Void)?,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.sourceURL = sourceURL
            self.destination = destination
            self.replaceMethod = replaceMethod
            self.installTask = installTask
            self.progress = progress
            self.continuation = continuation
        }
    }

    private var contexts: [TaskKey: Context] = [:]

    func start(
        request: URLRequest,
        session: URLSession,
        destination: URL,
        replaceMethod: ReplaceMethod,
        task: InstallTask?,
        progress: ((Double) -> Void)?
    ) async throws {
        let sourceURL = request.url ?? destination
        let savedResumeData = SingleFileDownloader.loadResumeData(for: destination, sourceURL: sourceURL)
        let downloadTask = savedResumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request)
        let key = TaskKey(sessionID: ObjectIdentifier(session), taskID: downloadTask.taskIdentifier)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let context = Context(
                    sourceURL: sourceURL,
                    destination: destination,
                    replaceMethod: replaceMethod,
                    installTask: task,
                    progress: progress,
                    continuation: continuation
                )
                Self.queue.addOperation {
                    self.contexts[key] = context
                    downloadTask.resume()
                }
            }
        }, onCancel: {
            downloadTask.cancel(byProducingResumeData: { data in
                guard let data else { return }
                SingleFileDownloader.persistResumeData(data, for: destination, sourceURL: sourceURL)
            })
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let context = context(for: session, task: downloadTask) else { return }
        let delta = totalBytesWritten - context.lastWritten
        context.lastWritten = totalBytesWritten
        // 字节计数走非阻塞的同步累加器，不再为每个 chunk 起一个 Task 跳到 MainActor。
        SpeedMeter.record(bytes: Int(delta))

        guard totalBytesExpectedToWrite > 0 else {
            context.progress?(-1)
            return
        }
        updateProgress(context, value: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let context = context(for: session, task: downloadTask) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw MyLocalizedError(reason: "远程服务器未返回有效响应。")
            }
            guard (200..<300).contains(response.statusCode) else {
                let host = response.url?.host ?? context.sourceURL.host ?? "远程服务器"
                let challenged = response.value(forHTTPHeaderField: "cf-mitigated") == "challenge"
                if response.statusCode == 403, challenged {
                    throw MyLocalizedError(reason: "\(host) 返回 HTTP 403，Cloudflare 拒绝了启动器请求。")
                }
                throw MyLocalizedError(reason: "\(host) 返回 HTTP \(response.statusCode)。")
            }

            let manager = FileManager.default
            if manager.fileExists(atPath: context.destination.path) {
                switch context.replaceMethod {
                case .replace:
                    try manager.removeItem(at: context.destination)
                case .throw:
                    throw MyLocalizedError(reason: "\(context.destination.lastPathComponent) 已存在。")
                case .skip:
                    break
                }
            }
            try manager.createDirectory(at: context.destination.parent(), withIntermediateDirectories: true)
            if context.replaceMethod != .skip || !manager.fileExists(atPath: context.destination.path) {
                try manager.moveItem(at: location, to: context.destination)
            }
            SingleFileDownloader.discardResumeData(for: context.destination)
            updateProgress(context, value: 1)
            resume(session: session, task: downloadTask, with: .success(()))
        } catch {
            resume(session: session, task: downloadTask, with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // For a normal download didFinishDownloadingTo has already moved the
            // temporary file and consumed the continuation.  If it has not,
            // fail rather than leave the caller awaiting forever.
            resume(
                session: session,
                task: task,
                with: .failure(MyLocalizedError(reason: "下载完成但未收到文件。"))
            )
            return
        }
        if let context = context(for: session, task: task) {
            let nsError = error as NSError
            if let resumeData = nsError.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data,
               !resumeData.isEmpty {
                SingleFileDownloader.persistResumeData(
                    resumeData,
                    for: context.destination,
                    sourceURL: context.sourceURL
                )
            } else if (error as? URLError)?.code != .cancelled {
                // No replacement resume payload means the saved opaque blob is
                // no longer usable. Keep it only for an explicit cancellation,
                // whose cancellation handler may be writing fresh resume data.
                SingleFileDownloader.discardResumeData(for: context.destination)
            }
        }
        resume(session: session, task: task, with: .failure(error))
    }

    private func key(for session: URLSession, task: URLSessionTask) -> TaskKey {
        TaskKey(sessionID: ObjectIdentifier(session), taskID: task.taskIdentifier)
    }

    private func context(for session: URLSession, task: URLSessionTask) -> Context? {
        contexts[key(for: session, task: task)]
    }

    private func resume(session: URLSession, task: URLSessionTask, with result: Result<Void, Error>) {
        let key = key(for: session, task: task)
        guard let context = contexts.removeValue(forKey: key), let continuation = context.continuation else { return }
        context.continuation = nil
        continuation.resume(with: result)
    }

    /// 节流后再上报进度：同一个下载最多每 100ms 更新一次 UI，进度到 1 时必报。
    /// delegate 回调本身跑在串行的 delegate queue 上，所以这里读写 context 是安全的。
    private func updateProgress(_ context: Context, value: Double) {
        let now = Date().timeIntervalSince1970
        let isTerminal = value >= 1
        if !isTerminal {
            guard now - context.lastReportedAt >= 0.1,
                  abs(value - context.lastReportedValue) >= 0.005 else { return }
        }
        context.lastReportedAt = now
        context.lastReportedValue = value

        Task { @MainActor in
            context.installTask?.currentStagePercentage = value
            context.progress?(value)
        }
    }
}
