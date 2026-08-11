//
//  MicrosoftAccount.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/29.
//

import Foundation
import SwiftyJSON

public class PlayerProfile: Codable {
    public let uuid: UUID
    public let name: String

    public init(fromResponse data: Data) throws {
        let json: JSON
        do {
            json = try JSON(data: data)
        } catch {
            throw MyLocalizedError(reason: "PlayerProfile 解析失败：\(error.localizedDescription)")
        }
        // 微软返回的 id 是无连字符的 32 字符 hex，需要插入连字符
        let rawId = json["id"].stringValue
        let dashedId: String
        if rawId.contains("-") {
            dashedId = rawId
        } else if rawId.count == 32 {
            let s = Array(rawId)
            dashedId = "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
        } else {
            throw MyLocalizedError(reason: "无效的玩家 UUID：\(rawId)")
        }
        guard let parsedUUID = UUID(uuidString: dashedId) else {
            throw MyLocalizedError(reason: "UUID 解析失败：\(dashedId)")
        }
        self.uuid = parsedUUID
        self.name = json["name"].stringValue
    }
}

private actor MicrosoftTokenRefreshCoordinator {
    private var inFlight: Task<(AuthToken, String), Error>?

    func refresh(accountID: UUID, refreshToken: String) async throws -> (AuthToken, String) {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<(AuthToken, String), Error> {
            guard let authToken = try await MsLogin.refreshAccessTokenLive(refreshToken) else {
                throw MyLocalizedError(reason: "微软登录凭据已失效，请重新登录。")
            }
            guard let minecraftToken = try await MsLogin.getMinecraftAccessToken(
                id: accountID,
                authToken.accessToken
            ) else {
                throw MyLocalizedError(reason: "无法获取 Minecraft Access Token，请稍后重试。")
            }
            return (authToken, minecraftToken)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

public class MicrosoftAccount: Account {
    public let id: UUID
    public var profile: PlayerProfile
    private var legacyRefreshToken: String?
    private lazy var refreshCoordinator = MicrosoftTokenRefreshCoordinator()
    
    public var name: String { profile.name }
    public var uuid: UUID { profile.uuid }
    
    @discardableResult
    public func refreshAccessToken() async throws -> String {
        if let token = AccessTokenStorage.shared.getTokenInfo(for: id)?.accessToken {
            debug("无需刷新 Access Token")
            return token
        }

        guard let refreshToken = secureRefreshToken, !refreshToken.isEmpty else {
            throw MyLocalizedError(reason: "微软登录凭据不存在，请重新登录。")
        }

        let (authToken, minecraftToken) = try await refreshCoordinator.refresh(
            accountID: id,
            refreshToken: refreshToken
        )
        guard SecureCredentialStore.shared.set(
            authToken.refreshToken,
            kind: .microsoftRefreshToken,
            accountID: id
        ) else {
            throw MyLocalizedError(reason: "无法安全保存微软登录凭据，请检查 Keychain 权限。")
        }
        legacyRefreshToken = nil
        debug("成功刷新 Access Token")
        return minecraftToken
    }
    
    enum CodingKeys: CodingKey {
        case id
        case refreshToken
        case profile
    }
    
    public init(refreshToken: String, profile: PlayerProfile) throws {
        self.id = .init()
        self.profile = profile
        guard SecureCredentialStore.shared.set(
            refreshToken,
            kind: .microsoftRefreshToken,
            accountID: id
        ) else {
            throw MyLocalizedError(reason: "无法将微软登录凭据保存到 Keychain。")
        }
    }
    
    public static func create(_ authToken: AuthToken) async -> MicrosoftAccount? {
        guard let accessToken = authToken.minecraftAccessToken else {
            return nil
        }
        guard let url = URL(string: "https://api.minecraftservices.com/minecraft/profile") else {
            return nil
        }
        guard let data = await Requests.get(url, headers: [
            "Authorization": "Bearer \(accessToken)"
        ]).data else {
            return nil
        }
        do {
            let profile = try PlayerProfile(fromResponse: data)
            return try .init(refreshToken: authToken.refreshToken, profile: profile)
        } catch {
            err("MicrosoftAccount.create 失败：\(error.localizedDescription)")
            return nil
        }
    }
    
    public func putAccessToken(options: LaunchOptions) async throws {
        options.accessToken = try await refreshAccessToken()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profile = try container.decode(PlayerProfile.self, forKey: .profile)
        legacyRefreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        _ = migrateLegacyCredentials()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profile, forKey: .profile)
    }

    var credentialsAreSecure: Bool {
        SecureCredentialStore.shared.string(
            kind: .microsoftRefreshToken,
            accountID: id
        ) != nil
    }

    @discardableResult
    func migrateLegacyCredentials() -> Bool {
        if credentialsAreSecure {
            legacyRefreshToken = nil
            return true
        }
        guard let legacyRefreshToken else { return false }
        let saved = SecureCredentialStore.shared.set(
            legacyRefreshToken,
            kind: .microsoftRefreshToken,
            accountID: id
        )
        if saved { self.legacyRefreshToken = nil }
        return saved
    }

    func removeStoredCredentials() {
        SecureCredentialStore.shared.remove(kind: .microsoftRefreshToken, accountID: id)
        AccessTokenStorage.shared.remove(id: id)
    }

    private var secureRefreshToken: String? {
        SecureCredentialStore.shared.string(
            kind: .microsoftRefreshToken,
            accountID: id
        ) ?? legacyRefreshToken
    }
}
