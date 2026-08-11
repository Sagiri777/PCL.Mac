//
//  Secrets.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/13.
//
//  CLIENT_ID 获取优先级（Secrets.getClientID）：
//    1. 进程环境变量 CLIENT_ID
//    2. ~/Library/Application Support/PCL.Mac/client_id.txt 第一行
//    3. Info.plist 的 CLIENT_ID（打包脚本或 CI 注入）
//    4. Secrets.CLIENT_ID 编译时常量（CI 注入）
//
//  如果以上都没有，会在首次正版登录时报错并提示用户如何注册：
//    https://learn.microsoft.com/azure/active-directory/develop/quickstart-register-app
//

import Foundation

public let CLIENT_ID: String = "{{CLIENT_ID}}"

public enum SecretsError: LocalizedError {
    case clientIDMissing

    public var errorDescription: String? {
        switch self {
        case .clientIDMissing:
            return """
            缺少 Microsoft OAuth client_id。

            请通过以下任一方式提供：
            1. 启动前设置环境变量：
                 export CLIENT_ID=你的Azure应用客户端ID
                 /path/to/PCL.Mac.app/Contents/MacOS/PCL.Mac

            2. 创建文件 ~/Library/Application Support/PCL.Mac/client_id.txt
                 第一行写入你的Azure应用客户端ID

            Azure App 注册步骤：
            • 访问 https://portal.azure.com → Microsoft Entra ID → 应用注册 → 新注册
            • 受支持的账户类型：任何组织目录(任何 Microsoft Entra ID 租户 - 多租户)中的帐户 + 个人 Microsoft 帐户
            • 重定向 URI：留空
            • 复制"应用程序(客户端) ID"使用

            """
        }
    }
}

public class Secrets {
    public static func getClientID() throws -> String {
        // 1. 环境变量
        if let env = ProcessInfo.processInfo.environment["CLIENT_ID"], !env.isEmpty {
            return env
        }

        // 2. 本地配置文件
        let appSupport = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PCL.Mac")
        let configFile = appSupport.appendingPathComponent("client_id.txt")
        if let text = try? String(contentsOf: configFile, encoding: .utf8) {
            let firstLine = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !firstLine.isEmpty {
                return firstLine
            }
        }

        // 3. Info.plist（打包脚本或 CI 注入）
        if let infoValue = Bundle.main.object(forInfoDictionaryKey: "CLIENT_ID") as? String,
           !infoValue.isEmpty,
           !infoValue.starts(with: "{{") {
            return infoValue
        }

        // 4. 编译时常量（非占位符时）
        if !CLIENT_ID.isEmpty && !CLIENT_ID.starts(with: "{{") {
            return CLIENT_ID
        }

        throw SecretsError.clientIDMissing
    }

    /// 兼容旧 API：getClientID() -> String，当失败时返回 ""。
    /// 推荐用 throws 版本。
    public static func getClientIDOrEmpty() -> String {
        do {
            return try getClientID()
        } catch {
            return ""
        }
    }
}
