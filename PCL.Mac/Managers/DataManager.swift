//
//  DataManager.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/19.
//

import SwiftUI
import Combine

/// 需要在界面上同步 / 使用的都放在这里
class DataManager: ObservableObject {
    static let shared = DataManager()
    
    @Published var javaVirtualMachines: [JavaVirtualMachine] = []
    @Published var lastTimeUsed: Int = 0
    @Published var versionManifest: VersionManifest?
    @Published var router: AppRouter = .init()
    @Published var leftTabWidth: CGFloat = 310
    @Published var leftTabContent: AnyView = AnyView(EmptyView())
    @Published var leftTabId: UUID = .init()
    @Published var inprogressInstallTasks: InstallTasks?
    
    var defaultInstance: MinecraftInstance? {
        if let directory = AppSettings.shared.currentMinecraftDirectory,
           let defaultInstance = AppSettings.shared.defaultInstance,
           let instance = MinecraftInstance.create(directory, defaultInstance) {
            return instance
        }
        return nil
    }
    
    private var routerCancellable: AnyCancellable?
    
    private init() {
        routerCancellable = router.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    
    /// 加载版本清单：先用本地缓存让界面立刻可用，再在后台刷新。
    ///
    /// 这里不再在主线程上做同步网络可达性探测（那会让启动白屏最多 2 秒）。
    /// 直接发起请求，失败时才判断有没有缓存可用。
    func refreshVersionManifest() {
        versionManifest = AppSettings.shared.lastVersionManifest
        Task {
            if let versionManifest = await VersionManifest.getVersionManifest() {
                await MainActor.run {
                    self.versionManifest = versionManifest
                    AppSettings.shared.lastVersionManifest = versionManifest
                    log("版本清单获取成功")
                }
                return
            }

            await MainActor.run {
                if self.versionManifest != nil {
                    warn("无法获取版本清单，使用最后一次获取到的版本清单")
                } else {
                    err("无法获取版本清单，且本地无缓存")
                    self.handleMissingVersionManifest()
                }
            }
        }
    }

    /// 清单既拉不到又没有缓存时，给用户一次重试机会而不是直接杀进程。
    @MainActor
    private func handleMissingVersionManifest() {
        Task {
            let button = await PopupManager.shared.showAsync(
                .init(
                    .error,
                    "无法获取版本列表",
                    "PCL.Mac 需要 Minecraft 版本清单才能工作，但当前既无法联网获取，本地也没有缓存。\n请检查网络连接（或代理设置）后重试。",
                    [.init(label: "重试", style: .accent), .init(label: "退出", style: .normal)]
                )
            )
            if button == 0 {
                self.refreshVersionManifest()
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    func leftTab(_ width: CGFloat, _ content: @escaping () -> some View) {
        DispatchQueue.main.async {
            self.leftTabWidth = width
            self.leftTabContent = AnyView(content())
            self.leftTabId = .init()
        }
    }
}
