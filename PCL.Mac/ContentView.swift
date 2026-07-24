//
//  ContentView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/17.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    @ObservedObject private var overlayManager: OverlayManager = .shared
    @ObservedObject private var popupManager: PopupManager = .shared
    @ObservedObject private var browserLogin: BrowserLoginController = .shared
    @ObservedObject private var settings: AppSettings = .shared

    @State private var isLeftTabVisible = true

    var installTaskButtonOverlay: some View {
        Group {
            if let tasks = dataManager.inprogressInstallTasks,
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    var hintOverlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                HintOverlay()
                Spacer()
            }
            .padding(.bottom, 50)
        }
    }

    var popupOverlay: some View {
        Group {
            if let currentPopup = popupManager.currentPopup {
                Rectangle().fill(currentPopup.type.getMaskColor())
                PopupOverlay(currentPopup).padding()
            }
        }
    }

    var routerOverlay: some View {
        Text(dataManager.router.getDebugText())
            .font(.custom("PCL English", size: 14))
            .foregroundStyle(Color("TextColor"))
            .animation(.easeInOut(duration: 0.2), value: dataManager.router.path)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(y: 48)
    }

    var body: some View {
        ZStack {
            createViewFromRouter()
            ForEach(overlayManager.overlays) { overlay in
                overlay.view
                    .offset(CGSize(width: overlay.position.x, height: overlay.position.y))
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if SharedConstants.shared.isDevelopment && settings.showCurrentRoute { routerOverlay }
            installTaskButtonOverlay
            ProjectQueueOverlay()
            hintOverlay
            popupOverlay
        }
        .background(Color.clear)
        .tint(settings.effectiveAccentColor)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $browserLogin.isPresented) {
            BrowserLoginView()
        }
        .onAppear {
            if !AppStartTracker.shared.finished {
                AppStartTracker.shared.finished = true
                let cost = Int(Double(Date().timeIntervalSince1970 - AppStartTracker.shared.launchTime) * 1000)
                log("主界面加载完成, App 启动总耗时 \(cost)ms")
            }
        }
    }

    @ViewBuilder
    private func createViewFromRouter() -> some View {
        if settings.glassEnabled {
            nativeMacOS26Layout
        } else {
            legacyLayout
        }
    }

    /// MacOS26 不再沿用 PCL 顶部彩色导航条，而是使用标准 macOS 侧栏、交通灯和浮动内容面板。
    private var nativeMacOS26Layout: some View {
        ZStack {
            NativeFrostedWindowFrame()
            nativeMacOS26Interior
                .padding(settings.glassFrameWidth)
            if settings.windowControlButtonStyle == .pcl {
                HStack(spacing: 4) {
                    Spacer()
                    WindowControlButton.Miniaturize
                    WindowControlButton.Close
                }
                .padding(.top, max(5, settings.glassFrameWidth * 0.35))
                .padding(.trailing, max(7, settings.glassFrameWidth * 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .background(Color.clear)
        .frame(minWidth: 780, minHeight: 500)
    }

    private var nativeMacOS26Interior: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                NativeMacSidebar()
                    .padding(.top, 44)
                Divider().opacity(0.20 + settings.glassHighlightStrength * 0.20)
                dataManager.leftTabContent
                    .scaleEffect(isLeftTabVisible ? 1 : 0.98)
                    .opacity(isLeftTabVisible ? 1 : 0)
                    .onChange(of: dataManager.leftTabId) { animateLeftTab() }
            }
            .frame(width: max(220, min(310, dataManager.leftTabWidth + 90)))
            .background(nativeSidebarMaterial)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(.white.opacity(0.05 + settings.glassHighlightStrength * 0.20))
                    .frame(width: 0.5)
            }

            VStack(spacing: 0) {
                NativeMacToolbar()
                AnyView(dataManager.router.getLastView())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(nativeContentSurface)
                    .clipShape(RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous))
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    private var legacyLayout: some View {
        VStack(spacing: 0) {
            Group {
                if dataManager.router.path.count <= 1 { TitleBarView() }
                else { SubviewTitleBarView() }
            }
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.clear)
                    .background(legacySidebarBackground)
                    .shadow(radius: 2)
                    .frame(width: dataManager.leftTabWidth)
                    .overlay(
                        dataManager.leftTabContent
                            .scaleEffect(isLeftTabVisible ? 1 : 0.96)
                            .opacity(isLeftTabVisible ? 1 : 0)
                            .onChange(of: dataManager.leftTabId) { animateLeftTab() }
                    )
                    .zIndex(1)
                AnyView(dataManager.router.getLastView())
                    .foregroundStyle(Color("TextColor"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Rectangle().fill(settings.theme.getBackgroundStyle()))
        }
        .frame(minWidth: 700, minHeight: 420)
    }

    private func animateLeftTab() {
        isLeftTabVisible = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isLeftTabVisible = true
        }
    }

    private var legacySidebarBackground: some View {
        Rectangle()
            .fill(settings.useUltraThinMaterial
                  ? AnyShapeStyle(.ultraThickMaterial)
                  : AnyShapeStyle(Color("BackgroundColor")))
    }

    private var nativeSidebarMaterial: some View {
        Rectangle()
            .fill(nativeMaterial(for: settings.glassPanelBlurStrength))
            .opacity((0.12 + settings.glassPanelBlurStrength * 0.72) * settings.glassSurfaceOpacity)
            .overlay(settings.effectiveAccentColor.opacity(settings.glassTintStrength * 0.055))
    }

    private var nativeContentSurface: some View {
        RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
            .fill(nativeMaterial(for: settings.glassBackgroundBlurStrength))
            .opacity((0.10 + settings.glassBackgroundBlurStrength * 0.62) * settings.glassSurfaceOpacity)
            .overlay(settings.effectiveAccentColor.opacity(settings.glassTintStrength * 0.04))
            .overlay {
                RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.04 + settings.glassHighlightStrength * 0.22), lineWidth: 0.7)
            }
            .shadow(
                color: .black.opacity(settings.glassShadowStrength * 0.16),
                radius: 3 + settings.glassShadowStrength * 8,
                y: 2
            )
    }

    private var contentCornerRadius: Double {
        settings.glassContentCornerRadius
    }

    private func nativeMaterial(for strength: Double) -> Material {
        if strength < 0.25 { return .ultraThinMaterial }
        if strength < 0.50 { return .thinMaterial }
        if strength < 0.78 { return .regularMaterial }
        return .thickMaterial
    }

}

private struct NativeFrostedWindowFrame: View {
    @ObservedObject private var settings = AppSettings.shared

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: settings.glassCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // 全窗口尺寸的 glassEffect 在滑块连续更新时 GPU 代价很高；窗框使用系统 Material，
            // 小尺寸交互卡片仍保留原生 Liquid Glass。
            shape
                .fill(frameMaterial)
                .opacity(0.30 + settings.glassFrameBlurStrength * 0.68)
            shape
                .fill(settings.effectiveAccentColor.opacity(settings.glassTintStrength * 0.075))
            frameHighlights
        }
        .shadow(
            color: .black.opacity(0.08 + settings.glassShadowStrength * 0.30),
            radius: 8 + settings.glassShadowStrength * 22,
            y: 4 + settings.glassShadowStrength * 8
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frameMaterial: Material {
        let strength = settings.glassFrameBlurStrength
        if strength < 0.25 { return .ultraThinMaterial }
        if strength < 0.50 { return .thinMaterial }
        if strength < 0.78 { return .regularMaterial }
        return .thickMaterial
    }

    private var frameHighlights: some View {
        ZStack {
            shape
                .inset(by: 0.5)
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.12 + settings.glassHighlightStrength * 0.64),
                            .white.opacity(0.04 + settings.glassHighlightStrength * 0.18),
                            settings.effectiveAccentColor.opacity(settings.glassTintStrength * 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.4
                )
            RoundedRectangle(cornerRadius: settings.glassInnerBorderCornerRadius, style: .continuous)
                .inset(by: settings.glassFrameWidth - 0.8)
                .stroke(
                    .black.opacity(0.04 + settings.glassShadowStrength * 0.13),
                    lineWidth: 1
                )
            RoundedRectangle(cornerRadius: settings.glassInnerBorderCornerRadius, style: .continuous)
                .inset(by: settings.glassFrameWidth + 0.4)
                .stroke(
                    .white.opacity(0.04 + settings.glassHighlightStrength * 0.22),
                    lineWidth: 0.8
                )
        }
    }
}

private struct NativeMacToolbar: View {
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        HStack(spacing: 10) {
            if dataManager.router.path.count > 1 {
                Button {
                    dataManager.router.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("返回")
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.top, 7)
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    private var title: String {
        if dataManager.router.path.count > 1 { return dataManager.router.getLast().title }
        return switch dataManager.router.getRoot() {
        case .launch: "启动"
        case .download: "下载"
        case .multiplayer: "联机"
        case .settings: "设置"
        case .others: "更多"
        default: "PCL.Mac"
        }
    }
}

private struct NativeMacSidebar: View {
    @ObservedObject private var dataManager = DataManager.shared

    private let routes: [(AppRoute, String, String)] = [
        (.launch, "play.fill", "启动"),
        (.download, "square.and.arrow.down", "下载"),
        (.settings, "gearshape", "设置"),
        (.others, "ellipsis.circle", "更多")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image("Icon")
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("PCL.Mac").font(.system(size: 14, weight: .semibold))
                    Text("Plain Craft Launcher").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ForEach(routes, id: \.0) { route, symbol, label in
                Button {
                    dataManager.router.setRoot(route)
                } label: {
                    Label(label, systemImage: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background {
                            if dataManager.router.getRoot() == route {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.primary.opacity(0.10))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 10)
    }
}

#Preview { ContentView() }
