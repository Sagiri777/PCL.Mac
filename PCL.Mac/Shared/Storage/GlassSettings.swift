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

public final class GlassSettings: ObservableObject {
    public static let shared = GlassSettings()

    /// 仅发布"玻璃参数"变化，不再通过 AppSettings 全局广播。
    public func refresh() {
        objectWillChange.send()
    }

    /// 当前主题色（取自 AppSettings，便于 BaseCardContainer 不订阅 AppSettings 也能渲染）。
    /// 初始用系统色，等到 AppSettings 完成初始化后由 AppDelegate 显式调 reloadThemeDerived() 覆盖。
    @Published public private(set) var accentColor: Color = .accentColor

    /// 当前主题的液态玻璃配置（nil = 非玻璃主题）。
    @Published public private(set) var glassConfig: GlassConfig?

    public init() {
        // ⚠️ 不要在这里访问 AppSettings.shared。
        // 本类常量的初始化会在应用启动早期发生；如果此时 AppSettings.shared
        // 还没完成它的 once 块，再次进 dispatch_once 会被 libdispatch 当作
        // 递归锁处理，触发 EXC_BREAKPOINT("trying to lock recursively")。
        // 用默认值起步，等 AppSettings 完成 init 后再由 AppDelegate 主动
        // 调用 reloadThemeDerived() 把派生值 push 过来。
        self.glassConfig = nil
        self.accentColor = .accentColor
    }

    /// 主题/主题色变更时由 AppSettings 主动调用，重新缓存派生值。
    /// ⚠️ 调用方必须保证 AppSettings.shared 已经初始化完成（典型调用点是
    /// AppDelegate.applicationWillFinishLaunching、AppSettings.updateColorScheme、
    /// themeId.didSet 等"用户态"路径）。
    public func reloadThemeDerived() {
        let s = AppSettings.shared
        glassConfig = s.theme?.getGlassConfig()
        accentColor = s.effectiveAccentColor
        objectWillChange.send()
    }
}
