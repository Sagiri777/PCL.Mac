//
//  NetworkTest.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/3.
//

import Foundation
import Network

/// 网络可达性查询。
///
/// 旧实现每次调用都新建一个 `NWPathMonitor` 并用 `DispatchGroup.wait(timeout: 2)`
/// 同步等待首个 path 回调。它在 `applicationWillFinishLaunching` 的主线程上被调用，
/// 于是离线或慢网络下启动会白屏卡满 2 秒。
///
/// 现在改为进程内单个常驻 monitor：启动时开始观察，`hasNetworkConnection()` 只读
/// 已缓存的状态并立即返回。首个回调还没到达时（启动后几毫秒内）乐观返回 true —— 真实
/// 的网络请求本来就有自己的失败处理，这比让 UI 卡住更合适。
public final class NetworkTest {
    public static let shared = NetworkTest()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.pcl-community.NetworkTest")
    private let lock = NSLock()
    private var isSatisfied = true
    private var hasReceivedPath = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.isSatisfied = path.status == .satisfied
            self.hasReceivedPath = true
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// 当前是否有可用网络。非阻塞。
    ///
    /// - Parameter timeout: 保留用于兼容旧调用点，已不再产生等待。
    public func hasNetworkConnection(timeout: TimeInterval = 2.0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSatisfied
    }

    /// 是否已经拿到过一次真实的 path 状态。用于需要区分“确认离线”与“还不知道”的场景。
    public var hasResolvedPath: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasReceivedPath
    }
}
