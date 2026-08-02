//
//  TitleBarView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/17.
//

import SwiftUI

struct DraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DraggableHelperView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class DraggableHelperView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        self.window?.defaultButtonCell?.performClick(self)
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }
}

struct GenericTitleBarView<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack {
            ZStack {
                DraggableArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                HStack(alignment: .center) {
                    if settings.windowControlButtonStyle == .macOS,
                       settings.trafficLightPosition == .topLeft {
                        TrafficLightControls(visibility: settings.trafficLightVisibility)
                    }
                    content()
                    Spacer()
                    if settings.windowControlButtonStyle == .macOS,
                       settings.trafficLightPosition == .topRight {
                        TrafficLightControls(visibility: settings.trafficLightVisibility)
                    } else if settings.windowControlButtonStyle == .pcl {
                        WindowControlButton.Miniaturize
                        WindowControlButton.Close
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 48)
        .background(
            settings.theme.getStyle()
        )
    }
}

struct TitleBarView: View {
    var body: some View {
        GenericTitleBarView {
            Group {
                if AppSettings.shared.windowControlButtonStyle == .pcl {
                    Image("TitleLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 19)
                        .bold()
                    MyTag(label: "Mac", backgroundColor: .white)
                        .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                }
                Spacer()
                MenuItemButton(route: .launch)
                MenuItemButton(route: .download)
//                MenuItemButton(route: .multiplayer)
                MenuItemButton(route: .settings)
                MenuItemButton(route: .others)
            }
        }
    }
}

struct SubviewTitleBarView: View {
    @ObservedObject private var router = DataManager.shared.router

    var body: some View {
        GenericTitleBarView {
            WindowControlButton.Back
            Text(router.getLast().title)
                .font(.custom("PCL English", size: 16))
                .foregroundStyle(.white)
        }
    }
}

struct MenuItemButton: View {
    @ObservedObject private var router = DataManager.shared.router
    
    let route: AppRoute
    var icon: Image?
    @State private var isHovered = false
    
    var body: some View {
        Button {
            if router.getRoot() != route { router.setRoot(route) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .foregroundStyle(router.getRoot() == route ? .white : (isHovered ? Color(hex: 0xFFFFFF, alpha: 0.17) : .clear))
                HStack(spacing: 7) {
                    getImage()
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text(getText())
                }
                .foregroundStyle(router.getRoot() == route ? AnyShapeStyle(AppSettings.shared.theme.getTextStyle()) : AnyShapeStyle(.white))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 75, height: 27)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: router.getRoot() == route)
        .onHover { isHovered = $0 }
        .accessibilityLabel(getText())
        .accessibilityAddTraits(router.getRoot() == route ? .isSelected : [])
    }
    
    private func getImage() -> Image {
        let key = switch route {
        case .launch: "LaunchIcon"
        case .download: "DownloadIcon"
        case .multiplayer: "MultiplayerIcon"
        case .settings: "SettingsIcon"
        case .others: "OthersIcon"
        default: ""
        }
        return Image(key)
    }
    
    private func getText() -> String {
        return switch route {
        case .launch: "启动"
        case .download: "下载"
        case .multiplayer: "联机"
        case .settings: "设置"
        case .others: "更多"
        default: ""
        }
    }
}

#Preview {
    TitleBarView()
}
