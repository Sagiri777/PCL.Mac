//
//  YggdrasilAccount.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 8/8/25.
//

import Foundation

public class YggdrasilAccount: Account {
    public let id: UUID
    public lazy var client: YggdrasilClient = { YggdrasilClient(authenticationServer) }()
    
    /// 账户所属验证服务器
    public let authenticationServer: URL
    
    /// 验证服务器名称
    public let authenticationServerName: String
    
    /// 账户所对应角色的 UUID
    public var uuid: UUID
    
    /// 账户所对应角色的名称
    public var name: String
    
    private var legacyAccessToken: String?
    private var legacyClientToken: String?
    
    public init(authenticationServer: URL, accountIdentifier: String, password: String) async throws {
        self.id = UUID()
        self.authenticationServer = authenticationServer
        self.authenticationServerName = try await Requests.get(authenticationServer).getJSONOrThrow()["meta"]["serverName"].stringValue
        
        let client = YggdrasilClient(authenticationServer)
        let response = try await client.authenticate(identifier: accountIdentifier, password: password)
        
        self.uuid = response.profileUUID
        self.name = response.profileName
        guard SecureCredentialStore.shared.set(
            response.accessToken,
            kind: .yggdrasilAccessToken,
            accountID: id
        ), SecureCredentialStore.shared.set(
            response.clientToken,
            kind: .yggdrasilClientToken,
            accountID: id
        ) else {
            removeStoredCredentials()
            throw MyLocalizedError(reason: "无法将外置登录凭据保存到 Keychain。")
        }
    }
    
    public func putAccessToken(options: LaunchOptions) async throws {
        guard let accessToken = SecureCredentialStore.shared.string(
            kind: .yggdrasilAccessToken,
            accountID: id
        ) ?? legacyAccessToken else {
            throw MyLocalizedError(reason: "外置登录凭据不存在，请重新登录。")
        }
        options.yggdrasilArguments.append("-javaagent:${authlib_injector_path}=\(authenticationServer.absoluteString)")
        if let data = await Requests.get(authenticationServer).data {
            options.yggdrasilArguments.append("-Dauthlibinjector.yggdrasil.prefetched=\(data.base64EncodedString())")
        }
        options.accessToken = accessToken
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case authenticationServer
        case authenticationServerName
        case uuid
        case name
        case accessToken
        case clientToken
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        authenticationServer = try container.decode(URL.self, forKey: .authenticationServer)
        authenticationServerName = try container.decode(String.self, forKey: .authenticationServerName)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        name = try container.decode(String.self, forKey: .name)
        legacyAccessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        legacyClientToken = try container.decodeIfPresent(String.self, forKey: .clientToken)
        _ = migrateLegacyCredentials()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(authenticationServer, forKey: .authenticationServer)
        try container.encode(authenticationServerName, forKey: .authenticationServerName)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
    }

    var credentialsAreSecure: Bool {
        SecureCredentialStore.shared.string(kind: .yggdrasilAccessToken, accountID: id) != nil &&
        SecureCredentialStore.shared.string(kind: .yggdrasilClientToken, accountID: id) != nil
    }

    @discardableResult
    func migrateLegacyCredentials() -> Bool {
        if credentialsAreSecure {
            legacyAccessToken = nil
            legacyClientToken = nil
            return true
        }
        guard let legacyAccessToken, let legacyClientToken else { return false }
        let accessSaved = SecureCredentialStore.shared.set(
            legacyAccessToken,
            kind: .yggdrasilAccessToken,
            accountID: id
        )
        let clientSaved = SecureCredentialStore.shared.set(
            legacyClientToken,
            kind: .yggdrasilClientToken,
            accountID: id
        )
        if accessSaved && clientSaved {
            self.legacyAccessToken = nil
            self.legacyClientToken = nil
            return true
        }
        return false
    }

    func removeStoredCredentials() {
        SecureCredentialStore.shared.remove(kind: .yggdrasilAccessToken, accountID: id)
        SecureCredentialStore.shared.remove(kind: .yggdrasilClientToken, accountID: id)
    }
}
