//
//  MinecraftAvatar.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/30.
//

import SwiftUI
import CoreImage
import AppKit

struct MinecraftAvatar: View {
    // 直接缓存解码后的 CGImage，避免每次 body 重渲都跑 CoreImage。
    @State private var decoded: CGImage?

    private let account: AnyAccount
    private let src: String
    private let size: CGFloat

    init(account: AnyAccount, src: String, size: CGFloat = 58) {
        self.account = account
        self.src = src
        self.size = size
        if let cached = SkinCacheStorage.shared.cachedDecodedAvatar(for: account) {
            self._decoded = State(initialValue: cached.image)
        }
    }

    var body: some View {
        ZStack {
            if let decoded = decoded {
                AvatarImageView(decoded: decoded, size: size)
                    .shadow(color: Color.black.opacity(0.2), radius: 1)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .padding(6)
        .task(id: account.uuid) {
            // 1) 进程内解码缓存命中：直接用，跳过网络和解码。
            if let hit = SkinCacheStorage.shared.cachedDecodedAvatar(for: account) {
                if decoded == nil || decoded != hit.image { decoded = hit.image }
                return
            }
            // 2) 加载 PNG 数据（命中持久化缓存或拉网络）。
            let data: Data
            do {
                data = try await SkinCacheStorage.shared.loadSkin(account: account)
            } catch {
                err("无法加载头像: \(error.localizedDescription)")
                return
            }
            // 3) 后台解码（CoreImage + GPU），主线程只更新 CGImage 引用。
            let avatar = await Task.detached(priority: .userInitiated) {
                SkinCacheStorage.shared.decodeAvatar(from: data)
            }.value
            guard let avatar else { return }
            SkinCacheStorage.shared.storeDecoded(avatar, for: account)
            decoded = avatar.image
        }
    }
}

/// 通用头像渲染：传入已解码的 CGImage，不再每次 onAppear 重复解码。
struct AvatarImageView: View {
    let decoded: CGImage
    let size: CGFloat

    /// 预渲染头像（非 skin texture 尺寸）使用 .medium 插值；
    /// skin texture 头部裁剪（8x8 → 放大到 58pt）使用 .none 保留像素感。
    private var isPreRendered: Bool {
        decoded.width != 8 || decoded.height != 8
    }

    var body: some View {
        Image(nsImage: NSImage(cgImage: decoded, size: CGSize(width: decoded.width, height: decoded.height)))
            .interpolation(isPreRendered ? .medium : .none)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
