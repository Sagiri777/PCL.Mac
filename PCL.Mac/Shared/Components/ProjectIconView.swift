//
//  ProjectIconView.swift
//  PCL.Mac
//
//  Modrinth 项目图标的加载与显示。
//
//  为什么单独抽一个 view：图标原来存在 `ProjectSearchViewState.iconCache` 这个
//  `@Published` 字典里。每加载完一张图就会发布一次变更，于是整份搜索结果（或整个
//  mod 列表）全部重新求值 —— 40 个结果就是 40 次全列表重渲染。
//
//  现在缓存放在非 published 的 actor 里，每行只用自己的 `@State` 存图，
//  单张图片就位只会重画那一行。NSImage 解码也移出主线程。
//

import SwiftUI
import AppKit
import ImageIO

/// 进程内图标缓存。key 为 Modrinth projectId。
actor ProjectIconCache {
    static let shared = ProjectIconCache()

    private struct Entry {
        let image: Image
        var lastAccess: UInt64
    }

    private var images: [String: Entry] = [:]
    /// 同一 projectId 的并发请求合并成一个网络任务。
    private var inflight: [String: Task<Image?, Never>] = [:]
    /// 上限保护：长时间浏览下载页不至于把所有图标都留在内存里。
    private static let capacity = 300
    private static let thumbnailPixelSize = 192
    private var accessClock: UInt64 = 0

    func cached(_ projectId: String) -> Image? {
        guard var entry = images[projectId] else { return nil }
        accessClock &+= 1
        entry.lastAccess = accessClock
        images[projectId] = entry
        return entry.image
    }

    func icon(for projectId: String, url: URL?) async -> Image? {
        if let cached = cached(projectId) { return cached }
        if let existing = inflight[projectId] { return await existing.value }
        guard let url else { return nil }

        let task = Task<Image?, Never> {
            guard let data = await Requests.get(url, category: .avatar).data else { return nil }
            // 生成接近实际显示尺寸的缩略图，避免把大型原图完整解码并常驻内存。
            return await Task.detached(priority: .utility) {
                ProjectIconCache.decodeThumbnail(data)
            }.value
        }
        inflight[projectId] = task
        let image = await task.value
        inflight[projectId] = nil

        if let image {
            if images.count >= ProjectIconCache.capacity {
                // 只淘汰最久未访问的一项，避免达到上限后整批失效并触发下载风暴。
                if let leastRecentlyUsed = images.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key {
                    images.removeValue(forKey: leastRecentlyUsed)
                }
            }
            accessClock &+= 1
            images[projectId] = Entry(image: image, lastAccess: accessClock)
        }
        return image
    }

    nonisolated private static func decodeThumbnail(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let size = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        return Image(nsImage: NSImage(cgImage: cgImage, size: size))
    }
}

/// 带占位图与淡入的项目图标。
struct ProjectIconView: View {
    let projectId: String?
    let iconURL: URL?
    let size: CGFloat
    var cornerRadius: CGFloat = 10

    @State private var image: Image?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        (image ?? Image("ModIconPlaceholder"))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: image == nil)
            .accessibilityHidden(true)
            .task(id: projectId) {
                guard let projectId else { return }
                if let hit = await ProjectIconCache.shared.cached(projectId) {
                    guard !Task.isCancelled else { return }
                    image = hit
                    return
                }
                if let loaded = await ProjectIconCache.shared.icon(for: projectId, url: iconURL) {
                    guard !Task.isCancelled else { return }
                    image = loaded
                }
            }
    }
}
