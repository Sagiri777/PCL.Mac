import SwiftUI

/// 菜单命令直接观察路由，确保“返回”的启用状态与当前页面实时同步。
struct AppCommands: Commands {
    @ObservedObject private var router = DataManager.shared.router

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 PCL.Mac") {
                router.setRoot(.others)
                router.append(.about)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("设置") {
                router.setRoot(.settings)
                router.append(.personalization)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) { }

        CommandMenu("导航") {
            Button("返回") { router.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!router.canGoBack)
            Divider()
            navigationButton("启动", route: .launch, key: "1")
            navigationButton("下载", route: .download, key: "2")
            navigationButton("联机", route: .multiplayer, key: "3")
            navigationButton("设置", route: .settings, key: "4")
            navigationButton("更多", route: .others, key: "5")
        }
    }

    private func navigationButton(
        _ title: String,
        route: AppRoute,
        key: KeyEquivalent
    ) -> some View {
        Button(title) {
            guard router.getRoot() != route else { return }
            router.setRoot(route)
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
