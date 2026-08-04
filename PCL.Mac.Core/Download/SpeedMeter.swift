//
//  SpeedMeter.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/24.
//

import Foundation

/// 下载速度显示。
///
/// 两处性能约束：
/// 1. `record(bytes:)` 会被 URLSession delegate 在每个 chunk 上调用（下载资源时
///    每秒上千次）。它必须是同步、无锁竞争代价的纯累加，不能每次都起一个 Task
///    跳到 MainActor —— 那是之前主线程被打满的主要来源。
/// 2. 1Hz 的 ticker 原来一旦创建就永久运行，且每次都给 `@Published` 赋值。
///    `@Published` 即使赋相同值也会发布，于是下载结束后界面仍以 1Hz 持续失效。
///    现在没有流量时 ticker 自动停下，值不变也不再发布。
@MainActor
final class SpeedMeter: ObservableObject {
    public static let shared: SpeedMeter = .init()

    @Published public private(set) var downloadSpeed: Int64 = 0

    private var tickerTask: Task<Void, Never>?
    /// 连续多少个空闲 tick 之后停掉 ticker。
    private var idleTicks = 0
    private static let maxIdleTicks = 3

    private init() {}

    /// 记录已下载字节。可从任意线程调用，同步返回。
    nonisolated public static func record(bytes: Int) {
        guard bytes > 0 else { return }
        ByteCounter.shared.add(Int64(bytes))
        Task { @MainActor in shared.ensureTicking() }
    }

    nonisolated public func addBytes(_ n: Int) async {
        SpeedMeter.record(bytes: n)
    }

    nonisolated public func addByte() async {
        SpeedMeter.record(bytes: 1)
    }

    /// 有流量时才让 ticker 跑起来。
    private func ensureTicking() {
        idleTicks = 0
        guard tickerTask == nil else { return }
        tickerTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                guard let self else { break }
                if self.tick() { break }
            }
        }
    }

    /// 返回 true 表示 ticker 应该停止。
    private func tick() -> Bool {
        let intervalBytes = ByteCounter.shared.take()
        if downloadSpeed != intervalBytes {
            downloadSpeed = intervalBytes
        }

        if intervalBytes > 0 {
            idleTicks = 0
            return false
        }

        idleTicks += 1
        if idleTicks >= SpeedMeter.maxIdleTicks {
            tickerTask = nil
            return true
        }
        return false
    }
}

/// 无 actor 跳转的字节累加器。用锁而非 actor：调用点在 URLSession 的 delegate
/// 回调里，必须同步完成，不能引入 await。
private final class ByteCounter {
    static let shared = ByteCounter()

    private let lock = NSLock()
    private var intervalBytes: Int64 = 0

    func add(_ n: Int64) {
        lock.lock()
        intervalBytes &+= n
        lock.unlock()
    }

    func take() -> Int64 {
        lock.lock()
        let value = intervalBytes
        intervalBytes = 0
        lock.unlock()
        return value
    }
}
