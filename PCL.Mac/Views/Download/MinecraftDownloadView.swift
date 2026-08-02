//
//  MinecraftDownloadView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/20.
//

import SwiftUI
import SwiftyJSON

fileprivate struct VersionView: View, Identifiable {
    let name: String
    let description: String
    let icon: String
    let parent: MinecraftDownloadView
    let version: VersionManifest.GameVersion

    /// 用版本 id 作标识，而不是每次构造随机 UUID（后者让 ForEach 身份不稳定）。
    var id: String { version.id }


    init(version: VersionManifest.GameVersion, isLatest: Bool = false, parent: MinecraftDownloadView) {
        self.name = version.id
        
        var description = SharedConstants.shared.dateFormatter.string(from: version.releaseTime)
        if isLatest {
            description = "最新\(version.type == .release ? "正式" : "预览")版，发布于 " + description
        } else if version.type == .aprilFool {
            description = VersionManifest.getAprilFoolDescription(version.id)
        }
        self.description = description
        
        self.icon = version.parse().getIconName()
        self.parent = parent
        self.version = version
    }
    
    var body: some View {
        MyListItem {
            HStack {
                Image(self.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 35)
                    .padding(.leading, 5)
                VStack(alignment: .leading) {
                    Text(self.name)
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(Color("TextColor"))
                        .padding(.top, 5)
                    Text(self.description)
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(Color(hex: 0x7F8790))
                        .padding(.bottom, 5)
                }
                Spacer()
            }
        }
        .padding(.top, -8)
        .onTapGesture {
            self.parent.onVersionClicked(version)
        }
    }
}

struct MinecraftDownloadView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    
    /// 按类别分好的版本。nil 表示版本清单还没就绪。
    @State private var categories: VersionCategories? = nil
    @State private var currentDownloadPage: DownloadPage?

    /// 分类后的版本集合。用具名结构体而不是 [String: [...]]，避免调用点到处强解包。
    fileprivate struct VersionCategories {
        let release: [VersionManifest.GameVersion]
        let snapshot: [VersionManifest.GameVersion]
        let old: [VersionManifest.GameVersion]
        let aprilFool: [VersionManifest.GameVersion]
        let latestRelease: VersionManifest.GameVersion?
        let latestSnapshot: VersionManifest.GameVersion?
    }

    var body: some View {
        HStack {
            if let currentDownloadPage = self.currentDownloadPage {
                currentDownloadPage
                    .zIndex(0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let categories {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack {
                        if categories.latestRelease != nil || categories.latestSnapshot != nil {
                            StaticMyCard(index: 0, title: "最新版本") {
                                VStack {
                                    if let latest = categories.latestRelease {
                                        VersionView(version: latest, isLatest: true, parent: self)
                                    }
                                    if let latest = categories.latestSnapshot {
                                        VersionView(version: latest, isLatest: true, parent: self)
                                    }
                                }
                                .padding(.top, 12)
                            }
                            .padding()
                        }

                        CategoryCard(index: 1, label: "正式版", versions: categories.release, parent: self)
                        CategoryCard(index: 2, label: "预览版", versions: categories.snapshot, parent: self)
                        // 远古版与愚人节版默认折叠：版本数量大（数百），初始不渲染可显著减少首次 layout pass。
                        CategoryCard(index: 3, label: "远古版", versions: categories.old, parent: self, startCollapsed: true)
                        CategoryCard(index: 4, label: "愚人节版", versions: categories.aprilFool, parent: self, startCollapsed: true)
                        Spacer()
                    }
                    .padding(.bottom, 20)
                }
                .zIndex(0)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .scrollIndicators(.never)
            } else {
                // 版本清单可能还在后台拉取（启动不再为它同步阻塞）。
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在获取版本列表……")
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentDownloadPage == nil)
        // 依赖清单对象本身：清单从缓存换成新拉取的版本时自动重新分类。
        .task(id: ObjectIdentifier(dataManager.versionManifest ?? emptyManifestSentinel)) {
            categories = Self.categorize(dataManager.versionManifest)
        }
    }

    /// `task(id:)` 需要一个稳定的非空值；清单为 nil 时用这个哨兵。
    private var emptyManifestSentinel: VersionManifest { Self.sentinel }
    private static let sentinel = VersionManifest(JSON())

    private static func categorize(_ manifest: VersionManifest?) -> VersionCategories? {
        guard let manifest, !manifest.versions.isEmpty else { return nil }

        // 一次遍历完成分类，替代原来对上千条版本的 4 次 filter。
        var release: [VersionManifest.GameVersion] = []
        var snapshot: [VersionManifest.GameVersion] = []
        var old: [VersionManifest.GameVersion] = []
        var aprilFool: [VersionManifest.GameVersion] = []

        for version in manifest.versions {
            switch version.type {
            case .release: release.append(version)
            case .snapshot, .pending: snapshot.append(version)
            case .beta, .alpha: old.append(version)
            case .aprilFool: aprilFool.append(version)
            default: break
            }
        }

        return VersionCategories(
            release: release,
            snapshot: snapshot,
            old: old,
            aprilFool: aprilFool,
            // 用可选查找：清单里偶尔会缺 latest 指向的条目（旧的 find! 会直接崩）。
            latestRelease: manifest.version(id: manifest.latest.release),
            latestSnapshot: manifest.version(id: manifest.latest.snapshot)
        )
    }
    
    func onVersionClicked(_ version: VersionManifest.GameVersion) {
        let version = version.parse()
        self.currentDownloadPage = DownloadPage(version) {
            self.currentDownloadPage = nil
        }
    }
}

fileprivate struct CategoryCard: View {
    let index: Int
    let label: String
    let versions: [VersionManifest.GameVersion]
    let parent: MinecraftDownloadView
    /// 是否初始折叠。远古/愚人节版本数量大，进入下载页时不展开可显著减少首次 layout 成本。
    var startCollapsed: Bool = false

    var body: some View {
        MyCard(index: index,
               title: "\(label) (\(versions.count))",
               unfoldBinding: .constant(!startCollapsed)) {
            LazyVStack {
                ForEach(versions, id: \.id) { version in
                    VersionView(version: version, parent: parent)
                }
            }
            .padding(.top, 12)
        }
        .cardId(label)
        .padding()
    }
}
