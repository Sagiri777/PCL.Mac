//
//  JavaSettingsView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/21.
//

import SwiftUI

struct JavaSettingsView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    @State private var isSearching: Bool = false

    var body: some View {
        ScrollView {
            TitlelessMyCard {
                HStack {
                    MyButton(text: isSearching ? "正在搜索……" : "刷新 Java 列表") {
                        refreshJavaList()
                    }
                    .frame(height: 35)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isSearching)
                    .opacity(isSearching ? 0.6 : 1)
                    MyButton(text: "手动添加 Java") {
                        addJavaManually()
                    }
                    .frame(height: 35)
                    .fixedSize(horizontal: true, vertical: false)
                    MyButton(text: "安装 Java") {
                        dataManager.router.append(.javaDownload)
                    }
                    .frame(height: 35)
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                }
            }
            .padding()

            TitlelessMyCard(index: 1) {
                VStack(spacing: 0) {
                    HStack {
                        Text(searchStatusText)
                            .font(.custom("PCL English", size: 14))
                            .foregroundStyle(Color(hex: 0x8C8C8C))
                        Spacer()
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                    if dataManager.javaVirtualMachines.isEmpty {
                        emptyState
                    } else {
                        // 列表可能有十几项，用 LazyVStack 只渲染可见行。
                        LazyVStack(spacing: 0) {
                            ForEach(dataManager.javaVirtualMachines) { javaEntity in
                                JavaListItemView(jvm: javaEntity)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: dataManager.javaVirtualMachines)
                    }
                }
                .padding()
            }
            .padding()
            .padding(.bottom, 30)
            .foregroundStyle(Color("TextColor"))
        }
        .scrollIndicators(.never)
        .task {
            // 启动时 Java 搜索是后台进行的；进入本页若列表还空着就补一次。
            if dataManager.javaVirtualMachines.isEmpty && !isSearching {
                refreshJavaList()
            }
        }
    }

    private var searchStatusText: String {
        if isSearching { return "正在搜索本机 Java……" }
        if dataManager.lastTimeUsed > 0 {
            return "共 \(dataManager.javaVirtualMachines.count) 项，搜索耗时 \(dataManager.lastTimeUsed)ms"
        }
        return "共 \(dataManager.javaVirtualMachines.count) 项"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isSearching ? "hourglass" : "cup.and.saucer")
                .font(.system(size: 32))
                .foregroundStyle(Color(hex: 0x8C8C8C))
            Text(isSearching ? "正在搜索……" : "没有找到已安装的 Java")
                .font(.custom("PCL English", size: 14))
                .foregroundStyle(Color("TextColor"))
            if !isSearching {
                Text("点击“安装 Java”可以直接下载一个，或用“手动添加 Java”指定 java 可执行文件。")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x8C8C8C))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func refreshJavaList() {
        guard !isSearching else { return }
        isSearching = true
        Task {
            await JavaSearch.searchAndSet()
            isSearching = false
        }
    }

    /// 手动添加：`JavaVirtualMachine.of` 可能 spawn `java -version`，放到后台再回主线程写列表。
    private func addJavaManually() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "请选择 Java 的可执行文件（通常位于 .../Contents/Home/bin/java）"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == "java" else {
            hint("请选择名为 java 的可执行文件", .critical)
            err("无法手动添加 Java: 可执行文件不正确")
            return
        }
        guard !dataManager.javaVirtualMachines.contains(where: { $0.executableURL == url }) else {
            hint("这个 Java 已经在列表里了", .critical)
            return
        }

        Task {
            let jvm = await Task.detached(priority: .userInitiated) {
                JavaVirtualMachine.of(url, true)
            }.value
            guard !jvm.isError else {
                hint("无法识别该 Java", .critical)
                err("发生错误，无法手动添加 Java")
                return
            }
            AppSettings.shared.userAddedJvmPaths.append(url)
            dataManager.javaVirtualMachines.append(jvm)
            hint("已添加 \(jvm.getTypeLabel()) \(jvm.displayVersion)", .finish)
        }
    }
}
