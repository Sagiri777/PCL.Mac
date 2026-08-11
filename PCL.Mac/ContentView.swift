//
//  ContentView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/17.
//

import SwiftUI

/// 应用根视图只负责组合稳定的功能层。
///
/// 导航、弹窗、提示和登录各自订阅自己的状态，避免任意一个高频状态变化都让
/// 当前路由页面和整套 Liquid Glass 背景重新求值。
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isGlobalDropHovering = false

    var body: some View {
        ZStack {
            AppNavigationSurface()
            AppOverlayHost()
            if isGlobalDropHovering {
                GlobalDropOverlay()
            }
        }
        .background(Color.clear)
        .ignoresSafeArea(.container, edges: .top)
        .modifier(AppPresentationModifier())
        .dropDestination(for: URL.self) { urls, _ in
            Task {
                await handleGlobalDrop(urls: urls)
            }
            return true
        } isTargeted: { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isGlobalDropHovering = hovering
            }
        }
        .onAppear {
            guard !AppStartTracker.shared.finished else { return }
            AppStartTracker.shared.finished = true
            let elapsed = Date().timeIntervalSince1970 - AppStartTracker.shared.launchTime
            log("主界面加载完成, App 启动总耗时 \(Int(elapsed * 1_000))ms")
        }
    }

    private func handleGlobalDrop(urls rawURLs: [URL]) async {
        guard !rawURLs.isEmpty else { return }
        let classification = ModInstaller.classify(rawURLs)
        guard classification.hasAny else {
            hint("未识别任何可导入内容", .critical)
            return
        }

        var installedMods = 0
        var failed = 0

        if !classification.modpacks.isEmpty {
            guard let directory = AppSettings.shared.currentMinecraftDirectory else {
                hint("请先选择 Minecraft 文件夹！", .critical)
                return
            }
            ModpackImportManager.shared.present(
                urls: classification.modpacks,
                directory: directory,
                autoStart: true
            )
        }

        if !classification.mods.isEmpty {
            if let instance = DataManager.shared.defaultInstance {
                let summary = await ModInstaller.install(dropped: classification.mods, into: instance)
                installedMods += summary.installedJars
                failed += summary.failures.count
            } else {
                failed += classification.mods.count
                warn("拖入了 Mod 文件，但当前没有默认实例。")
            }
        }

        var result: [String] = []
        if !classification.modpacks.isEmpty { result.append("已打开整合包导入任务") }
        if installedMods > 0 { result.append("已安装 \(installedMods) 个 Mod") }
        if failed > 0 { result.append("失败 \(failed) 项") }
        hint(
            result.isEmpty ? "没有可导入内容" : result.joined(separator: "，"),
            failed > 0 ? .critical : .finish
        )
    }
}

#Preview { ContentView() }
