//
//  SkinCacheStorage.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/11.
//

import Foundation
import CoreImage
import CoreGraphics
import ImageIO

class SkinCacheStorage {
    public static let shared: SkinCacheStorage = .init()

    /// 缓存的二进制数据
    @CodableAppStorage("skinCache") var skinCache: [UUID : Data] = [:]
    /// 缓存写入时间（Unix 时间戳，秒）
    @CodableAppStorage("skinCacheTimestamp") var cacheTimestamps: [UUID : Double] = [:]

    /// 判断某个账号的缓存是否过期。同时校验缓存内容是合法 PNG（避免 Cloudflare 验证页等脏数据被复用）。
    public func isCacheValid(for account: AnyAccount) -> Bool {
        validCachedSkin(for: account) != nil
    }

    /// 返回仍然有效的缓存数据，没有则返回 nil。
    ///
    /// 合并了原来的「先 isCacheValid 再 skinCache[...]」两步写法：
    /// `skinCache` 是 CodableAppStorage，每次读都可能要解码整个 PNG 字典，
    /// 一次头像加载原本要走三遍。
    public func validCachedSkin(for account: AnyAccount) -> Data? {
        let cache = skinCache
        guard let cached = cache[account.uuid],
              let ts = cacheTimestamps[account.uuid] else { return nil }
        if !Self.isPNG(cached) {
            err("缓存内容不是合法 PNG，自动失效: \(account.uuid)")
            return nil
        }
        let ttl = TimeInterval(max(0, AppSettings.shared.avatarCacheDays) * 86400)
        return Date().timeIntervalSince1970 - ts < ttl ? cached : nil
    }

    /// PNG 文件头校验（89 50 4E 47 0D 0A 1A 0A）。
    static func isPNG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Array(data.prefix(8)) == sig
    }

    /// 是否是合法头像图像：
    /// - Minecraft skin texture: 32x32 / 64x64 / 64x32
    /// - 预渲染头像: 任意正方形（>=16x16），如 mc-heads/minotar 返回的 180x180
    /// 满足任一条件即视为合法。
    static func isAvatarImage(_ data: Data) -> Bool {
        guard isPNG(data), let image = CIImage(data: data) else { return false }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        let isSkin = (w == 32 && h == 32) || (w == 64 && h == 64) || (w == 64 && h == 32)
        let isPreRendered = (w >= 16 && w == h && w <= 2048)
        return isSkin || isPreRendered
    }

    /// 兼容旧名字（已废弃，请使用 isAvatarImage）。
    @available(*, deprecated, message: "Use isAvatarImage instead")
    static func isSkinTexture(_ data: Data) -> Bool { isAvatarImage(data) }

    /// 取缓存（即使过期也允许读取，让调用方决定是否刷新）。
    public func cachedSkin(for account: AnyAccount) -> Data? {
        skinCache[account.uuid]
    }

    /// 写入缓存。拒绝非 PNG 数据。
    public func store(_ data: Data, for account: AnyAccount) {
        guard Self.isPNG(data) else {
            err("拒绝缓存非 PNG 数据: \(account.uuid), size=\(data.count)")
            return
        }
        // 读-改-写各一次；下标直接赋值会额外触发一次 getter 全量解码。
        var cache = skinCache
        cache[account.uuid] = data
        skinCache = cache

        var timestamps = cacheTimestamps
        timestamps[account.uuid] = Date().timeIntervalSince1970
        cacheTimestamps = timestamps

        log("已缓存头像: \(account.uuid), size=\(data.count), ttl=\(AppSettings.shared.avatarCacheDays)d")
    }

    /// 加载头像：优先用缓存，过期或缺失则走网络。
    @discardableResult
    public func loadSkin(account: AnyAccount) async throws -> Data {
        if let cached = validCachedSkin(for: account) {
            return cached
        }
        let skinData = try await account.getSkinData()
        store(skinData, for: account)
        return skinData
    }

    /// 强制刷新某个账号的头像（忽略缓存 TTL）。
    @discardableResult
    public func refreshSkin(account: AnyAccount) async throws -> Data {
        let skinData = try await account.getSkinData()
        store(skinData, for: account)
        return skinData
    }

    /// 清空所有缓存。
    public func clearAll() {
        skinCache = [:]
        cacheTimestamps = [:]
        clearDecodedCache()
    }

    private init() {}
}
/// 解码后的头像缓存（进程内）。CGImage 比 Data 占内存更少，
/// 且渲染时不再需要 CoreImage 解码，避开主线程的反复 createCGImage。
public struct DecodedAvatar: @unchecked Sendable {
    public let image: CGImage
    public let extent: CGSize
    public let isSkinTexture: Bool
}

extension SkinCacheStorage {
    /// 共享的 CIContext：CIContext 创建成本高，每次 onAppear 都新建是浪费。
    /// `.useSoftwareRenderer = false`：默认 GPU 加速；CIContext 自动选择最佳后端。
    static let sharedCIContext: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false, .priorityRequestLow: true])
    }()

    /// 进程内解码缓存（UUID -> 解码结果）。key 与持久化 skinCache 一致。
    /// SwiftUI 重新进入 body 时优先命中此缓存，跳过 CoreImage 解码。
    private static let decodedLock = NSLock()
    nonisolated(unsafe) private static var _decodedCache: [UUID: DecodedAvatar] = [:]

    public func cachedDecodedAvatar(for account: AnyAccount) -> DecodedAvatar? {
        Self.decodedLock.lock(); defer { Self.decodedLock.unlock() }
        return Self._decodedCache[account.uuid]
    }

    public func storeDecoded(_ avatar: DecodedAvatar, for account: AnyAccount) {
        Self.decodedLock.lock(); defer { Self.decodedLock.unlock() }
        Self._decodedCache[account.uuid] = avatar
    }

    public func clearDecodedCache() {
        Self.decodedLock.lock(); defer { Self.decodedLock.unlock() }
        Self._decodedCache.removeAll()
    }

    /// 在后台线程解码头像数据。结果可缓存供后续 view 复用。
    /// - Parameter source: 已下载/已缓存的 PNG 数据。
    public func decodeAvatar(from source: Data) -> DecodedAvatar? {
        guard let ci = CIImage(data: source) else { return nil }
        let extent = ci.extent
        let w = extent.width, h = extent.height
        let isSkinTexture = (w == 32 && h == 32) || (w == 64 && h == 64) || (w == 64 && h == 32)
        let toRender: CIImage
        if isSkinTexture {
            // skin texture：裁剪头部（face + hat 第二层）以减少渲染工作量
            let yOffset: CGFloat = h == 32 ? 0 : 32
            toRender = ci.cropped(to: CGRect(x: 8, y: 16 + yOffset, width: 8, height: 8))
        } else {
            toRender = ci
        }
        guard let cg = Self.sharedCIContext.createCGImage(toRender, from: toRender.extent) else {
            return nil
        }
        return DecodedAvatar(image: cg, extent: toRender.extent.size, isSkinTexture: isSkinTexture)
    }
}
