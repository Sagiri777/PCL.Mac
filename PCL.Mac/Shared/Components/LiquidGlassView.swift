//
//  LiquidGlassView.swift
//  PCL.Mac
//
//  纯 SwiftUI 液态玻璃渲染层。macOS 26 使用系统原生 glassEffect，
//  较早系统使用 SwiftUI Material 回退，不桥接 NSVisualEffectView / AppKit。
//

import SwiftUI

public enum GlassRole {
    case card
    case panel
    case background
}

public struct LiquidGlassBackground<S: InsettableShape>: View {
    private let role: GlassRole
    private let config: GlassConfig
    private let blurStrength: Double
    private let shape: S
    private let surfaceOpacityMultiplier: Double
    private let tintStrength: Double
    private let highlightStrength: Double
    private let shadowStrength: Double
    private let interactive: Bool

    public init(
        role: GlassRole,
        config: GlassConfig,
        blurStrength: Double = 1,
        surfaceOpacity: Double = 1,
        tintStrength: Double = 1,
        highlightStrength: Double = 1,
        shadowStrength: Double = 1,
        interactive: Bool = true,
        shape: S
    ) {
        self.role = role
        self.config = config
        self.blurStrength = blurStrength.clamped(to: 0...1)
        self.surfaceOpacityMultiplier = surfaceOpacity.clamped(to: 0...1)
        self.tintStrength = tintStrength.clamped(to: 0...1)
        self.highlightStrength = highlightStrength.clamped(to: 0...1)
        self.shadowStrength = shadowStrength.clamped(to: 0...1)
        self.interactive = interactive
        self.shape = shape
    }

    @ViewBuilder
    public var body: some View {
        // 卡片列表可能同时创建大量玻璃层，逐卡片采样会明显增加滚动成本。
        // 窗口、侧栏和内容表面则使用 macOS 26 的原生实现；旧系统以及卡片
        // 保持 Material 回退，保证 macOS 14+ 的行为和性能边界稳定。
        Group {
            if #available(macOS 26.0, *), role != .card {
                nativeLiquidGlass
            } else {
                swiftUIMaterialFallback
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @available(macOS 26.0, *)
    private var nativeLiquidGlass: some View {
        shape
            .fill(.clear)
            .glassEffect(
                .regular
                    .tint(tintColor.opacity(tintOpacity))
                    .interactive(interactive && role != .background),
                in: shape
            )
            // glassEffect 自己负责背景采样和模糊。这里不能再把“模糊强度”
            // 乘进整层 opacity，否则较低的模糊设置会同时让窗口几乎透明。
            .opacity(GlassRenderingMetrics.nativeSurfaceOpacity(
                surfaceOpacityMultiplier: surfaceOpacityMultiplier
            ))
            .overlay(highlightBorder)
            .shadow(color: borderColor.opacity(shadowOpacity), radius: shadowRadius, y: 1)
    }

    private var swiftUIMaterialFallback: some View {
        shape
            .fill(fallbackMaterial)
            .opacity(GlassRenderingMetrics.fallbackSurfaceOpacity(
                effectiveStrength: effectiveStrength,
                surfaceOpacityMultiplier: surfaceOpacityMultiplier
            ))
            .overlay(shape.fill(tintColor.opacity(tintOpacity)))
            .overlay(highlightBorder)
            .shadow(color: borderColor.opacity(shadowOpacity), radius: shadowRadius, y: 1)
    }

    private var highlightBorder: some View {
        shape
            .inset(by: 0.5)
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(borderOpacity * highlightStrength),
                        borderColor.opacity(borderOpacity * 0.55 * highlightStrength),
                        .white.opacity(borderOpacity * 0.18 * highlightStrength)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var roleStrength: Double {
        switch role {
        case .card: config.cardBlur
        case .panel: config.panelBlur
        case .background: config.backgroundBlur
        }
    }

    private var effectiveStrength: Double {
        (roleStrength * blurStrength).clamped(to: 0...1)
    }

    private var fallbackMaterial: Material {
        if effectiveStrength < 0.34 { return .ultraThinMaterial }
        if effectiveStrength < 0.67 { return .regularMaterial }
        return .thickMaterial
    }

    private var tintColor: Color {
        config.tintColor ?? Color(hex: 0x0A84FF)
    }

    private var borderColor: Color {
        config.borderColor ?? Color.white
    }

    private var tintOpacity: Double {
        (0.025 + effectiveStrength * 0.075) * tintStrength
    }

    private var borderOpacity: Double {
        0.18 + effectiveStrength * 0.34
    }

    private var shadowOpacity: Double {
        (0.05 + effectiveStrength * 0.14) * shadowStrength
    }

    private var shadowRadius: Double {
        (2 + effectiveStrength * 6) * (0.35 + shadowStrength * 0.65)
    }
}

enum GlassRenderingMetrics {
    static func nativeSurfaceOpacity(surfaceOpacityMultiplier: Double) -> Double {
        surfaceOpacityMultiplier.clamped(to: 0...1)
    }

    static func fallbackSurfaceOpacity(
        effectiveStrength: Double,
        surfaceOpacityMultiplier: Double
    ) -> Double {
        (0.12 + effectiveStrength.clamped(to: 0...1) * 0.88)
            * surfaceOpacityMultiplier.clamped(to: 0...1)
    }
}

public extension Theme {
    var isGlassTheme: Bool { getGlassConfig()?.enabled == true }
}

public extension AppSettings {
    var glassEnabled: Bool { theme?.isGlassTheme == true }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
