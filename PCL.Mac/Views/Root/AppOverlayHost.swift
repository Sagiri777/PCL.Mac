import SwiftUI

/// 将高频、短生命周期的浮层状态与主导航视图隔离。
struct AppOverlayHost: View {
    var body: some View {
        ZStack {
            CustomOverlayLayer()
            DebugRouteOverlay()
            InstallTaskButtonOverlay()
            ProjectQueueOverlay()
            HintLayer()
            PopupLayer()
        }
    }
}

private struct CustomOverlayLayer: View {
    @ObservedObject private var overlayManager = OverlayManager.shared

    var body: some View {
        ForEach(overlayManager.overlays) { overlay in
            overlay.view
                .offset(x: overlay.position.x, y: overlay.position.y)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DebugRouteOverlay: View {
    @ObservedObject private var router = DataManager.shared.router
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if SharedConstants.shared.isDevelopment && settings.showCurrentRoute {
            Text(router.getDebugText())
                .font(.custom("PCL English", size: 14))
                .foregroundStyle(Color("TextColor"))
                .animation(.easeInOut(duration: 0.2), value: router.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(y: 48)
                .allowsHitTesting(false)
        }
    }
}

private struct InstallTaskButtonOverlay: View {
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        Group {
            if dataManager.inprogressInstallTasks != nil,
               case .installing = dataManager.router.getLast() {
                EmptyView()
            } else if let tasks = dataManager.inprogressInstallTasks {
                RoundedButton {
                    Image("DownloadIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20)
                        .foregroundStyle(.white)
                } onClick: {
                    dataManager.router.append(.installing(tasks: tasks))
                }
                .padding()
                .help("查看下载任务")
                .accessibilityLabel("查看下载任务")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

private struct HintLayer: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                HintOverlay()
                Spacer()
            }
            .padding(.bottom, 50)
        }
        .allowsHitTesting(false)
    }
}

private struct PopupLayer: View {
    @ObservedObject private var popupManager = PopupManager.shared

    var body: some View {
        if let popup = popupManager.currentPopup {
            Rectangle().fill(popup.type.getMaskColor())
            PopupOverlay(popup).padding()
        }
    }
}

struct GlobalDropOverlay: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            settings.effectiveAccentColor.opacity(0.16)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 54, weight: .medium))
                Text("松开以导入")
                    .font(.custom("PCL English", size: 20))
                Text("支持整合包、Mod 与资源压缩包")
                    .font(.custom("PCL English", size: 12))
                    .opacity(0.72)
            }
            .foregroundStyle(settings.effectiveThemeStyle)
            .padding(36)
        }
        .background(.ultraThinMaterial.opacity(0.55))
        .allowsHitTesting(false)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.985).combined(with: .opacity))
        .zIndex(20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("松开以导入整合包、Mod 或资源压缩包")
    }
}

/// Sheet 的观察范围也独立出来，登录进度变化不会重算导航树。
struct AppPresentationModifier: ViewModifier {
    @ObservedObject private var browserLogin = BrowserLoginController.shared
    @ObservedObject private var modpackImportManager = ModpackImportManager.shared
    @ObservedObject private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .tint(settings.effectiveAccentColor)
            .sheet(isPresented: $browserLogin.isPresented) {
                BrowserLoginView()
            }
            .sheet(isPresented: $modpackImportManager.isPresented) {
                ModpackImportView(manager: modpackImportManager)
            }
    }
}
