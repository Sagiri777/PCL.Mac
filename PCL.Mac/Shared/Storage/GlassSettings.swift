//
//  GlassSettings.swift
//  PCL.Mac
//
//  把 macOS26 液态玻璃相关参数从 AppSettings 中抽离，作为独立的 ObservableObject。
//
// 设计动机：
// - AppSettings.refreshVisuals() 原来会调用 objectWillChange.send()，
//   导致所有订阅 AppSettings 的 view（含每张 MyCard/StaticMyCard/TitlelessMyCard）重渲染。
//   拖动玻璃滑块时尤其明显。
// - 现在玻璃参数由 GlassSettings 单独发布；订阅 GlassSettings 的 view（卡片背景、
//   PersonalizationView、ContentView 的玻璃表面、WindowAccessor）才参与重渲染。
// - AppSettings 仍保留 glassXxx @AppStorage 字段作为持久化存储，保证历史设置不丢；
//   GlassSettings 由 AppSettings 主动 push（reloadThemeDerived）来同步派生值，
//   不在自身 init 里反向读取 AppSettings —— 否则会和 AppSettings.init 形成
//   dispatch_once 递归（libdispatch 不允许在同一线程栈上嵌套两个不同的 once 块），
//   启动时会被 SIGTRAP 杀掉（"BUG IN CLIENT OF LIBDISPATCH: trying to lock recursively"）。
//

import Foundation
import SwiftUI

public struct GlassAppearanceState {
    public let glassConfig: GlassConfig?
    public let accentColor: Color
    public let backgroundBlurStrength: Double
    public let panelBlurStrength: Double
    public let cardBlurStrength: Double
    public let frameWidth: Double
    public let frameBlurStrength: Double
    public let surfaceOpacity: Double
    public let tintStrength: Double
    public let highlightStrength: Double
    public let shadowStrength: Double
    public let cornerRadius: Double
    public let innerBorderCornerRadius: Double
    public let contentCornerRadius: Double
    public let interactiveEffects: Bool

    public init(
        glassConfig: GlassConfig? = nil,
        accentColor: Color = .accentColor,
        backgroundBlurStrength: Double = 1,
        panelBlurStrength: Double = 1,
        cardBlurStrength: Double = 1,
        frameWidth: Double = 14,
        frameBlurStrength: Double = 0.78,
        surfaceOpacity: Double = 0.70,
        tintStrength: Double = 0.22,
        highlightStrength: Double = 0.62,
        shadowStrength: Double = 0.55,
        cornerRadius: Double = 22,
        innerBorderCornerRadius: Double = 10,
        contentCornerRadius: Double = 14,
        interactiveEffects: Bool = true
    ) {
        self.glassConfig = glassConfig
        self.accentColor = accentColor
        self.backgroundBlurStrength = backgroundBlurStrength.clamped(to: 0...1)
        self.panelBlurStrength = panelBlurStrength.clamped(to: 0...1)
        self.cardBlurStrength = cardBlurStrength.clamped(to: 0...1)
        self.frameWidth = max(0, frameWidth)
        self.frameBlurStrength = frameBlurStrength.clamped(to: 0...1)
        self.surfaceOpacity = surfaceOpacity.clamped(to: 0...1)
        self.tintStrength = tintStrength.clamped(to: 0...1)
        self.highlightStrength = highlightStrength.clamped(to: 0...1)
        self.shadowStrength = shadowStrength.clamped(to: 0...1)
        self.cornerRadius = max(0, cornerRadius)
        self.innerBorderCornerRadius = max(0, innerBorderCornerRadius)
        self.contentCornerRadius = max(0, contentCornerRadius)
        self.interactiveEffects = interactiveEffects
    }
}

public final class GlassSettings: ObservableObject {
    public static let shared = GlassSettings()

    /// 仅发布"玻璃参数"变化，不再通过 AppSettings 全局广播。
    public func refresh() {
        objectWillChange.send()
    }

    /// 所有 Glass 派生值的单一发布入口，避免 AppStorage 不发布导致界面读到旧值。
    /// 初始用默认值，等 AppSettings 完成初始化后由 AppDelegate 显式同步。
    @Published public private(set) var appearance = GlassAppearanceState()

    public var accentColor: Color { appearance.accentColor }
    public var glassConfig: GlassConfig? { appearance.glassConfig }

    public init() {
        // ⚠️ 不要在这里访问 AppSettings.shared。
        // 本类常量的初始化会在应用启动早期发生；如果此时 AppSettings.shared
        // 还没完成它的 once 块，再次进 dispatch_once 会被 libdispatch 当作
        // 递归锁处理，触发 EXC_BREAKPOINT("trying to lock recursively")。
        // 用默认值起步，等 AppSettings 完成 init 后再由 AppDelegate 主动
        // 调用 reloadThemeDerived() 把派生值 push 过来。
        self.appearance = GlassAppearanceState()
    }

    /// 主题/主题色变更时由 AppSettings 主动调用，重新缓存派生值。
    /// ⚠️ 调用方必须保证 AppSettings.shared 已经初始化完成（典型调用点是
    /// AppDelegate.applicationWillFinishLaunching、AppSettings.updateColorScheme、
    /// themeId.didSet 等"用户态"路径）。
    public func reloadThemeDerived() {
        let s = AppSettings.shared
        let accentColor = s.customAccentColorEnabled
            ? Color(.sRGB, red: s.customAccentRed, green: s.customAccentGreen, blue: s.customAccentBlue)
            : (s.theme?.baseAccentColor ?? s.cachedAccentColor)
        appearance = GlassAppearanceState(
            glassConfig: s.theme?.getGlassConfig(),
            accentColor: accentColor,
            backgroundBlurStrength: s.glassBackgroundBlurStrength,
            panelBlurStrength: s.glassPanelBlurStrength,
            cardBlurStrength: s.glassCardBlurStrength,
            frameWidth: s.glassFrameWidth,
            frameBlurStrength: s.glassFrameBlurStrength,
            surfaceOpacity: s.glassSurfaceOpacity,
            tintStrength: s.glassTintStrength,
            highlightStrength: s.glassHighlightStrength,
            shadowStrength: s.glassShadowStrength,
            cornerRadius: s.glassCornerRadius,
            innerBorderCornerRadius: s.glassInnerBorderCornerRadius,
            contentCornerRadius: s.glassContentCornerRadius,
            interactiveEffects: s.glassInteractiveEffects
        )
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
