//
//  UpdateCheck.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/13.
//

import Foundation
import AppKit

public struct Update {
    public let version: String
    public let time: Date
    public let url: URL
}

/// 只检查公开 Release，不在运行中的应用内下载或覆盖可执行文件。
/// 更新包的签名、公证与来源验证由浏览器和 macOS 安装流程处理。
public enum UpdateCheck {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Sagiri777/PCL.Mac/releases/latest")!

    public static func getLastUpdate() async -> Update? {
        let response = await Requests.get(
            latestReleaseURL,
            headers: ["Accept": "application/vnd.github+json"],
            category: .other
        )
        guard response.statusCode == 200, let json = response.json else {
            if response.statusCode != 404 {
                err("GitHub Release 检查失败（HTTP \(response.statusCode)）")
            }
            return nil
        }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: json["published_at"].stringValue),
              let url = json["html_url"].url,
              url.scheme == "https",
              url.host?.lowercased() == "github.com" else {
            err("GitHub Release 响应缺少有效版本、时间或 HTTPS 页面")
            return nil
        }
        let version = json["tag_name"].stringValue
        guard !version.isEmpty else { return nil }
        return Update(version: version, time: date, url: url)
    }

    @MainActor
    public static func openReleasePage(_ update: Update) {
        NSWorkspace.shared.open(update.url)
    }
}
