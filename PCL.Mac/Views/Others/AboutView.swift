//
//  AboutView.swift
//  PCL.Mac Liquid Glass Edition
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            StaticMyCard(index: 0, title: "关于本版本") {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        Image("Icon")
                            .resizable()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(radius: 8)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(SharedConstants.shared.editionName)
                                .font(.system(size: 21, weight: .semibold))
                            Text(SharedConstants.shared.editionSubtitle)
                                .foregroundStyle(.secondary)
                            Text("版本 \(SharedConstants.shared.version) · \(SharedConstants.shared.branch)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Divider()
                    Text("本版本在 PCL.Mac 基础上持续同步 PCL 功能，并重点重构 macOS 26 原生窗口、Liquid Glass、透明材质、可调磨砂窗框，以及登录、整合包和本地维护能力。")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("打开项目仓库") {
                            NSWorkspace.shared.open(SharedConstants.shared.projectURL)
                        }
                        Button("打开数据目录") {
                            NSWorkspace.shared.open(SharedConstants.shared.applicationSupportURL)
                        }
                        Spacer()
                    }
                }
                .padding()
            }
            .padding()

            StaticMyCard(index: 1, title: "本版本特性") {
                VStack(alignment: .leading, spacing: 12) {
                    feature("macwindow", "原生 macOS 26 窗口", "系统交通灯、透明标题栏和可透出桌面的磨砂玻璃框。")
                    feature("circle.hexagongrid.fill", "Liquid Glass", "背景、侧栏、卡片、窗框和高光阴影均可独立调整。")
                    feature("shippingbox.fill", "PCL 功能增强", "持续完善游戏安装、登录、整合包、崩溃分析和下载链路。")
                    feature("slider.horizontal.3", "本地优先配置", "公告源、开发提示、调试路径和界面信息均可由用户控制。")
                }
                .padding()
            }
            .padding()

            StaticMyCard(index: 2, title: "上游与许可") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本项目基于 Plain Craft Launcher 与 PCL.Mac 的既有工作继续开发。原项目作者、贡献者和第三方依赖的版权仍归各自权利人所有。")
                    Divider()
                    dependency("Plain Craft Launcher", "Meloong-Git/PCL")
                    dependency("PCL.Mac upstream", "PCL-Community/PCL.Mac")
                    dependency("SwiftyJSON", "SwiftyJSON/SwiftyJSON")
                    dependency("ZIPFoundation", "weichsel/ZIPFoundation")
                }
                .font(.system(size: 13))
                .padding()
            }
            .padding()
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
    }

    private func feature(_ symbol: String, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(description).foregroundStyle(.secondary)
            }
        }
    }

    private func dependency(_ name: String, _ repository: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Button(repository) {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(repository)")!)
            }
            .buttonStyle(.link)
        }
    }
}

#Preview { AboutView().padding() }
