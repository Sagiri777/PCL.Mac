//
//  AppRoute.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/29.
//

import SwiftUI

public enum AppRoute: Hashable {
    // 根页面
    case launch
    case download
    case multiplayer
    case settings
    case others
    
    // 子页面
    case accountManagement
    case accountList
    case newAccount
    case installing(tasks: InstallTasks)
    case versionSelect
    case projectDownload(summary: ProjectSummary)
    case announcementHistory
    case versionSettings(instance: MinecraftInstance)
    
    // MyList 导航
    case minecraftDownload
    case projectSearch(type: ProjectType)
    case versionList(directory: MinecraftDirectory)
    case instanceOverview
    case instanceSettings
    case instanceMods
    case javaDownload
    
    case about
    case toolbox
    case debug
    
    case personalization
    case javaSettings
    case otherSettings
    
    /// 是否应显示统一返回按钮。只要路由栈中还有上一层就显示，避免依赖各页面自行实现。
    var showsBackButton: Bool {
        DataManager.shared.router.path.count > 1
    }

    var isRoot: Bool {
        switch self {
        case .launch, .download, .multiplayer, .settings, .others,
                .minecraftDownload, .projectSearch(_),
                .about, .toolbox, .debug,
                .personalization, .javaSettings, .otherSettings:
            return true
        default:
            return false
        }
    }
    
    var name: String {
        switch self {
        case .installing(let task): "installing?task=\(task.id)"
        case .projectDownload(let summary): "projectDownload?summary=\(summary.modId)"
        case .versionList(let directory): "versionList?rootURL=\(directory.rootURL.path)"
        case .versionSettings(let instance): "versionSettings?instance=\(instance.name)"
        case .projectSearch(let type): "projectSearch?type=\(type)"
        default:
            String(describing: self)
        }
    }
    
    var title: String {
        switch self {
        case .installing(_): "下载管理"
        case .versionSelect, .versionList: "版本选择"
        case .projectDownload(let summary): "资源下载 - \(summary.name)"
        case .accountManagement, .accountList, .newAccount: "账号管理"
        case .announcementHistory: "历史公告"
        case .versionSettings, .instanceOverview, .instanceSettings, .instanceMods: "版本设置 - \(AppSettings.shared.defaultInstance ?? "")"
        case .javaDownload: "Java 下载"
        default: SharedConstants.shared.editionName
        }
    }
    
    func isSame(_ another: AppRoute) -> Bool {
        if case .versionList(let directory1) = self,
           case .versionList(let directory2) = another {
            return directory1.rootURL == directory2.rootURL
        }
        
        return self == another
    }
}

public class AppRouter: ObservableObject {
    @Published public var path: [AppRoute] = [.launch]

    public var canGoBack: Bool {
        path.count > 1
    }
    
    public func append(_ route: AppRoute) {
        path.append(route)
    }
    
    public func getLastView() -> any View {
        switch getLast() {
        case .launch:
            LaunchView()
        case .accountManagement, .accountList, .newAccount:
            AccountManagementView()
        case .download, .minecraftDownload, .projectSearch(_):
            DownloadView()
        case .multiplayer:
            MultiplayerView()
        case .settings, .personalization, .javaSettings, .otherSettings:
            SettingsView()
        case .others, .about, .toolbox, .debug:
            OthersView()
        case .installing(let tasks):
            InstallingView(tasks: tasks)
        case .versionSelect, .versionList(_):
            VersionSelectView()
        case .projectDownload(let summary):
            ProjectDownloadView(id: summary.modId)
        case .announcementHistory:
            AnnouncementHistoryView()
        case .versionSettings, .instanceOverview, .instanceSettings, .instanceMods:
            VersionSettingsView()
        case .javaDownload:
            JavaInstallView()
        }
    }

    /// 当前页面所属的“容器”标识。
    ///
    /// 很多路由共享同一个容器 view（例如 `.settings` / `.personalization` /
    /// `.javaSettings` 都是 `SettingsView`，内部再按子路由切换）。ContentView 用它
    /// 作为 `.id()`：只有真正换了容器时才重建视图树，容器内的子路由切换走正常 diff。
    public func getLastViewIdentity() -> String {
        switch getLast() {
        case .launch: "launch"
        case .accountManagement, .accountList, .newAccount: "account"
        case .download, .minecraftDownload, .projectSearch: "download"
        case .multiplayer: "multiplayer"
        case .settings, .personalization, .javaSettings, .otherSettings: "settings"
        case .others, .about, .toolbox, .debug: "others"
        case .installing(let tasks): "installing-\(tasks.id)"
        case .versionSelect, .versionList: "versionSelect"
        case .projectDownload(let summary): "projectDownload-\(summary.modId)"
        case .announcementHistory: "announcementHistory"
        case .versionSettings, .instanceOverview, .instanceSettings, .instanceMods: "versionSettings"
        case .javaDownload: "javaDownload"
        }
    }
    
    public func getDebugText() -> String {
        return "/" + path.map { $0.name }.joined(separator: "/")
    }
    
    public func removeLast() {
        self.path.removeLast()
        if self.path.isEmpty {
            self.path.append(.launch)
        }
    }

    /// 统一菜单、旧标题栏与 Liquid Glass 工具栏的返回语义。
    ///
    /// 账号、版本选择和版本设置都是“容器路由 + 容器内子路由”两层结构；
    /// 离开它们时需要先退出子路由，再退出容器。普通页面只退一层。
    public func goBack() {
        guard canGoBack else { return }
        let leavesContainer = (getLastView() as? SubRouteContainer)?.shouldPop() == true
        let removalCount = min(leavesContainer ? 2 : 1, path.count - 1)
        path = Array(path.dropLast(removalCount))
    }
    
    public func setRoot(_ root: AppRoute) {
        path.removeAll()
        path.append(root)
    }
    
    public func getLast() -> AppRoute {
        return path.last!
    }
    
    public func getRoot() -> AppRoute {
        return path.first!
    }
}

/// 若该视图为子页面，且有子路由，需要实现此协议以便正常返回。
protocol SubRouteContainer {
    func shouldPop() -> Bool
}

extension SubRouteContainer {
    func shouldPop() -> Bool { true }
}
