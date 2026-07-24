//
//  AnnouncementManager.swift
//  PCL.Mac
//
//  公告源支持关闭、使用内置源或用户自定义根地址。
//  根地址需包含 latest.json；历史公告沿用 history/{number}.json 结构。
//

import Foundation
import SwiftyJSON

@MainActor
public final class AnnouncementManager: ObservableObject {
    private static let builtInRoot = URL(string: "https://gitee.com/yizhimcqiu/pcl-mac-announcements/raw/main/announcements")!
    public static let shared = AnnouncementManager()

    @Published var latest: Announcement?
    @Published var history: [Announcement] = []
    @Published var isLoading = false
    @Published var lastError: String?

    public var activeSourceDescription: String {
        guard AppSettings.shared.showAnnouncements else { return "已关闭" }
        if AppSettings.shared.useCustomAnnouncementSource {
            return normalizedCustomRoot()?.absoluteString ?? "自定义地址无效"
        }
        return "内置公告源"
    }

    public func reload() {
        latest = nil
        history.removeAll()
        lastError = nil
        guard AppSettings.shared.showAnnouncements else { return }
        guard let root = activeRoot() else {
            lastError = "自定义公告源地址无效"
            return
        }

        isLoading = true
        Task {
            defer { isLoading = false }
            guard let index = await Requests.get(root.appending(path: "latest.json"), category: .announcement).json else {
                lastError = "无法读取公告索引"
                return
            }
            let path = index["path"].stringValue
            guard !path.isEmpty,
                  let json = await Requests.get(root.appending(path: path), category: .announcement).json else {
                lastError = "无法读取最新公告"
                return
            }
            latest = Announcement(json)
        }
    }

    public func loadHistory() {
        history.removeAll()
        guard AppSettings.shared.showAnnouncements, let root = activeRoot() else { return }
        Task {
            guard let json = await Requests.get(root.appending(path: "latest.json"), category: .announcement).json else { return }
            let latestNumber = json["number"].intValue
            for i in stride(from: latestNumber, through: max(latestNumber - 9, 0), by: -1) {
                if let item = await Requests.get(root.appending(path: "history").appending(path: "\(i).json"), category: .announcement).json {
                    history.append(Announcement(item))
                }
            }
        }
    }

    private func activeRoot() -> URL? {
        if AppSettings.shared.useCustomAnnouncementSource {
            return normalizedCustomRoot()
        }
        return Self.builtInRoot
    }

    private func normalizedCustomRoot() -> URL? {
        let value = AppSettings.shared.customAnnouncementSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    private init() {
        reload()
    }
}
