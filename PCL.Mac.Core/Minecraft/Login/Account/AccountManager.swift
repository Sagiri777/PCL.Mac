//
//  AccountManager.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/29.
//

import Foundation
import CoreImage
import SwiftyJSON

public protocol Account: Codable, Identifiable {
    var id: UUID { get }
    var uuid: UUID { get }
    var name: String { get }
    func putAccessToken(options: LaunchOptions) async
}

public enum AnyAccount: Account, Identifiable, Equatable {
    case offline(OfflineAccount)
    case microsoft(MicrosoftAccount)
    case yggdrasil(YggdrasilAccount)
    
    private var account: any Account {
        switch self {
        case .offline(let account): return account
        case .microsoft(let account): return account
        case .yggdrasil(let account): return account
        }
    }
    
    public var id: UUID { account.id }
    public var uuid: UUID { account.uuid }
    public var name: String { account.name }
    
    public static func == (lhs: AnyAccount, rhs: AnyAccount) -> Bool {
        lhs.id == rhs.id
    }
    
    public func putAccessToken(options: LaunchOptions) async { await account.putAccessToken(options: options) }
    
    // MARK: - Codable
    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum AccountType: String, Codable { case offline, microsoft, yggdrasil }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(AccountType.self, forKey: .type) {
        case .offline:    self = .offline(try container.decode(OfflineAccount.self, forKey: .payload))
        case .microsoft:  self = .microsoft(try container.decode(MicrosoftAccount.self, forKey: .payload))
        case .yggdrasil:  self = .yggdrasil(try container.decode(YggdrasilAccount.self, forKey: .payload))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offline(let value):
            try container.encode(AccountType.offline, forKey: .type)
            try container.encode(value, forKey: .payload)
        case .microsoft(let value):
            try container.encode(AccountType.microsoft, forKey: .type)
            try container.encode(value, forKey: .payload)
        case .yggdrasil(let value):
            try container.encode(AccountType.yggdrasil, forKey: .type)
            try container.encode(value, forKey: .payload)
        }
    }
    
    public func getSkinData() async throws -> Data {
        switch self {
        case .offline(_), .microsoft(_):
            return await fetchFromTemplates()
        case .yggdrasil(let yggdrasilAccount):
            guard let textures = try await yggdrasilAccount.client.getProfile(id: yggdrasilAccount.uuid).properties["textures"] else {
                return Self.placeholderSkinPNG
            }
            let json = try JSON(data: Data(base64Encoded: textures) ?? .init())
            guard let raw = URL(string: json["textures"]["SKIN"]["url"].stringValue) else {
                return Self.placeholderSkinPNG
            }
            return try await Requests.get(raw, category: .minecraftAPI).getDataOrThrow()
        }
    }

    /// 通用化模板处理：依次尝试每个模板。
    /// - 替换占位符：`{uuid}` = strippedUUID，`{username}` = 当前账号 username
    /// - 如果响应 Content-Type 是 JSON，解析后从 `skin_url` 再请求 PNG
    /// - 如果响应是 PNG/Skin（魔数校验），直接返回
    /// 全失败用占位图兜底。
    private func fetchFromTemplates() async -> Data {
        let templates = AppSettings.shared.avatarSources.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !templates.isEmpty else {
            err("头像源列表为空，使用占位图")
            return Self.placeholderSkinPNG
        }
        let strippedUUID = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let username = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for template in templates {
            var urlString = template
            urlString = urlString.replacingOccurrences(of: "{uuid}", with: strippedUUID)
            if username.isEmpty {
                urlString = urlString.replacingOccurrences(of: "{username}", with: "Player")
            } else {
                urlString = urlString.replacingOccurrences(of: "{username}", with: username)
            }
            guard let url = URL(string: urlString) else {
                err("头像源模板无效: \(template)")
                continue
            }
            let response = await Requests.get(url, ignoredFailureStatusCodes: Array(400...599), category: .avatar)
            guard response.statusCode == 200, let data = response.data, !data.isEmpty else {
                err("头像源 \(url.host ?? "?") 失败: HTTP \(response.statusCode)")
                continue
            }

            // JSON 响应（uapis.cn 类型）：解析 → skin_url
            if response.contentType.contains("json"),
               let json = try? JSON(data: data),
               let skinURLString = json["skin_url"].string,
               !skinURLString.isEmpty,
               let skinURL = URL(string: skinURLString) {
                log("JSON API \(url.host ?? "?") → skin_url: \(skinURLString)")
                let png = await Requests.get(skinURL, ignoredFailureStatusCodes: Array(400...599))
                if png.statusCode == 200, let bytes = png.data, SkinCacheStorage.isAvatarImage(bytes) {
                    log("skin_url 拉取成功: \(bytes.count) bytes")
                    return bytes
                }
                err("skin_url 拉取失败: HTTP \(png.statusCode)")
                continue
            }

            // 直接 PNG 响应：必须是合法 Minecraft skin texture 尺寸（32x32 / 64x64 / 64x32）
            if SkinCacheStorage.isAvatarImage(data) {
                log("头像源 \(url.host ?? "?") 返回 \(data.count) bytes")
                return data
            }
            err("头像源 \(url.host ?? "?") 响应非 skin texture (ct=\(response.contentType), size=\(data.count))")
        }
        err("所有头像源均不可用，使用占位图")
        return Self.placeholderSkinPNG
    }

    static let placeholderSkinPNG: Data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAdVBMVEUAAAD///+l2sAzMyzeV4KvLyqclkAr68ApKSbY0mUYD4ElZWPX6QWT8FiIiBUzkAf38Denp2SzNVVVV3QjVSPYlqQDBKSkpGOqUAaGhBNZs/Pz86MYk3Nzc/KhVJJRAoKCg0JRIzJBFCHQorHg0mGgokGAjoejraAAAAAXRSTlMAQObYZgAAAtFJREFUeNrtlm132jAMhelKFWuOHdr1hYYkZcbz//+Ju5LjsXRwEujHcSNsOefc50gmEK+KYgyIEJtRq0sVw4AQwBN0DQBmudyTyl0OgDvgcz0g5iZcbuFyQAggxGFoXAO5+nKA7AFUN/m6GAB3BCM29QfU1MuN4kwyDhAIWASZgmZxye7HlEJAwC9XEhxikPvDot6jDLz+tib+qeshBC0D1FmAVpxiZFqviYjVldvQRuYB+vhxorsX4pc7Suz0VkgKCku+/5AYInp9JWIoaf0pCSTOAlJMjuvmu6s/np8PSJqaHW4KIC4BNA5+FuPh44Dv32HBTh7HX9DCX2UH9f1+X9b3xMDSfTeq3K+qyjARnQTs933/B8AO4pMAAvxsBbOABwDmKzjfgpEWPlfQtl273W47TG2L2UKVIWYyVc4NRlgrZJg2kCyOgO4I2ELWe1tVlgij5pDa1Q/A+/sG6REwGtsC8I+P3sAiA3IlWAm1G6sALE4DEI9QMUluxIXPZtQ7JPMEIG0IoYPE5I0C/AiwAmFmJ5cKi2kFCLgVJGV7YxQwtqAFERETY4CboCkAKrOHrJSNbSi5LJkyQgGII6CdAiw8Xso2xkquACMAlTYyqaBTo2CQQdZbhNEiNEMCv2diBUBTwNtbN+pNBZcyYLQiccPvCYBCmAD6HVw/xLqTdJe/DNTjYZMEHSHZZgBnAP8N6PudGHc9hBEA7Wnbep/3BSyMTPDmLVDE6qb/Ug9ZlYEqJKubbvqk2ZetvJOIiCW/5sChAMdEX6jgoSLoKxUYx4taKOeFti0v3Q1UXu2ieUBxdgBB+jpXgo7LAJ0A2iPAZjNiaQUFgKycB4rG/4OiI/DcecGJWC6Vm68AZkgrkJxhzUeDrMtagASgdqUwLd9ESABOASqdFjxE5UlABmnvap8BnDsvFL/YZwCnzwsK4ALgGcCJ8wLnTUCQTP/8Hn4DsAh5tPm8HxQAAAAASUVORK5CYII=") ?? Data()
}

public class AccountManager: ObservableObject {
    public static let shared: AccountManager = .init()
    
    @CodableAppStorage("accounts") public var accounts: [AnyAccount] = []
    
    @CodableAppStorage("accountId") public var accountId: UUID? = nil
    
    public func getAccount() -> AnyAccount? {
        if accountId == nil {
            if let id = accounts.first?.id {
                accountId = id
            } else {
                return nil
            }
        }
        
        if let account = accounts.first(where: { $0.id == accountId }) {
            return account
        }
        
        warn("accountId 对应的账号不存在！")
        accountId = nil
        return nil
    }
}
