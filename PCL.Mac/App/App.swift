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
            CommandGroup(replacing: .appInfo) {
                Button("关于 PCL.Mac") {
                    DataManager.shared.router.setRoot(.others)
                    DataManager.shared.router.append(.about)
                }
            }
            
            CommandGroup(replacing: .appSettings) {
                Button("设置") {
                    DataManager.shared.router.setRoot(.settings)
                    DataManager.shared.router.append(.personalization)
                }
            }
            
            CommandGroup(replacing: .newItem) { } // 修复 #21
        }
        .windowStyle(.hiddenTitleBar) // 避免刚启动时闪一下标题栏
    }
}

struct WindowAccessor: NSViewRepresentable {
    @ObservedObject private var settings = AppSettings.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 仅在 appearanceRevision 真正变化时重新配置窗口，
        // 避免父 view（订阅 AppSettings 的 ContentView）每次重渲都触发
        // frame 重算 / traffic light 重新布局。
        guard context.coordinator.lastAppearanceRevision != settings.appearanceRevision else {
            return
        }
        context.coordinator.lastAppearanceRevision = settings.appearanceRevision
        configure(nsView.window, coordinator: context.coordinator)
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
            if settings.windowControlButtonStyle == .macOS {
                coordinator.configureTrafficLights(window: window, position: settings.trafficLightPosition, visibility: settings.trafficLightVisibility, frameWidth: settings.glassFrameWidth)
            } else {
                coordinator.hideSystemTrafficLights(window)
            }
        } else {
            coordinator.leaveGlassMode()
            window.styleMask = [.borderless, .miniaturizable, .resizable]
            coordinator.hideSystemTrafficLights(window)
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = 10
                contentView.layer?.masksToBounds = true
            }
        }
    }

    final class Coordinator {
        private var appliedFrameWidth: Double?
        private var hoverMonitor: Any?
        private var trafficConfiguration: String?
        private weak var hoverWindow: NSWindow?
        private var hoverPosition: TrafficLightPosition = .topLeft
        private var hoverButtons: [NSButton] = []
        /// 记录上次 configure 时的 appearanceRevision，避免重复 configure。
        var lastAppearanceRevision: UInt = UInt.max

        deinit { removeHoverMonitor() }

        func enterGlassMode(window: NSWindow, frameWidth: Double) {
            let old = appliedFrameWidth ?? frameWidth
            let delta = frameWidth - old
            if abs(delta) > 0.1 {
                var frame = window.frame
                frame.origin.x -= delta
                frame.origin.y -= delta
                frame.size.width += delta * 2
                frame.size.height += delta * 2
                window.setFrame(frame, display: true, animate: false)
            }
            appliedFrameWidth = frameWidth
            window.contentView?.layer?.masksToBounds = false
        }

        func leaveGlassMode() {
            appliedFrameWidth = nil
            trafficConfiguration = nil
            removeHoverMonitor()
        }

        func hideSystemTrafficLights(_ window: NSWindow) {
            trafficConfiguration = "hidden-system"
            removeHoverMonitor()
            setButtons(trafficButtons(window), visible: false)
        }

        func configureTrafficLights(window: NSWindow, position: TrafficLightPosition, visibility: TrafficLightVisibility, frameWidth: Double) {
            let configuration = "\(position.rawValue)-\(visibility.rawValue)-\(frameWidth)-\(window.frame.width)"
            guard trafficConfiguration != configuration else { return }
            trafficConfiguration = configuration
            let buttons = trafficButtons(window)
            guard buttons.count == 3 else { return }
            let spacing: CGFloat = 20
            guard let container = buttons[0].superview else { return }
            let y = max(6, (container.bounds.height - buttons[0].frame.height) / 2)
            let firstX: CGFloat = position == .topLeft
                ? max(12, frameWidth * 0.62)
                : max(12, container.bounds.width - frameWidth * 0.62 - spacing * 3)
            for (index, button) in buttons.enumerated() {
                button.setFrameOrigin(NSPoint(x: firstX + CGFloat(index) * spacing, y: y))
            }

            switch visibility {
            case .always:
                removeHoverMonitor()
                setButtons(buttons, visible: true)
            case .hidden:
                removeHoverMonitor()
                setButtons(buttons, visible: false)
            case .hover:
                installHoverMonitor(window: window, position: position, buttons: buttons)
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

        private func installHoverMonitor(window: NSWindow, position: TrafficLightPosition, buttons: [NSButton]) {
            removeHoverMonitor()
            hoverWindow = window
            hoverPosition = position
            hoverButtons = buttons
            setButtons(buttons, visible: false)
            window.acceptsMouseMovedEvents = true

            // 使用全局事件监视器：SwiftUI 的 ScrollView/控件可能吞掉 local mouseMoved，
            // 导致只有设置页空白区域能触发。屏幕坐标检测不依赖当前页面命中链。
            hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                DispatchQueue.main.async { self?.updateHoverVisibility() }
            }
            updateHoverVisibility()
        }

        private func updateHoverVisibility() {
            guard let window = hoverWindow, !hoverButtons.isEmpty else { return }
            let mouse = NSEvent.mouseLocation
            let frame = window.frame
            let nearTop = mouse.y >= frame.maxY - 76 && mouse.y <= frame.maxY + 8
            let nearSide = hoverPosition == .topLeft
                ? mouse.x >= frame.minX - 8 && mouse.x <= frame.minX + 150
                : mouse.x <= frame.maxX + 8 && mouse.x >= frame.maxX - 150
            setButtons(hoverButtons, visible: nearTop && nearSide)
        }

        private func removeHoverMonitor() {
            if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
            hoverMonitor = nil
            hoverWindow = nil
            hoverButtons = []
        }
    }
}
