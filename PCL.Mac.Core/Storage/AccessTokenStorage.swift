//
//  AccessTokenStorage.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/1.
//

import Foundation
import Security

enum CredentialKind: String {
    case minecraftAccessToken = "minecraft.access"
    case microsoftRefreshToken = "microsoft.refresh"
    case yggdrasilAccessToken = "yggdrasil.access"
    case yggdrasilClientToken = "yggdrasil.client"
}

/// 账号密钥的唯一持久化入口。UserDefaults 仅保留非敏感的账号元数据与过期时间。
final class SecureCredentialStore {
    static let shared = SecureCredentialStore()

    private let service = "io.github.pcl-community.PCL-Mac.credentials"

    private init() {}

    @discardableResult
    func set(_ value: String, kind: CredentialKind, accountID: UUID) -> Bool {
        guard let data = value.data(using: .utf8), !value.isEmpty else { return false }
        let account = key(kind: kind, accountID: accountID)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            err("Keychain 更新失败：\(updateStatus)")
            return false
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            err("Keychain 写入失败：\(addStatus)")
            return false
        }
        return true
    }

    func string(kind: CredentialKind, accountID: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key(kind: kind, accountID: accountID),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            err("Keychain 读取失败：\(status)")
            return nil
        }
        return value
    }

    func remove(kind: CredentialKind, accountID: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key(kind: kind, accountID: accountID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            err("Keychain 删除失败：\(status)")
        }
    }

    private func key(kind: CredentialKind, accountID: UUID) -> String {
        "\(kind.rawValue).\(accountID.uuidString.lowercased())"
    }
}

struct AccessTokenInfo: Codable, Identifiable {
    let id: UUID
    let accessToken: String
    let expiresAt: Date

    init(id: UUID, accessToken: String, expiriesIn: Int) {
        self.id = id
        self.accessToken = accessToken
        self.expiresAt = Date().addingTimeInterval(TimeInterval(max(0, expiriesIn)))
    }

    init(id: UUID, accessToken: String, expiresAt: Date) {
        self.id = id
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    var isExpired: Bool {
        expiresAt <= Date()
    }
}

final class AccessTokenStorage: ObservableObject {
    static let shared = AccessTokenStorage()

    private static let expiryStorageKey = "accessTokenExpiries"
    private static let legacyStorageKey = "accessTokens"
    private let lock = NSLock()
    private var expiries: [UUID: Date]

    private init(defaults: UserDefaults = .standard) {
        expiries = Self.decodeExpiries(from: defaults.data(forKey: Self.expiryStorageKey))
        migrateLegacyTokens(in: defaults)
        removeExpiredTokens()
    }

    @discardableResult
    func add(id: UUID, accessToken: String, expiriesIn: Int) -> Bool {
        guard SecureCredentialStore.shared.set(
            accessToken,
            kind: .minecraftAccessToken,
            accountID: id
        ) else {
            err("Access Token 未能写入 Keychain")
            return false
        }

        lock.lock()
        expiries[id] = Date().addingTimeInterval(TimeInterval(max(0, expiriesIn)))
        persistExpiriesLocked()
        lock.unlock()
        return true
    }

    func getTokenInfo(for id: UUID) -> AccessTokenInfo? {
        lock.lock()
        guard let expiresAt = expiries[id] else {
            lock.unlock()
            return nil
        }
        if expiresAt <= Date() {
            expiries.removeValue(forKey: id)
            persistExpiriesLocked()
            lock.unlock()
            SecureCredentialStore.shared.remove(kind: .minecraftAccessToken, accountID: id)
            return nil
        }
        lock.unlock()

        guard let token = SecureCredentialStore.shared.string(
            kind: .minecraftAccessToken,
            accountID: id
        ) else {
            remove(id: id)
            return nil
        }
        return AccessTokenInfo(id: id, accessToken: token, expiresAt: expiresAt)
    }

    var allTokens: [AccessTokenInfo] {
        lock.lock()
        let snapshot = expiries
        lock.unlock()
        return snapshot.compactMap { id, expiresAt in
            guard expiresAt > Date(),
                  let token = SecureCredentialStore.shared.string(
                    kind: .minecraftAccessToken,
                    accountID: id
                  ) else { return nil }
            return AccessTokenInfo(id: id, accessToken: token, expiresAt: expiresAt)
        }
    }

    func remove(id: UUID) {
        lock.lock()
        expiries.removeValue(forKey: id)
        persistExpiriesLocked()
        lock.unlock()
        SecureCredentialStore.shared.remove(kind: .minecraftAccessToken, accountID: id)
    }

    func removeExpiredTokens() {
        lock.lock()
        let expiredIDs = expiries.compactMap { $0.value <= Date() ? $0.key : nil }
        expiredIDs.forEach { expiries.removeValue(forKey: $0) }
        persistExpiriesLocked()
        lock.unlock()
        expiredIDs.forEach {
            SecureCredentialStore.shared.remove(kind: .minecraftAccessToken, accountID: $0)
        }
    }

    private func migrateLegacyTokens(in defaults: UserDefaults) {
        guard let data = defaults.data(forKey: Self.legacyStorageKey),
              let legacy = try? JSONDecoder().decode([UUID: AccessTokenInfo].self, from: data) else {
            return
        }

        var migratedAll = true
        for (id, info) in legacy where !info.isExpired {
            let saved = SecureCredentialStore.shared.set(
                info.accessToken,
                kind: .minecraftAccessToken,
                accountID: id
            )
            if saved {
                expiries[id] = info.expiresAt
            } else {
                migratedAll = false
            }
        }
        persistExpiriesLocked()
        if migratedAll {
            defaults.removeObject(forKey: Self.legacyStorageKey)
            log("已将旧版 Access Token 迁移到 Keychain")
        }
    }

    private func persistExpiriesLocked() {
        guard let data = try? JSONEncoder().encode(expiries) else { return }
        UserDefaults.standard.set(data, forKey: Self.expiryStorageKey)
    }

    private static func decodeExpiries(from data: Data?) -> [UUID: Date] {
        guard let data,
              let decoded = try? JSONDecoder().decode([UUID: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
