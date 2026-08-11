import SwiftUI

/// 稳定的导航与窗口表面。只订阅路由和外观，提示/弹窗不会触发这里重算。
struct AppNavigationSurface: View {
    @ObservedObject private var router = DataManager.shared.router
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var glassSettings = GlassSettings.shared

    var body: some View {
        Group {
            if settings.glassEnabled {
                nativeLayout
            } else {
                legacyLayout
            }
        }
    }

    private var nativeLayout: some View {
        ZStack {
            NativeFrostedWindowFrame()
            nativeInterior
                .padding(glassSettings.appearance.frameWidth)
            if settings.windowControlButtonStyle == .pcl {
                HStack(spacing: 4) {
                    Spacer()
                    WindowControlButton.Miniaturize
                    WindowControlButton.Close
                }
                .padding(.top, max(5, glassSettings.appearance.frameWidth * 0.35))
                .padding(.trailing, max(7, glassSettings.appearance.frameWidth * 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else {
                TrafficLightControls(visibility: settings.trafficLightVisibility)
                    .padding(.top, max(1, glassSettings.appearance.frameWidth * 0.14))
                    .padding(
                        settings.trafficLightPosition == .topLeft ? .leading : .trailing,
                        max(2, glassSettings.appearance.frameWidth * 0.20)
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: settings.trafficLightPosition == .topLeft ? .topLeading : .topTrailing
                    )
                    .zIndex(20)
            }
        }
        .background(Color.clear)
        .frame(minWidth: 780, minHeight: 500)
    }

    private var nativeInterior: some View {
        HStack(spacing: 0) {
            NativeLeftColumn()

            VStack(spacing: 0) {
                NativeMacToolbar()
                routedContent
                    .foregroundStyle(.primary)
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
                if router.path.count <= 1 { TitleBarView() }
                else { SubviewTitleBarView() }
            }
            HStack(spacing: 0) {
                LegacyLeftColumn()
                routedContent
                    .foregroundStyle(Color("TextColor"))
            }
            .background(Rectangle().fill(settings.theme.getBackgroundStyle()))
        }
        .frame(minWidth: 700, minHeight: 420)
    }

    /// AnyView 必须绑定容器身份；同一容器内切换子路由时保留视图状态。
    private var routedContent: some View {
        AnyView(router.getLastView())
            .id(router.getLastViewIdentity())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var nativeContentSurface: some View {
        let shape = RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
        if let config = glassSettings.glassConfig {
            LiquidGlassBackground(
                role: .panel,
                config: config,
                blurStrength: glassSettings.appearance.backgroundBlurStrength,
                surfaceOpacity: glassSettings.appearance.surfaceOpacity,
                tintStrength: glassSettings.appearance.tintStrength,
                highlightStrength: glassSettings.appearance.highlightStrength,
                shadowStrength: glassSettings.appearance.shadowStrength,
                interactive: glassSettings.appearance.interactiveEffects,
                shape: shape
            )
        } else {
            shape
                .fill(nativeMaterial(for: settings.glassBackgroundBlurStrength))
                .opacity((0.10 + settings.glassBackgroundBlurStrength * 0.62) * settings.glassSurfaceOpacity)
                .overlay(settings.effectiveAccentColor.opacity(settings.glassTintStrength * 0.04))
                .overlay {
                    shape.stroke(.white.opacity(0.04 + settings.glassHighlightStrength * 0.22), lineWidth: 0.7)
                }
                .shadow(
                    color: .black.opacity(settings.glassShadowStrength * 0.16),
                    radius: 3 + settings.glassShadowStrength * 8,
                    y: 2
                )
        }
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

/// 只有左栏需要订阅 DataManager 的 leftTab* 状态。Java 搜索、版本清单等变化
/// 不再让右侧路由页面和整套玻璃背景一起重新求值。
private struct NativeLeftColumn: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var glassSettings = GlassSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isContentVisible = true

    var body: some View {
        VStack(spacing: 0) {
            NativeMacSidebar()
                .padding(.top, 44)
            Divider().opacity(0.20 + glassSettings.appearance.highlightStrength * 0.20)
            dataManager.leftTabContent
                .scaleEffect(isContentVisible ? 1 : 0.98)
                .opacity(isContentVisible ? 1 : 0)
                .onChange(of: dataManager.leftTabId) { animateContent() }
        }
        .frame(width: max(220, min(310, dataManager.leftTabWidth + 90)))
        .background(sidebarMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.05 + glassSettings.appearance.highlightStrength * 0.20))
                .frame(width: 0.5)
        }
    }

    @ViewBuilder
    private var sidebarMaterial: some View {
        if let config = glassSettings.glassConfig {
            LiquidGlassBackground(
                role: .panel,
                config: config,
                blurStrength: glassSettings.appearance.panelBlurStrength,
                surfaceOpacity: glassSettings.appearance.surfaceOpacity,
                tintStrength: glassSettings.appearance.tintStrength,
                highlightStrength: glassSettings.appearance.highlightStrength,
                shadowStrength: glassSettings.appearance.shadowStrength,
                interactive: glassSettings.appearance.interactiveEffects,
                shape: Rectangle()
            )
        } else {
            Rectangle()
                .fill(material(for: settings.glassPanelBlurStrength))
                .opacity((0.12 + settings.glassPanelBlurStrength * 0.72) * settings.glassSurfaceOpacity)
                .overlay(settings.effectiveAccentColor.opacity(settings.glassTintStrength * 0.055))
        }
    }

    private func material(for strength: Double) -> Material {
        if strength < 0.25 { return .ultraThinMaterial }
        if strength < 0.50 { return .thinMaterial }
        if strength < 0.78 { return .regularMaterial }
        return .thickMaterial
    }

    private func animateContent() {
        guard !reduceMotion else {
            isContentVisible = true
            return
        }
        isContentVisible = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            isContentVisible = true
        }
    }
}

private struct LegacyLeftColumn: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isContentVisible = true

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .background(
                settings.useUltraThinMaterial
                    ? AnyShapeStyle(.ultraThickMaterial)
                    : AnyShapeStyle(Color("BackgroundColor"))
            )
            .shadow(radius: 2)
            .frame(width: dataManager.leftTabWidth)
            .overlay(
                dataManager.leftTabContent
                    .scaleEffect(isContentVisible ? 1 : 0.96)
                    .opacity(isContentVisible ? 1 : 0)
                    .onChange(of: dataManager.leftTabId) { animateContent() }
            )
            .zIndex(1)
    }

    private func animateContent() {
        guard !reduceMotion else {
            isContentVisible = true
            return
        }
        isContentVisible = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            isContentVisible = true
        }
    }
}

private struct NativeFrostedWindowFrame: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var glassSettings = GlassSettings.shared

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: settings.glassCornerRadius, style: .continuous)
    }

    var body: some View {
        frameSurface
            .overlay(frameHighlights)
        .shadow(
            color: glassSettings.glassConfig == nil
                ? .black.opacity(0.08 + settings.glassShadowStrength * 0.30)
                : .clear,
            radius: glassSettings.glassConfig == nil ? 8 + settings.glassShadowStrength * 22 : 0,
            y: glassSettings.glassConfig == nil ? 4 + settings.glassShadowStrength * 8 : 0
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var frameSurface: some View {
        if let config = glassSettings.glassConfig {
            LiquidGlassBackground(
                role: .background,
                config: config,
                blurStrength: glassSettings.appearance.frameBlurStrength,
                surfaceOpacity: glassSettings.appearance.surfaceOpacity,
                tintStrength: glassSettings.appearance.tintStrength,
                highlightStrength: glassSettings.appearance.highlightStrength,
                shadowStrength: glassSettings.appearance.shadowStrength,
                interactive: false,
                shape: shape
            )
        } else {
            ZStack {
                shape
                    .fill(frameMaterial)
                    .opacity(0.30 + settings.glassFrameBlurStrength * 0.68)
                shape
                    .fill(settings.effectiveAccentColor.opacity(settings.glassTintStrength * 0.075))
            }
        }
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
            RoundedRectangle(cornerRadius: glassSettings.appearance.innerBorderCornerRadius, style: .continuous)
                .inset(by: glassSettings.appearance.frameWidth - 0.8)
                .stroke(
                    .black.opacity(0.04 + settings.glassShadowStrength * 0.13),
                    lineWidth: 1
                )
            RoundedRectangle(cornerRadius: glassSettings.appearance.innerBorderCornerRadius, style: .continuous)
                .inset(by: glassSettings.appearance.frameWidth + 0.4)
                .stroke(
                    .white.opacity(0.04 + settings.glassHighlightStrength * 0.22),
                    lineWidth: 0.8
                )
        }
    }
}

private struct NativeMacToolbar: View {
    @ObservedObject private var router = DataManager.shared.router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBackHovered = false

    var body: some View {
        HStack(spacing: 10) {
            if router.canGoBack {
                Button {
                    router.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.primary.opacity(isBackHovered ? 0.10 : 0))
                        }
                }
                .buttonStyle(.plain)
                .onHover { isBackHovered = $0 }
                .help("返回（⌘[）")
                .accessibilityLabel("返回")
                .transition(.opacity)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: router.canGoBack)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isBackHovered)
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.top, 7)
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    private var title: String {
        if router.canGoBack { return router.getLast().title }
        return switch router.getRoot() {
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
    @ObservedObject private var router = DataManager.shared.router

    private let routes: [(AppRoute, String, String)] = [
        (.launch, "play.fill", "启动"),
        (.download, "square.and.arrow.down", "下载"),
        (.multiplayer, "network", "联机"),
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
                    Text("Plain Craft Launcher")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ForEach(Array(routes.enumerated()), id: \.element.0) { index, entry in
                let (route, symbol, label) = entry
                SidebarRow(
                    symbol: symbol,
                    label: label,
                    shortcutIndex: index + 1,
                    isSelected: router.getRoot() == route
                ) {
                    guard router.getRoot() != route else { return }
                    router.setRoot(route)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 10)
    }
}

private struct SidebarRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let symbol: String
    let label: String
    let shortcutIndex: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(settings.effectiveAccentColor) : AnyShapeStyle(Color.clear))
                    .frame(width: 3, height: 16)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(isSelected ? AnyShapeStyle(settings.effectiveAccentColor) : AnyShapeStyle(Color.primary))
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 0)
                Text("⌘\(shortcutIndex)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(isSelected ? 0.10 : (isHovered ? 0.055 : 0)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.13), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
