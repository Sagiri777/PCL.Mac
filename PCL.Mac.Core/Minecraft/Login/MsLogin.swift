//
//  MsLogin.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/1.
//

import Foundation
import SwiftUI
import UserNotifications
import SwiftyJSON

public class AuthToken: ObservableObject {
    @Published fileprivate(set) var minecraftAccessToken: String?
    @Published private(set) var accessToken: String
    @Published private(set) var refreshToken: String
    
    init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

public struct DeviceAuthResponse {
    let deviceCode: String
    let expiresIn: Int
    let interval: Int
    let userCode: String
    let verificationUri: String
    
    init(_ json: JSON) {
        self.deviceCode = json["device_code"].stringValue
        self.expiresIn = json["expires_in"].intValue
        self.interval = json["interval"].intValue
        self.userCode = json["user_code"].stringValue
        self.verificationUri = json["verification_uri"].stringValue
    }
}

@MainActor
public class MsLogin {
    // MARK: 获取代码对
    public static func getDeviceCode() async throws -> DeviceAuthResponse? {
        let clientID: String
        do {
            clientID = try Secrets.getClientID()
        } catch {
            await PopupManager.shared.show(.init(.error, "无法登录", error.localizedDescription, [.ok]))
            return nil
        }
        guard !clientID.isEmpty else {
            await PopupManager.shared.show(.init(.error, "无法登录",
                "未配置 Microsoft OAuth client_id。请在 Settings > 账户 中查看说明。",
                [.ok]))
            return nil
        }

        let response = await Requests.post(
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
            body: [
                "client_id": clientID,
                "scope": "XboxLive.signin offline_access"
            ],
            encodeMethod: .urlEncoded
        )

        // 检查 HTTP 错误（device code 失败）
        if let err = response.error {
            await PopupManager.shared.show(.init(.error, "登录请求失败",
                "Microsoft OAuth 返回错误：\(err.localizedDescription)\n请检查 client_id 是否正确。",
                [.ok]))
            return nil
        }

        guard let json = response.json else {
            // 解析响应
            let statusCode = (response.data?.count ?? 0) > 0 ? "请检查 client_id 配置。" : "网络异常"
            await PopupManager.shared.show(.init(.error, "登录请求失败",
                "Microsoft OAuth 返回空响应：\(statusCode)",
                [.ok]))
            return nil
        }

        // 检查 OAuth 错误码
        if let errorCode = json["error"].string, !errorCode.isEmpty {
            let errorDesc = json["error_description"].stringValue
            await PopupManager.shared.show(.init(.error, "登录被拒绝",
                "\\(errorCode): \(errorDesc)",
                [.ok]))
            return nil
        }

        let authResponse = DeviceAuthResponse(json)
        guard !authResponse.deviceCode.isEmpty else {
            await PopupManager.shared.show(.init(.error, "登录失败",
                "Microsoft OAuth 返回的 device_code 为空。请检查 client_id 是否有效。",
                [.ok]))
            return nil
        }

        // 复制 userCode 到剪贴板（失败不致命）
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(authResponse.userCode, forType: .string)

        // 打开浏览器（URL 无效时回退到微软登录主页）
        if let url = URL(string: authResponse.verificationUri) {
            NSWorkspace.shared.open(url)
        } else if let fallback = URL(string: "https://login.microsoftonline.com") {
            NSWorkspace.shared.open(fallback)
        }

        // 尝试发送通知，失败也不致命（macOS 上需 entitlement，但 try? 不会 fatalError）
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.setNotificationCategories([])
        let content = UNMutableNotificationContent()
        content.title = "登录"
        content.body = "请将剪切板中的内容粘贴到输入框中"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)

        await PopupManager.shared.show(.init(.normal, "登录 Minecraft", """
登录网页将自动开启，请在网页中输入 \(authResponse.userCode)（已自动复制）。

如果网络环境不佳，网页可能一直加载不出来，届时请使用使用加速器或 VPN 以改善网络环境。
你也可以用其他设备打开 \(authResponse.verificationUri) 并输入上述代码。
""", [.ok]))
        
        return authResponse
    }
    
    // MARK: 轮询获取 Access Token
    public static func getAccessToken(_ deviceAuthResponse: DeviceAuthResponse) async throws -> AuthToken? {
        // 防御性归一化：interval 至少 1 秒，expiresIn 至少 1 秒；总次数限定 1..3600
        let interval = max(1, deviceAuthResponse.interval)
        let total = min(3600, max(1, Int(Double(max(1, deviceAuthResponse.expiresIn)) / Double(interval))))
        for i in 1...total {
            debug("轮询第 \(i) / \(total) 次")
            do {
                let clientID = Secrets.getClientIDOrEmpty()
                let response = await Requests.post(
                    "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
                    body: [
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "client_id": clientID,
                        "device_code": deviceAuthResponse.deviceCode
                    ],
                    encodeMethod: .urlEncoded
                )
                // 防御：response.json 可能为 nil（网络失败）；data 可能为 nil
                guard let json = response.json else {
                    if let error = response.error {
                        err("轮询请求失败: \(error.localizedDescription)")
                    } else {
                        err("轮询请求失败: 无响应数据")
                    }
                    try? await Task.sleep(for: .seconds(interval))
                    continue
                }
                if let accessToken = json["access_token"].string,
                   let refreshToken = json["refresh_token"].string {
                    return .init(accessToken: accessToken, refreshToken: refreshToken)
                }
                // 检查错误码（authorization_pending 等）
                let errorCode = json["error"].stringValue
                if errorCode == "authorization_declined" || errorCode == "access_denied" {
                    err("用户拒绝授权")
                    return nil
                }
                if errorCode == "expired_token" {
                    err("设备码已过期")
                    return nil
                }
                // authorization_pending / 其他：继续轮询
            } catch {
                err("轮询异常: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(interval))
        }
        err("轮询已结束，但没有获取到 Access Token")
        return nil
    }
    
    // MARK: 刷新 Access Token
    public static func refreshAccessToken(_ refreshToken: String) async throws -> AuthToken? {
        let clientID = Secrets.getClientIDOrEmpty()
        let json = try await Requests.post(
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
            body: [
                "client_id": clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
                "scope": "XboxLive.signin offline_access"
            ],
            encodeMethod: .urlEncoded
        ).getJSONOrThrow()
        if let accessToken = json["access_token"].string,
           let refreshToken = json["refresh_token"].string {
            return .init(accessToken: accessToken, refreshToken: refreshToken)
        }
        return nil
    }

    // MARK: 刷新 Access Token（login.microsoftonline.com v2.0 端点）
    /// 使用 refresh_token 获取新的 access_token（Prism Launcher 公开 client）。
    public static func refreshAccessTokenLive(_ refreshToken: String) async throws -> AuthToken? {
        let body = [
            "client_id": MinecraftOfficialClient.publicClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": MinecraftOfficialClient.scope
        ]
        let response = await Requests.post(MinecraftOfficialClient.tokenURL, body: body, encodeMethod: .urlEncoded, category: .microsoftLogin)
        guard let json = response.json else {
            err("刷新令牌响应为空")
            return nil
        }
        if let errCode = json["error"].string, !errCode.isEmpty {
            err("刷新令牌失败: \(errCode): \(json["error_description"].stringValue)")
            return nil
        }
        guard let accessToken = json["access_token"].string,
              let newRefreshToken = json["refresh_token"].string else {
            err("刷新令牌: 缺少 access_token / refresh_token 字段")
            return nil
        }
        return .init(accessToken: accessToken, refreshToken: newRefreshToken)
    }

    // MARK: 获取 Minecraft Access Token
    public static func getMinecraftAccessToken(id: UUID? = nil, _ accessToken: String) async throws -> String? {
        if let id = id,
           let accessToken = AccessTokenStorage.shared.getTokenInfo(for: id)?.accessToken {
            return accessToken
        }
        
        let json = try await Requests.post(
            "https://user.auth.xboxlive.com/user/authenticate",
            body: [
                "Properties": [
                    "AuthMethod": "RPS",
                    "SiteName": "user.auth.xboxlive.com",
                    "RpsTicket": "d=\(accessToken)"
                ],
                "RelyingParty": "http://auth.xboxlive.com",
                "TokenType": "JWT"
            ],
            encodeMethod: .json
        ).getJSONOrThrow()
        if let token = json["Token"].string,
           let uhs = json["DisplayClaims"]["xui"].array?.first?["uhs"].string {
            let json = try await Requests.post(
                "https://xsts.auth.xboxlive.com/xsts/authorize",
                body: [
                    "Properties": [
                        "SandboxId": "RETAIL",
                        "UserTokens": [
                            token
                        ]
                    ],
                    "RelyingParty": "rp://api.minecraftservices.com/",
                    "TokenType": "JWT"
                ],
                encodeMethod: .json
            ).getJSONOrThrow()
            if let token = json["Token"].string {
                let json = try await Requests.post(
                    "https://api.minecraftservices.com/authentication/login_with_xbox",
                    body: [
                        "identityToken": "XBL3.0 x=\(uhs);\(token)"
                    ],
                    encodeMethod: .json
                ).getJSONOrThrow()
                if let accessToken = json["access_token"].string {
                    if let id = id {
                        AccessTokenStorage.shared.add(id: id, accessToken: accessToken, expiriesIn: json["expires_in"].intValue)
                    }
                    return accessToken
                } else {
                    err("无法获取 Minecraft 访问令牌")
                }
            } else {
                err("XSTS 身份验证失败")
            }
        } else {
            err("Xbox Live 身份验证失败")
        }
        return nil
    }
    
    // MARK: 检测是否拥有 Minecraft
    public static func hasMinecraftGame(_ authToken: AuthToken) async throws -> Bool {
        guard let accessToken = authToken.minecraftAccessToken else { return false }
        
        let json = try await Requests.get(
            "https://api.minecraftservices.com/entitlements/mcstore",
            headers: [
                "Authorization": "Bearer \(accessToken)"
            ],
            category: .minecraftAPI
        ).getJSONOrThrow()
        
        return json["items"].arrayValue.contains(where: { $0["name"].stringValue == "product_minecraft" })
    }
    
    /// 登录并获取 Access Token
    public static func signIn() async throws -> AuthToken? {
        log("正在获取设备码")
        guard let deviceCode = try await getDeviceCode() else {
            err("无法获取设备码")
            return nil
        }

        guard let authToken = try await getAccessToken(deviceCode) else { return nil }

        // 防御：getMinecraftAccessToken 内部可能 throw / 返回 nil
        do {
            authToken.minecraftAccessToken = try await getMinecraftAccessToken(authToken.accessToken)
        } catch {
            err("getMinecraftAccessToken 失败: \(error.localizedDescription)")
            return nil
        }
        return authToken
    }
}

// MARK: - OAuth Authorization Code Flow（模拟 Minecraft 官方启动器）

public enum OAuthCallbackError: Error, LocalizedError {
    case userCancelled
    case malformedURL(String)
    case missingCode
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "用户取消了登录"
        case .malformedURL(let s):
            return "回调 URL 格式异常：\(s)"
        case .missingCode:
            return "回调 URL 中未找到 code 参数"
        case .serverError(let s):
            return "服务器错误：\(s)"
        }
    }
}

/// OAuth 回调载荷（pclmac://oauth/callback?code=xxx&state=yyy）
public struct OAuthCallback: Sendable {
    public let code: String
    public let state: String?
}

/// 单次登录会话（用于在 AppDelegate 和 NewMicrosoftAccountView 之间共享）
@MainActor
public final class OAuthSession: ObservableObject {
    public static let shared = OAuthSession()

    /// 等待浏览器回调的 continuation。
    private var continuation: CheckedContinuation<OAuthCallback, Error>?

    /// 当前是否在等待回调。
    @Published public private(set) var isWaiting = false

    /// 启动器 URL scheme（与 Info.plist CFBundleURLSchemes 同步）。
    public static let callbackScheme = "pclmac"
    public static let callbackHost = "oauth"
    public static let callbackURLString = "\(callbackScheme)://\(callbackHost)/callback"

    /// 注册来自 AppDelegate 的回调 URL。
    public func handle(url: URL) {
        guard let cb = parseCallback(url: url) else {
            finish(.failure(OAuthCallbackError.malformedURL(url.absoluteString)))
            return
        }
        finish(.success(cb))
    }

    /// 等待回调（NewMicrosoftAccountView 调用）。
    public func waitForCallback() async throws -> OAuthCallback {
        if let c = continuation {
            c.resume(throwing: OAuthCallbackError.userCancelled)
            continuation = nil
        }
        isWaiting = true
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }

    /// 用户主动取消。
    public func cancel() {
        finish(.failure(OAuthCallbackError.userCancelled))
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        isWaiting = false
        switch result {
        case .success(let cb): cont.resume(returning: cb)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    /// 解析 pclmac://oauth/callback?code=...&state=...
    private func parseCallback(url: URL) -> OAuthCallback? {
        guard url.scheme == Self.callbackScheme,
              url.host == Self.callbackHost else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return nil
        }
        let state = items.first(where: { $0.name == "state" })?.value
        return OAuthCallback(code: code, state: state)
    }
}

public enum MinecraftOfficialClient {
    /// Prism Launcher 团队注册的公开 Azure App client_id（public client，无需 client_secret）。
    /// 已验证可用 scope `XboxLive.signin offline_access`。
    /// 参考：https://github.com/PrismLauncher/PrismLauncher/blob/develop/CMakeLists.txt
    public static let publicClientID = "c36a9fb6-4f2a-41ff-90bd-ae7cc92031eb"
    /// OAuth scope: XboxLive.signin（XBL 认证必需）+ offline_access（获取 refresh_token）。
    public static let scope = "XboxLive.signin offline_access"
    /// Device Code 端点（login.microsoftonline.com v2.0 consumers）。
    public static let deviceCodeURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")!
    /// Token 端点（轮询 + refresh）。
    public static let tokenURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
}

extension MsLogin {
    /// Minecraft 官方风格 OAuth Authorization Code 登录。
    /// 1. 打开浏览器到 login.live.com
    /// 2. 用户登录微软账号
    /// 3. 浏览器 redirect 回 pclmac://oauth/callback?code=xxx
    /// 4. macOS 唤起 PCL.Mac，AppDelegate.handle(url) 解析
    /// 5. 用 code 换 access_token → Xbox token → XSTS token → Minecraft token
    /// login.microsoftonline.com Device Code Flow 登录（Prism Launcher 公开 client_id，无需注册）。
    /// 1. POST devicecode 获取 device_code + user_code
    /// 2. 弹原生窗口显示验证码、自动复制到剪贴板、打开系统浏览器
    /// 3. 轮询 token 端点直到拿到 access_token
    /// 4. access_token → XBL → XSTS → Minecraft token
    public static func signInViaBrowser() async throws -> AuthToken? {
        log("开始 Device Code 登录（login.microsoftonline.com, client_id=\(MinecraftOfficialClient.publicClientID)）")

        // 1. 获取设备码
        let deviceResponse = try await requestDeviceCode()
        let userCode = deviceResponse.userCode
        let deviceCode = deviceResponse.deviceCode
        let interval = max(1, deviceResponse.interval)
        let expiresIn = max(1, deviceResponse.expiresIn)
        let verificationURI = deviceResponse.verificationUri

        log("设备码获取成功: user_code=\(userCode), 验证页=\(verificationURI), 过期=\(expiresIn)s")

        // 2. 复制验证码到剪贴板
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(userCode, forType: .string)

        // 3. 打开系统浏览器（系统浏览器支持通行密钥）
        if let url = URL(string: verificationURI) {
            NSWorkspace.shared.open(url)
        }

        // 4. 弹原生提示
        await PopupManager.shared.show(.init(.normal, "登录 Minecraft", """
登录网页已自动开启，请在网页中输入 \(userCode)（已自动复制）。

如果网页一直加载不出来，请使用加速器或 VPN 改善网络环境。
你也可以用其他设备打开 \(verificationURI) 并输入上述代码。
""", [.ok]))

        // 5. 轮询获取 access_token（最多 15 分钟）
        let totalPolls = min(900, expiresIn / interval)
        var liveAccessToken: String?
        var refreshToken: String?

        for i in 1...totalPolls {
            try? await Task.sleep(for: .seconds(interval))
            do {
                let pollResult = try await pollDeviceToken(deviceCode: deviceCode)
                if let token = pollResult {
                    liveAccessToken = token.accessToken
                    refreshToken = token.refreshToken
                    log("第 \(i) 次轮询成功，获取到 access_token")
                    break
                }
            } catch {
                throw error
            }
        }

        guard let accessToken = liveAccessToken else {
            err("Device Code 轮询超时，未获取到 access_token")
            throw OAuthCallbackError.serverError("设备码登录超时")
        }
        guard let rToken = refreshToken else {
            err("Device Code 响应中缺少 refresh_token")
            throw OAuthCallbackError.serverError("设备码响应缺少 refresh_token")
        }
        log("成功获取 microsoftonline.com access_token, 长度=\(accessToken.count)")

        // 6. access_token → XBL
        let xblToken = try await getXBLToken(accessToken: accessToken)
        log("成功获取 XBL token, userHash=\(xblToken.userHash)")

        // 7. XBL → XSTS
        let xsts = try await getXSTSToken(xblToken: xblToken.token, userHash: xblToken.userHash)
        log("成功获取 XSTS token")

        // 8. XSTS → Minecraft
        let mcAccess = try await getMinecraftTokenFromXbox(xstsToken: xsts.token, userHash: xblToken.userHash)
        log("成功获取 Minecraft access_token")

        // 9. 构造 AuthToken
        let auth = AuthToken(accessToken: accessToken, refreshToken: rToken)
        auth.minecraftAccessToken = mcAccess
        return auth
    }

    /// 设备码响应结构。
    private struct DeviceCodeResponse {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int
    }

    /// POST devicecode → 获取设备码。
    private static func requestDeviceCode() async throws -> DeviceCodeResponse {
        let body = [
            "client_id": MinecraftOfficialClient.publicClientID,
            "scope": MinecraftOfficialClient.scope
        ]
        let response = await Requests.post(MinecraftOfficialClient.deviceCodeURL, body: body, encodeMethod: .urlEncoded, category: .microsoftLogin)
        guard let json = response.json else {
            let raw = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            err("获取设备码失败: HTTP \(response.statusCode), raw=\(raw)")
            throw OAuthCallbackError.serverError("获取设备码失败: \(raw)")
        }
        guard let dc = json["device_code"].string,
              let uc = json["user_code"].string,
              let vu = json["verification_uri"].string else {
            err("设备码响应字段缺失: \(json)")
            throw OAuthCallbackError.serverError("设备码响应字段缺失: \(json)")
        }
        return DeviceCodeResponse(
            deviceCode: dc,
            userCode: uc,
            verificationUri: vu,
            expiresIn: json["expires_in"].intValue,
            interval: json["interval"].intValue
        )
    }

    /// 轮询 token 端点（authorization_pending 返回 nil）。
    private static func pollDeviceToken(deviceCode: String) async throws -> (accessToken: String, refreshToken: String)? {
        let body = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": MinecraftOfficialClient.publicClientID,
            "device_code": deviceCode
        ]
        let response = await Requests.post(MinecraftOfficialClient.tokenURL, body: body, encodeMethod: .urlEncoded, category: .microsoftLogin)
        guard let json = response.json else { return nil }

        if let accessToken = json["access_token"].string,
           let refreshToken = json["refresh_token"].string {
            return (accessToken, refreshToken)
        }

        let errorCode = json["error"].stringValue
        if errorCode == "authorization_declined" || errorCode == "access_denied" {
            err("用户拒绝授权")
            throw OAuthCallbackError.userCancelled
        }
        if errorCode == "expired_token" {
            err("设备码已过期")
            throw OAuthCallbackError.serverError("设备码已过期")
        }
        if errorCode == "slow_down" {
            // 服务器要求减慢轮询，外层 caller 处理 interval
            return nil
        }
        // authorization_pending → 返回 nil 继续轮询
        return nil
    }

/// 内部数据结构：XBL / XSTS 响应里 token + userHash 绑定。
    private struct XBLToken {
        let token: String
        let userHash: String
    }

/// POST user.auth.xboxlive.com/user/authenticate → XBL token + userHash
    private static func getXBLToken(accessToken: String) async throws -> XBLToken {
        let rpsTicket = "d=\(accessToken)"
        let body: [String: Any] = [
            "Properties": ["AuthMethod": "RPS",
                           "SiteName": "user.auth.xboxlive.com",
                           "RpsTicket": rpsTicket],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        ]
        // 打印实际发送的 JSON body（token 截断）
        let debugBody: [String: Any] = [
            "Properties": ["AuthMethod": "RPS",
                           "SiteName": "user.auth.xboxlive.com",
                           "RpsTicket": "d=\(String(accessToken.prefix(30)))...(\(accessToken.count) chars)"],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        ]
        if let debugData = try? JSONSerialization.data(withJSONObject: debugBody, options: [.prettyPrinted, .withoutEscapingSlashes]),
           let debugStr = String(data: debugData, encoding: .utf8) {
            log("XBL 请求 body: \(debugStr)")
        }
        let response = await Requests.post(
            URL(string: "https://user.auth.xboxlive.com/user/authenticate")!,
            headers: [
                "Accept": "application/json",
                "User-Agent": "PCL.Mac/1.0"
            ],
            body: body,
            encodeMethod: .json,
            ignoredFailureStatusCodes: [401, 403, 400, 429, 500],
            category: .minecraftAPI
        )
        log("XBL 请求发送, HTTP状态码=\(response.statusCode)")
        guard let json = response.json else {
            let rawBody = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "(无法解码)"
            err("XBL 认证失败: HTTP \(response.statusCode), 响应为空, raw body=\(rawBody), token前20字符=\(String(accessToken.prefix(20)))")
            throw OAuthCallbackError.serverError("XBL HTTP \(response.statusCode): \(rawBody)")
        }
        // XBL 可能返回 XErr（如 2148916233 表示账号无 Xbox profile）
        if let xerr = json["XErr"].int, xerr != 0 {
            let message = json["Message"].stringValue
            err("XBL 认证返回 XErr=\(xerr): \(message)")
            throw OAuthCallbackError.serverError("XBL XErr=\(xerr): \(message)")
        }
        guard let token = json["Token"].string else {
            err("XBL Token 字段缺失: \(json)")
            throw OAuthCallbackError.serverError("XBL Token 字段缺失：\(json)")
        }
        guard let uhs = json["DisplayClaims"]["xui"].array?.first?["uhs"].string else {
            throw OAuthCallbackError.serverError("XBL userHash 缺失")
        }
        return XBLToken(token: token, userHash: uhs)
    }

    /// POST xsts.auth.xboxlive.com/xsts/authorize → XSTS token
    private static func getXSTSToken(xblToken: String, userHash: String) async throws -> XBLToken {
        let body: [String: Any] = [
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [xblToken]
            ],
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT"
        ]
        let response = await Requests.post(
            URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!,
            body: body,
            encodeMethod: .json,
            category: .minecraftAPI
        )
        guard let json = response.json else {
            throw OAuthCallbackError.serverError("XSTS 响应为空")
        }
        if let err = json["XErr"].int, err != 0 {
            throw OAuthCallbackError.serverError("XSTS 错误 XErr=\(err)：\(json["Message"].stringValue)")
        }
        guard let token = json["Token"].string else {
            throw OAuthCallbackError.serverError("XSTS Token 缺失")
        }
        return XBLToken(token: token, userHash: userHash)
    }

    /// POST api.minecraftservices.com/authentication/login_with_xbox → Minecraft access_token
    private static func getMinecraftTokenFromXbox(xstsToken: String, userHash: String) async throws -> String {
        let body: [String: Any] = [
            "identityToken": "XBL3.0 x=\(userHash);\(xstsToken)"
        ]
        let response = await Requests.post(
            URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!,
            body: body,
            encodeMethod: .json
        )
        guard let json = response.json else {
            throw OAuthCallbackError.serverError("Minecraft 登录响应为空")
        }
        guard let accessToken = json["access_token"].string else {
            throw OAuthCallbackError.serverError("Minecraft access_token 缺失：\(json)")
        }
        return accessToken
    }
}
