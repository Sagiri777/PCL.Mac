//
//  ProjectDownloadView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/20.
//

import SwiftUI

// 别问为什么抽出来，问就是 The compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
fileprivate struct ProjectVersionListView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    @ObservedObject private var state: ProjectSearchViewState = StateManager.shared.projectSearch
    @State private var requestID = UUID()
    @State private var versionMap: ProjectVersionMap = [:]
    @State private var loadError: String?


    let summary: ProjectSummary
    let versions: [String]
    
    var body: some View {
        VStack {
            ForEach(versionMap.platformKeys, id: \.self) { key in
                if let versions = versionMap[key] {
                    MyCard(title: getCardTitle(key.loader, key.minecraftVersion)) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let version = versions.first,
                               !version.dependencies.isEmpty {
                                Text("前置资源")
                                    .font(.custom("PCL English", size: 14))
                                    .padding(4)
                                ForEach(version.dependencies, id: \.self) { dependency in
                                    ProjectListItem(summary: dependency.summary)
                                }
                                Text("版本列表")
                                    .font(.custom("PCL English", size: 14))
                                    .padding(4)
                            }
                            ForEach(versions) { version in
                                Button {
                                    state.addToQueue(version)
                                } label: {
                                    ProjectVersionListItem(version: version)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("下载 \(version.name)，\(version.versionNumber)")
                            }
                        }
                        .padding(4)
                    }
                    .padding()
                }
            }
        }
        .task(id: requestID) {
            do {
                let map = try await ModrinthProjectSearcher.shared.getVersionMap(id: summary.modId)
                self.versionMap = map
            } catch {
                err("无法加载版本列表: \(error.localizedDescription)")
                loadError = error.localizedDescription
            }
        }
        .overlay {
            if versionMap.isEmpty {
                if let loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color(hex: 0xF50000))
                        Text("无法加载版本列表")
                            .font(.custom("PCL English", size: 14))
                            .foregroundStyle(Color("TextColor"))
                        Text(loadError)
                            .font(.custom("PCL English", size: 12))
                            .foregroundStyle(Color(hex: 0x8C8C8C))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        MyButton(text: "重试") {
                            self.loadError = nil
                            requestID = UUID()
                        }
                        .frame(width: 110, height: 30)
                    }
                    .padding(.vertical, 30)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.vertical, 30)
                }
            }
        }
    }
    
    private func getCardTitle(_ loader: ClientBrand, _ version: MinecraftVersion) -> String {
        if loader == .vanilla { return version.displayName }
        return loader.getName() + " " + version.displayName
    }
}

fileprivate struct ProjectVersionListItem: View {
    let version: ProjectVersion
    /// 描述在 init 里算好：原来放在 body 里，每次重渲染都要新建一个
    /// RelativeDateTimeFormatter 并跑一次正则替换。
    private let description: String

    init(version: ProjectVersion) {
        self.version = version
        self.description = ProjectVersionListItem.makeDescription(version)
    }

    var body: some View {
        MyListItem {
            HStack {
                Image(version.type.capitalized + "Icon")
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading) {
                    Text(version.name)
                        .font(.custom("PCL English", size: 14))
                    Text(description)
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                }
                Spacer()
            }
            .padding(4)
        }
    }

    private static func makeDescription(_ version: ProjectVersion) -> String {
        let result = ProjectListItem.relativeFormatter
            .localizedString(for: version.updateDate, relativeTo: Date())
            .replacingOccurrences(of: "(\\d+)", with: " $1 ", options: .regularExpression)
        let typeText = switch version.type {
        case "release":
            "正式版"
        case "beta", "alpha":
            "测试版"
        default:
            "未知"
        }
        return "\(version.versionNumber)，更新于\(result)，\(typeText)"
    }
}

struct ProjectDownloadView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    @ObservedObject private var state: ProjectSearchViewState = StateManager.shared.projectSearch
    @State private var summary: ProjectSummary?
    let id: String
    
    init(id: String) {
        self.id = id
    }
    
    var body: some View {
        Group {
            if let summary = summary {
                ScrollView {
                    TitlelessMyCard {
                        VStack {
                            ProjectListItem(summary: summary)
                            HStack(spacing: 25) {
                                MyButton(text: "转到 Modrinth", foregroundStyle: AppSettings.shared.theme.getTextStyle()) {
                                    NSWorkspace.shared.open(summary.infoURL)
                                }
                                .frame(width: 160, height: 40)
                                
                                MyButton(text: "复制名称") {
                                    NSPasteboard.general.setString(summary.name, forType: .string)
                                }
                                .frame(width: 160, height: 40)
                                Spacer()
                            }
                        }
                        .padding(10)
                    }
                    .padding()
                    if let versions = summary.versions {
                        ProjectVersionListView(summary: summary, versions: versions)
                    }
                }
                .scrollIndicators(.never)
            } else {
                // 之前这里是个空 Spacer：网络慢时页面完全空白，看不出在加载。
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在加载资源信息……")
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(id)
        .onAppear {
            dataManager.leftTab(0) { EmptyView() }
        }
        .task(id: id) {
            summary = nil
            summary = try? await ModrinthProjectSearcher.shared.get(id)
        }
    }
}
