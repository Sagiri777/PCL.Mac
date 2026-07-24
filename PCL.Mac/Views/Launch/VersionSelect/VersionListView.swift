//
//  VersionList.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/1.
//

import SwiftUI

struct VersionListView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    let minecraftDirectory: MinecraftDirectory
    
    struct VersionView: View, Identifiable {
        @State private var isHovered: Bool = false
        private let instanceInfo: InstanceInfo
        
        let id: UUID = UUID()
        
        init(instanceInfo: InstanceInfo) {
            self.instanceInfo = instanceInfo
        }
        
        var body: some View {
            MyListItem {
                HStack {
                    Image(instanceInfo.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 35)
                        .padding(.leading, 5)
                    VStack(alignment: .leading) {
                        Text(instanceInfo.name)
                            .font(.custom("PCL English", size: 14))
                            .foregroundStyle(Color("TextColor"))
                            .padding(.top, 5)
                        Text(instanceInfo.version.displayName)
                            .font(.custom("PCL English", size: 14))
                            .foregroundStyle(Color(hex: 0x7F8790))
                            .padding(.bottom, 5)
                    }
                    Spacer()
                    if isHovered {
                        HStack {
                            Image(systemName: "xmark")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 10)
                                .bold()
                                .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    deleteInstance()
                                }
                        }
                        .padding(.trailing, 12)
                    }
                }
            }
            .onTapGesture {
                AppSettings.shared.defaultInstance = instanceInfo.name
                DataManager.shared.router.setRoot(.launch)
            }
            .padding(.top, -8)
            .onHover { isHovered in
                self.isHovered = isHovered
            }
            .animation(.easeInOut(duration: 0.2), value: isHovered)
        }
        
        private func deleteInstance() {
            Task {
                let result = await PopupManager.shared.showAsync(
                    PopupModel(
                        .normal,
                        "删除版本",
                        "确定要删除版本 \"\(instanceInfo.name)\" 吗？\n\n此操作将永久删除该版本的所有文件，包括模组、资源包等。\n真的很久！",
                        [
                            PopupButtonModel(label: "取消", style: .normal),
                            PopupButtonModel(label: "删除", style: .danger)
                        ]
                    )
                )
                
                if result == 1 { // 用户点击了删除按钮
                    do {
                        let versionName = instanceInfo.name
                        let runningDirectory = instanceInfo.runningDirectory
                        
                        // 删除版本文件夹
                        try FileManager.default.removeItem(at: runningDirectory)
                        
                        // 清理MinecraftInstance缓存
                        MinecraftInstance.clearCache(for: runningDirectory)
                        
                        // 如果删除的是当前默认实例，清空默认实例设置
                        if AppSettings.shared.defaultInstance == versionName {
                            AppSettings.shared.defaultInstance = nil
                        }
                        
                        // 重新加载实例列表
                        instanceInfo.minecraftDirectory.loadInnerInstances { instances in
                            // 如果删除的是默认实例且还有其他实例，自动选择第一个作为新的默认实例
                            if AppSettings.shared.defaultInstance == nil && !instances.isEmpty {
                                AppSettings.shared.defaultInstance = instances.first?.name
                            }
                            
                            DataManager.shared.router.path = [.versionSelect, .versionList(directory: instanceInfo.minecraftDirectory)]
                        }
                        
                        hint("版本 \"\(versionName)\" 已删除", .finish)
                    } catch {
                        err("删除版本失败: \(error.localizedDescription)")
                        hint("删除版本失败: \(error.localizedDescription)", .critical)
                    }
                }
            }
        }
    }
    var body: some View {
        // 三态：isLoading / loadError / instances.isEmpty / 非空。
        // 关键规则：永远不要让"加载中……"在没有 IO 进行中的情况下显示；调用方必须保证
        // loadInnerInstances 完成后 isLoading 回 false（由 MinecraftDirectory 端负责）。
        VStack {
            if minecraftDirectory.isLoading
                && minecraftDirectory.instances.isEmpty
                && minecraftDirectory.loadError == nil {
                // 正在加载 —— 显式 spinner + 文字
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("加载中……")
                        .foregroundStyle(Color("TextColor"))
                        .font(.custom("PCL English", size: 14))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = minecraftDirectory.loadError,
                      minecraftDirectory.instances.isEmpty {
                // 加载失败 —— 给出错误信息和"重试"按钮
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(hex: 0xF50000))
                    Text("读取版本目录失败")
                        .font(.custom("PCL English", size: 16))
                        .foregroundStyle(Color("TextColor"))
                    Text(err)
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    MyButton(text: "重试") {
                        loadInstances(minecraftDirectory)
                    }
                    .frame(width: 120, height: 30)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if minecraftDirectory.instances.isEmpty {
                // 加载成功，但目录里确实没版本 —— 引导用户去添加版本
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                    Text("该文件夹还没有版本实例")
                        .font(.custom("PCL English", size: 16))
                        .foregroundStyle(Color("TextColor"))
                    Text("前往 \"下载\" 页面安装，或将现有版本文件夹拖入此窗口。")
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let notVanillaVersions = minecraftDirectory.instances.filter { $0.brand != .vanilla }
                    if !notVanillaVersions.isEmpty {
                        MyCard(index: 0, title: "可安装 Mod") {
                            LazyVStack {
                                ForEach(
                                    notVanillaVersions
                                        .sorted(by: { $0.version > $1.version })
                                        .sorted(by: { $0.brand.index < $1.brand.index })
                                ) { instanceInfo in
                                    VersionView(instanceInfo: instanceInfo)
                                }
                            }
                            .padding(.top, 12)
                        }
                        .padding()
                    }
                    
                    MyCard(index: 1, title: "常规版本") {
                        LazyVStack {
                            ForEach(
                                minecraftDirectory.instances
                                    .filter { $0.brand == .vanilla }
                                    .sorted(by: { $0.version > $1.version })
                            ) { info in
                                VersionView(instanceInfo: info)
                            }
                        }
                        .padding(.top, 12)
                    }
                    .padding()
                    .padding(.bottom, 25)
                }
                .scrollIndicators(.never)
            }
        }
        .id(minecraftDirectory)
        .onChange(of: minecraftDirectory) { loadInstances(minecraftDirectory) }
        .onAppear { loadInstances(minecraftDirectory) }
    }
    
    private func loadInstances(_ directory: MinecraftDirectory) {
        AppSettings.shared.currentMinecraftDirectory = directory
        if directory.instances.isEmpty {
            directory.loadInnerInstances()
        }
    }
}


class VersionDropDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.folder])
    }
    
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.folder])
        for provider in providers {
            provider.loadItem(forTypeIdentifier: provider.registeredTypeIdentifiers[0], options: nil) { item, error in
                if let error = error {
                    err(error.localizedDescription)
                }
                
                if let url = item as? URL, url.hasDirectoryPath {
                    guard FileManager.default.fileExists(atPath: url.appending(path: "\(url.lastPathComponent).json").path) else {
                        hint("请拖入正确的 Minecraft 版本文件夹！", .critical)
                        return
                    }
                    
                    hint("正在导入实例 \(url.lastPathComponent)……")
                    Task {
                        let dest = URL(fileURLWithUserPath: "~/PCL-Mac-minecraft/versions/\(url.lastPathComponent)")
                        if FileManager.default.fileExists(atPath: dest.path) {
                            hint("已存在同名实例！", .critical)
                            return
                        }
                        do {
                            try FileManager.default.copyItem(at: url, to: dest)
                            AppSettings.shared.defaultInstance = url.lastPathComponent
                            hint("导入成功！", .finish)
                        } catch {
                            err("无法复制实例: \(error.localizedDescription)")
                            hint("无法复制实例: \(error.localizedDescription)", .critical)
                        }
                    }
                }
            }
            return true
        }
        return false
    }
}
