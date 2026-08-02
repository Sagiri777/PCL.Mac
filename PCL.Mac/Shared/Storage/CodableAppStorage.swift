//
//  CodableAppStorage.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/3.
//

import Foundation

/// 复用的编解码器。放在泛型类型外部：泛型类型不允许 static stored property，
/// 而每次调用新建 JSONEncoder/JSONDecoder 本身就是这里要消除的开销之一。
private enum CodableStorageCoders {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

/// UserDefaults 中以 JSON 持久化的设置项。
///
/// 性能约束：getter 在热路径上被大量调用 —— `currentMinecraftDirectory` 出现在
/// view init / body 里，`fileDownloadSource` 出现在每个下载条目上，
/// `lastVersionManifest` 是上千条 GameVersion 的大 blob。早期实现每次读取都新建
/// `JSONDecoder` 并解码整个 blob，每次写入都重新编码并无条件广播
/// `DataManager.objectWillChange`（= 整棵界面失效）。
///
/// 现在：解码结果按底层字节缓存，编解码器复用，写入时若字节没变则跳过存储与广播。
@propertyWrapper
public struct CodableAppStorage<T: Codable> {
    /// 缓存需要在 wrapper 的多次 copy 之间共享，因此用引用类型持有。
    private final class Box {
        var cachedData: Data?
        var cachedValue: T?
    }

    private let key: String
    private let store: UserDefaults
    private let defaultValue: T
    private let box = Box()

    public var wrappedValue: T {
        get {
            guard let data = store.data(forKey: key) else {
                box.cachedData = nil
                box.cachedValue = nil
                return defaultValue
            }

            // 字节完全一致说明值没被外部改过，直接复用已解码对象。
            if let cachedValue = box.cachedValue, box.cachedData == data {
                return cachedValue
            }

            guard let decoded = try? CodableStorageCoders.decoder.decode(T.self, from: data) else {
                return defaultValue
            }
            box.cachedData = data
            box.cachedValue = decoded
            return decoded
        }
        nonmutating set {
            guard let data = try? CodableStorageCoders.encoder.encode(newValue) else { return }

            // 值没有实际变化时不写盘也不广播 —— 否则像 VersionListView.onAppear 里
            // 「重新赋值当前 Minecraft 目录」这种幂等写入都会触发一次全界面重渲染。
            if box.cachedData == data, store.data(forKey: key) == data {
                box.cachedValue = newValue
                return
            }

            store.set(data, forKey: key)
            box.cachedData = data
            box.cachedValue = newValue
            DispatchQueue.main.async {
                DataManager.shared.objectWillChange.send()
            }
        }
    }

    public init(wrappedValue: T, _ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.store = store
        self.defaultValue = wrappedValue
        // 初始写入（仅当没有值时）
        if store.data(forKey: key) == nil,
           let data = try? CodableStorageCoders.encoder.encode(wrappedValue) {
            store.set(data, forKey: key)
            box.cachedData = data
            box.cachedValue = wrappedValue
        }
    }
}
