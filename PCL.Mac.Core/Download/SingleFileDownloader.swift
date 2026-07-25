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

    private final class Context {
        let destination: URL
        let replaceMethod: ReplaceMethod
        weak var installTask: InstallTask?
        let progress: ((Double) -> Void)?
        var continuation: CheckedContinuation<Void, Error>?
        var lastWritten: Int64 = 0

        init(
            destination: URL,
            replaceMethod: ReplaceMethod,
            installTask: InstallTask?,
            progress: ((Double) -> Void)?,
            continuation: CheckedContinuation<Void, Error>
        ) {
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
        let downloadTask = session.downloadTask(with: request)
        let key = TaskKey(sessionID: ObjectIdentifier(session), taskID: downloadTask.taskIdentifier)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.addOperation {
                    self.contexts[key] = Context(
                        destination: destination,
                        replaceMethod: replaceMethod,
                        installTask: task,
                        progress: progress,
                        continuation: continuation
                    )
                    downloadTask.resume()
                }
            }
        }, onCancel: {
            downloadTask.cancel()
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
        Task { await SpeedMeter.shared.addBytes(Int(delta)) }

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
                throw MyLocalizedError(reason: "远程服务器返回了 \(response.statusCode)。")
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

    private func updateProgress(_ context: Context, value: Double) {
        Task { @MainActor in
            context.installTask?.currentStagePercentage = value
            context.progress?(value)
        }
    }
}
