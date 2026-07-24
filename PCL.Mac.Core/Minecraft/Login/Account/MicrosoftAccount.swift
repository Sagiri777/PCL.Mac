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

public class MicrosoftAccount: Account {
    public let id: UUID
    public var refreshToken: String
    public var profile: PlayerProfile
    public var isTokenRefreshing: Bool = false
    
    public var name: String { profile.name }
    public var uuid: UUID { profile.uuid }
    
    public func refreshAccessToken() async {
        if isTokenRefreshing { return }
        isTokenRefreshing = true
        if AccessTokenStorage.shared.getTokenInfo(for: id) != nil {
            debug("无需刷新 Access Token")
            return
        }
        
        if let authToken = try? await MsLogin.refreshAccessTokenLive(self.refreshToken) {
            if (try? await MsLogin.getMinecraftAccessToken(id: id, authToken.accessToken)) != nil {
                self.refreshToken = authToken.refreshToken
                debug("成功刷新 Access Token")
                return
            }
        }
        err("无法刷新 Access Token")
    }
    
    enum CodingKeys: CodingKey {
        case id
        case refreshToken
        case profile
    }
    
    public init(refreshToken: String, profile: PlayerProfile) {
        self.id = .init()
        self.refreshToken = refreshToken
        self.profile = profile
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
            return .init(refreshToken: authToken.refreshToken, profile: profile)
        } catch {
            err("MicrosoftAccount.create 失败：\(error.localizedDescription)")
            return nil
        }
    }
    
    public func putAccessToken(options: LaunchOptions) async {
        await self.refreshAccessToken()
        options.accessToken = AccessTokenStorage.shared.getTokenInfo(for: id)?.accessToken ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
