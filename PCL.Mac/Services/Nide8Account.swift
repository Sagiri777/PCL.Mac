//
//  Nide8Account.swift
//  PCL.Mac
//
//  Created by PCL.Mac on 2026-07-22.
//  对应上游 PageLoginNide.xaml(.vb) + PageLoginNideSkin.xaml(.vb)。
//
//  Nide8 实际上是 authlib-injector 兼容的 Yggdrasil 服务。
//  本实现复用 YggdrasilAccount 机制，仅提供预设 URL 入口。
//

import Foundation

public enum Nide8AccountHelper {
    /// Nide8 默认 authlib-injector 服务器 URL。
    public static let defaultURL = URL(string: "https://auth.mc-user.com:233/")!

    /// 用 Nide8 登录（底层走 YggdrasilAccount）。
    public static func login(email: String, password: String) async throws -> YggdrasilAccount {
        try await YggdrasilAccount(
            authenticationServer: defaultURL,
            accountIdentifier: email,
            password: password
        )
    }

    /// 检测 Nide8 服务可用性。
    public static func checkAvailability() async -> Bool {
        do {
            let json = try await Requests.get(defaultURL).getJSONOrThrow()
            return json["meta"]["serverName"].string != nil
        } catch {
            log("Nide8 服务不可达：\(error.localizedDescription)")
            return false
        }
    }
}
