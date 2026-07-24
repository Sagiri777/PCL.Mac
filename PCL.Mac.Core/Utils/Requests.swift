//
//  Requests.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/11.
//

import Foundation
import SwiftyJSON

public protocol URLConvertible {
    var url: URL { get }
}

extension URL: URLConvertible {
    public var url: URL { self }
}

extension String: URLConvertible {
    public var url: URL { URL(string: self) ?? URL(fileURLWithPath: "/") }
}

public enum EncodeMethod {
    case json
    case urlEncoded
}

/// 网络请求类别，决定是否走代理。
public enum NetworkCategory: Sendable {
    case avatar           // 头像 CDN（mc-heads/crafatar/textures.minecraft.net/uapis.cn）
    case microsoftLogin   // 微软 OAuth 登录
    case minecraftAPI     // 微软 Xbox/Minecraft 服务（XBL/XSTS/minecraftservices）
    case gameDownload     // 游戏下载、版本列表、mod 搜索
    case announcement     // 公告/PCL 服务器配置
    case other            // 其他未分类请求（默认走直连）
}

public struct Response: Sendable {
    public let data: Data?
    public let json: JSON?
    public let error: Error?
    public let statusCode: Int
    public let contentType: String

    public func getDataOrThrow() throws -> Data {
        guard let data = self.data else {
            throw self.error ?? NSError(domain: "data 为空", code: -1)
        }

        return data
    }
    
    public func getJSONOrThrow() throws -> JSON {
        let data = try getDataOrThrow()
        if data.isEmpty {
            throw MyLocalizedError(reason: "响应为空")
        }
        do {
            return try JSON(data: data)
        } catch {
            throw MyLocalizedError(reason: "JSON 解析失败: \(error.localizedDescription)")
        }
    }
}

public final class Requests: @unchecked Sendable {
    public static func request(
        url: URL,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: [String: Any]? = nil,
        encodeMethod: EncodeMethod = .json,
        ignoredFailureStatusCodes: [Int],
        category: NetworkCategory = .other
    ) async -> Response {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            
            headers?.forEach { key, value in
                request.setValue(value, forHTTPHeaderField: key)
            }
            
            if let body = body {
                switch encodeMethod {
                case .json:
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
                case .urlEncoded:
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    if method == "GET" {
                        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                            components.queryItems = body.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
                            request.url = components.url
                        }
                    } else {
                        let query = body.map { key, value -> String in
                            let val = String(describing: value)
                            let encoded = val.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? val
                            return "\(key)=\(encoded)"
                        }.joined(separator: "&")
                        request.httpBody = query.data(using: .utf8)
                    }
                }
            }
            
            let session = Self.makeSession(forceUseProxy: Self.shouldUseProxy(for: category))
            let (data, response) = try await session.data(for: request)
            if let response = response as? HTTPURLResponse, response.statusCode != 200 && !ignoredFailureStatusCodes.contains(response.statusCode) {
                debug("\(url.absoluteString) 返回了 \(response.statusCode): \(String(data: data, encoding: .utf8) ?? "(empty)")")
            }
            let httpResp = response as? HTTPURLResponse
            let code = httpResp?.statusCode ?? 0
            let ct = httpResp?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let json = try? JSON(data: data)
            return Response(data: data, json: json, error: nil, statusCode: code, contentType: ct)
        } catch let error as URLError where error.code == .cancelled {
            return Response(data: nil, json: nil, error: nil, statusCode: 0, contentType: "")
        } catch {
            err("在发送请求时发生错误: \(error)")
            return Response(data: nil, json: nil, error: error, statusCode: 0, contentType: "")
        }
    }

    public static func get(
        _ url: URLConvertible,
        headers: [String: String]? = nil,
        body: [String: Any]? = nil,
        encodeMethod: EncodeMethod = .urlEncoded,
        ignoredFailureStatusCodes: [Int] = [],
        category: NetworkCategory = .other
    ) async -> Response {
        return await request(url: url.url, method: "GET", headers: headers, body: body, encodeMethod: encodeMethod, ignoredFailureStatusCodes: ignoredFailureStatusCodes, category: category)
    }

    /// 根据 NetworkCategory 决定是否对当前请求走代理。
    public static func shouldUseProxy(for category: NetworkCategory) -> Bool {
        let s = AppSettings.shared
        guard s.proxyEnabled, !s.proxyHost.isEmpty, s.proxyPort > 0 else { return false }
        switch category {
        case .avatar:         return s.proxyForAvatar
        case .microsoftLogin: return s.proxyForMicrosoftLogin
        case .minecraftAPI:   return s.proxyForMinecraftAPI
        case .gameDownload:   return s.proxyForGameDownload
        case .announcement:   return s.proxyForAnnouncement
        case .other:          return s.proxyForOther
        }
    }

    /// 构造带代理配置的 URLSessionConfiguration。
    public static func makeConfiguration(forceUseProxy: Bool = false) -> URLSessionConfiguration {
        let settings = AppSettings.shared
        guard forceUseProxy,
              settings.proxyEnabled,
              !settings.proxyHost.isEmpty,
              settings.proxyPort > 0 else {
            return URLSessionConfiguration.default
        }
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            kCFProxyTypeKey: kCFProxyTypeHTTP,
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: settings.proxyHost,
            kCFNetworkProxiesHTTPPort: settings.proxyPort,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: settings.proxyHost,
            kCFNetworkProxiesHTTPSPort: settings.proxyPort
        ]
        return config
    }

    /// 构造带代理配置的 URLSession。如果代理未启用，返回默认 session。
    public static func makeSession(forceUseProxy: Bool = false) -> URLSession {
        guard forceUseProxy else { return URLSession.shared }
        return URLSession(configuration: makeConfiguration(forceUseProxy: true))
    }

    public static func post(
        _ url: URLConvertible,
        headers: [String: String]? = nil,
        body: [String: Any]? = nil,
        encodeMethod: EncodeMethod = .json,
        ignoredFailureStatusCodes: [Int] = [],
        category: NetworkCategory = .other
    ) async -> Response {
        return await request(url: url.url, method: "POST", headers: headers, body: body, encodeMethod: encodeMethod, ignoredFailureStatusCodes: ignoredFailureStatusCodes, category: category)
    }
}
