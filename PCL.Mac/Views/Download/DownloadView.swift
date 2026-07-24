//
//  DownloadView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/18.
//

import SwiftUI

struct DownloadView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    
    var body: some View {
        Group {
            switch dataManager.router.getLast() {
            case .minecraftDownload:
                MinecraftDownloadView()
            case .projectSearch(let type):
                ProjectSearchView(type: type)
                    .id(type)
            default:
                Spacer()
                    .onAppear {
                        if dataManager.router.getLast() == .download {
                            dataManager.router.append(.minecraftDownload)
                        }
                    }
            }
        }
        .onAppear {
            dataManager.leftTab(170) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Minecraft")
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                        .padding(.leading, 12)
                        .padding(.top, 20)
                        .padding(.bottom, 4)
                    MyList(
                        cases: .constant([.minecraftDownload])
                    ) { type, isSelected in
                        createListItemView(type)
                            .foregroundStyle(isSelected ? AnyShapeStyle(AppSettings.shared.theme.getTextStyle()) : AnyShapeStyle(Color("TextColor")))
                    }
                    .id("DownloadList")
                    Text("社区资源")
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                        .padding(.leading, 12)
                        .padding(.top, 32)
                        .padding(.bottom, 4)
                    MyList(
                        cases: .constant([.projectSearch(type: .mod), .projectSearch(type: .resourcepack)]),
                        animationIndex: 2
                    ) { type, isSelected in
                        createListItemView(type)
                            .foregroundStyle(isSelected ? AnyShapeStyle(AppSettings.shared.theme.getTextStyle()) : AnyShapeStyle(Color("TextColor")))
                    }
                    .id("DownloadList")
                    Spacer()
                }
            }
        }
    }
    
    private func createListItemView(_ lastComponent: AppRoute) -> some View {
        let imageName: String, text: String
        switch lastComponent {
        case .minecraftDownload:
            imageName = "GameDownloadIcon"
            text = "游戏下载"
        case .projectSearch(let type):
            switch type {
            case .mod:
                imageName = "ModDownloadIcon"
            case .resourcepack:
                imageName = "PictureIcon"
            case .shader:
                imageName = "ModDownloadIcon"
            }
            text = type.getName()
        default:
            return AnyView(EmptyView())
        }
        
        return AnyView(
            HStack {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                Text(text)
                    .font(.custom("PCL English", size: 14))
            }
        )
    }
}

/// RoundedButton 的专用 ButtonStyle。
///
/// 为什么单独写一个：早期版本为了实现按下缩放，把 .onLongPressGesture 挂在外
/// 面上，结果和 Button 内部的 tap recognizer 抢同一组鼠标事件，导致 “刷新”
/// “返回” 等按钮偶发不响应（参见 MyButton.swift 顶部说明）。
/// 这里用 SwiftUI 原生的 configuration.isPressed 实现视觉反馈，按钮的
/// click 就不会被任何额外 gesture 干扰。
private struct RoundedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct RoundedButton<Content: View>: View {
    let content: () -> Content
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            content()
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: .infinity)
                        .fill(AppSettings.shared.theme.getAccentColor())
                )
                .contentShape(Circle())
        }
        .buttonStyle(RoundedButtonStyle())
    }
}
