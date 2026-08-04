//
//  PCL_MacApp.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/17.
//

import SwiftUI

@main
struct PCL_MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        _ = AppStartTracker.shared
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowAccessor())
        }
        .defaultSize(width: 980, height: 650)
        .commands {
            AppCommands()
        }
        .windowStyle(.hiddenTitleBar) // 避免刚启动时闪一下标题栏
    }
}

public struct WindowAccessor: NSViewRepresentable {
    @ObservedObject private var settings = AppSettings.shared

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        // 仅在 appearanceRevision 真正变化时重新配置窗口，
        // 避免父 view（订阅 AppSettings 的 ContentView）每次重渲都触发
        // frame 重算 / traffic light 重新布局。
        guard let window = nsView.window else { return }
        guard context.coordinator.lastAppearanceRevision != settings.appearanceRevision else {
            return
        }
        context.coordinator.lastAppearanceRevision = settings.appearanceRevision
        configure(window, coordinator: context.coordinator)
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true

        if settings.glassEnabled {
            coordinator.enterGlassMode(window: window, frameWidth: settings.glassFrameWidth)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            coordinator.hideSystemTrafficLights(window)
        } else {
            coordinator.leaveGlassMode(window: window)
            // miniaturizable 只对带标题栏的窗口生效。保留透明的系统标题栏能力，
            // 视觉仍由应用自绘，窗口服务器则能正常创建 Dock 最小化 counterpart。
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            coordinator.hideSystemTrafficLights(window)
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = 10
                contentView.layer?.masksToBounds = true
            }
        }
        coordinator.observeWindowLifecycle(window)
    }

    public final class Coordinator {
        private var appliedFrameWidth: Double?
        private var appliedFrameAdjustment: Double = 0
        private weak var observedWindow: NSWindow?
        private var windowObservers: [NSObjectProtocol] = []
        /// 记录上次 configure 时的 appearanceRevision，避免重复 configure。
        var lastAppearanceRevision: UInt = UInt.max

        public init() {}

        deinit {
            removeWindowObservers()
        }

        public func enterGlassMode(window: NSWindow, frameWidth: Double) {
            let normalizedFrameWidth = max(0, frameWidth)
            let old = appliedFrameWidth ?? normalizedFrameWidth
            let delta = normalizedFrameWidth - old
            if abs(delta) > 0.1 {
                adjustFrame(window, by: delta)
                appliedFrameAdjustment += delta
            }
            appliedFrameWidth = normalizedFrameWidth
            window.contentView?.layer?.masksToBounds = false
        }

        public func leaveGlassMode(window: NSWindow) {
            if abs(appliedFrameAdjustment) > 0.1 {
                adjustFrame(window, by: -appliedFrameAdjustment)
            }
            appliedFrameAdjustment = 0
            appliedFrameWidth = nil
        }

        private func adjustFrame(_ window: NSWindow, by inset: Double) {
            var frame = window.frame
            frame.origin.x -= inset
            frame.origin.y -= inset
            frame.size.width += inset * 2
            frame.size.height += inset * 2
            window.setFrame(frame, display: true, animate: false)
        }

        func hideSystemTrafficLights(_ window: NSWindow) {
            setButtons(trafficButtons(window), visible: false)
        }

        /// AppKit 会在进出全屏时重建部分标题栏层级；完成转换后再次隐藏原生按钮，
        /// 防止它们与 SwiftUI 自绘交通灯短暂重叠。
        func observeWindowLifecycle(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            removeWindowObservers()
            observedWindow = window

            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    guard let self, let window else { return }
                    self.hideSystemTrafficLights(window)
                }
                windowObservers.append(token)
            }
        }

        private func trafficButtons(_ window: NSWindow) -> [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        }

        private func setButtons(_ buttons: [NSButton], visible: Bool) {
            for button in buttons {
                button.isHidden = !visible
                button.alphaValue = visible ? 1 : 0
            }
        }

        private func removeWindowObservers() {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers.removeAll()
            observedWindow = nil
        }
    }
}
