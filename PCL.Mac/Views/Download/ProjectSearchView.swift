//
//  ModDownloadView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/20.
//

import SwiftUI

fileprivate struct ImageAndTextComponent: View {
    let imageName: String
    let text: String
    
    var body: some View {
        HStack {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 16)
            Text(text)
                .font(.custom("PCL English", size: 12))
        }
    }
}

struct ProjectListItem: View {
    public static let tagMap: [String: String] = ["technology":"科技","magic":"魔法","adventure":"冒险","utility":"实用","optimization":"性能优化","vanilla-like":"原版风","realistic":"写实风","worldgen":"世界元素","food":"食物/烹饪","game-mechanics":"游戏机制","transportation":"运输","storage":"仓储","decoration":"装饰","mobs":"生物","equipment":"装备","social":"服务器","library":"支持库","multiplayer":"多人","challenging":"硬核","combat":"战斗","quests":"任务","kitchen-sink":"水槽包","lightweight":"轻量","simplistic":"简洁","tweaks":"改良","8x-":"极简","16x":"16x","32x":"32x","48x":"48x","64x":"64x","128x":"128x","256x":"256x","512x+":"超高清","audio":"含声音","fonts":"含字体","models":"含模型","gui":"含 UI","locale":"含语言","core-shaders":"核心着色器","modded":"兼容 Mod","fantasy":"幻想风","semi-realistic":"半写实风","cartoon":"卡通风","colored-lighting":"彩色光照","path-tracing":"路径追踪","pbr":"PBR","reflections":"反射","iris":"Iris","optifine":"OptiFine","vanilla":"原版可用"]
    
    /// 共享的相对时间格式化器。原来每个搜索结果行的 init 都新建一个，
    /// RelativeDateTimeFormatter 的初始化并不便宜。
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    @State private var isHovered: Bool = false
    @State private var isAdding: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lastUpdateLabel: String
    private let downloadCountLabel: String
    private let summary: ProjectSummary
    private let displayTags: [String]
    private let hiddenTagCount: Int
    /// 支持版本描述在 init 里算一次。它内部要按 id 查版本清单，
    /// 放在 body 里会随每次重渲染反复执行。
    private let supportDescription: String

    /// 故意不是 @ObservedObject：这一行的外观并不依赖下载队列内容，
    /// 订阅它会让队列每次变化都重画整份搜索结果。
    @MainActor private var state: ProjectSearchViewState { StateManager.shared.projectSearch }

    init(summary: ProjectSummary) {
        self.summary = summary
        self.lastUpdateLabel = ProjectListItem.relativeFormatter
            .localizedString(for: summary.lastUpdate, relativeTo: Date())
            .replacingOccurrences(of: "(\\d+)", with: " $1 ", options: .regularExpression)
        self.downloadCountLabel = ProjectListItem.formatNumber(summary.downloadCount)
        self.supportDescription = ProjectListItem.makeSupportDescription(summary)
        let tags = summary.tags.compactMap { ProjectListItem.tagMap[$0] }
        self.displayTags = Array(tags.prefix(3))
        self.hiddenTagCount = max(0, tags.count - 3)
    }
    
    var body: some View {
        MyListItem {
            HStack(spacing: 8) {
                Button(action: openDetails) {
                    HStack(spacing: 12) {
                        ProjectIconView(projectId: summary.projectId, iconURL: summary.iconURL, size: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(summary.name)
                                .font(.custom("PCL English", size: 16))
                                .foregroundStyle(Color("TextColor"))
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                ForEach(displayTags, id: \.self) { tag in
                                    MyTag(label: tag, backgroundColor: Color("TagColor"), fontSize: 12)
                                }
                                if hiddenTagCount > 0 {
                                    Text("+\(hiddenTagCount)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help("还有 \(hiddenTagCount) 个标签")
                                }

                                Text(summary.description)
                                    .font(.custom("PCL English", size: 14))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(-1)
                            }
                            .foregroundStyle(Color(hex: 0x8C8C8C))

                            HStack(spacing: 18) {
                                if !supportDescription.isEmpty {
                                    ImageAndTextComponent(
                                        imageName: "SettingsIcon",
                                        text: supportDescription
                                    )
                                }
                                ImageAndTextComponent(
                                    imageName: "DownloadIcon",
                                    text: downloadCountLabel
                                )
                                ImageAndTextComponent(
                                    imageName: "UploadIcon",
                                    text: lastUpdateLabel
                                )
                                Spacer(minLength: 0)
                            }
                            .lineLimit(1)
                            .foregroundStyle(Color(hex: 0x8C8C8C))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summary.name)
                .accessibilityHint("打开项目详情")

                Button(action: addToQueue) {
                    ZStack {
                        if isAdding {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color(hex: 0x8C8C8C))
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(isAdding)
                .opacity(isHovered || isAdding ? 1 : 0.58)
                .help("添加 \(summary.name) 到下载队列")
                .accessibilityLabel("添加 \(summary.name) 到下载队列")
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: isHovered)
                .padding(.trailing, 6)
            }
            .padding(.vertical, 6)
            .padding(.leading, 4)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered in
            self.isHovered = isHovered
        }
    }

    private func openDetails() {
        DataManager.shared.router.append(.projectDownload(summary: summary))
    }
    
    /// 加入下载队列。整个过程要发网络请求，期间在按钮位置显示转圈并防止重复点击。
    private func addToQueue() {
        guard !isAdding else { return }
        isAdding = true
        Task {
            defer { isAdding = false }

            if state.pendingDownloadProjects.contains(where: { $0.projectId == summary.projectId }) {
                hint("\(summary.name) 已在下载队列中", .critical)
                return
            }

            if summary.type == .modpack {
                if let version = try? await ModrinthProjectSearcher.shared.getVersion(summary.versions?.first ?? "") {
                    state.addToQueue(version)
                } else {
                    hint("未找到 \(summary.name) 可用的版本！", .critical)
                }
                return
            }

            guard let instance = DataManager.shared.defaultInstance else {
                hint("请先选择一个实例！", .critical)
                return
            }
            if let versionMap = try? await ModrinthProjectSearcher.shared.getVersionMap(id: summary.modId),
               let versions = versionMap[.init(loader: instance.clientBrand, minecraftVersion: instance.version)],
               let version = versions.first {
                state.addToQueue(version)
            } else {
                hint("\(summary.name) 没有适配 \(instance.name) 的版本", .critical)
            }
        }
    }

    /// 生成「仅 Fabric 1.20~1.21」这类支持范围描述。
    ///
    /// 只在 init 里调用一次。注意 `MinecraftVersion(displayName:)` 会去版本清单里
    /// 按 id 查类型，所以这段逻辑对每个受支持版本都有一次查表成本 —— 别放回 body。
    private static func makeSupportDescription(_ summary: ProjectSummary) -> String {
        var supportDescription = ""
        if summary.loaders.count == 1 {
            supportDescription.append("仅 \(summary.loaders.first!.getName())")
        } else if summary.loaders.count < 3 {
            supportDescription.append(summary.loaders.map { $0.rawValue.capitalized }.joined(separator: " / "))
        }

        if !supportDescription.isEmpty { supportDescription.append(" ") }

        var supportedVersions = summary.gameVersions.map { $0.displayName }
        supportedVersions.removeAll(where: { $0.starts(with: "3D-Shareware") }) // 笑点解析: 3D-Shareware-v1.34 识别成 1.34

        var minorVersions: Set<Int> = []
        for name in supportedVersions {
            guard MinecraftVersion(displayName: name).type == .release else { continue }
            let components = name.split(separator: ".")
            guard components.count > 1, let minor = Int(components[1]) else { continue }
            minorVersions.insert(minor)
        }

        // 清单可能还没加载完，此时不给出「全版本」这类依赖最新版号的结论。
        let highest: Int
        if let latestRelease = DataManager.shared.versionManifest?.latest.release,
           let parsed = Int(latestRelease.split(separator: ".").dropFirst().first ?? "") {
            highest = parsed
        } else {
            highest = -1
        }

        supportDescription.append(
            describeGameVersions(
                gameVersions: minorVersions.sorted(by: >),
                mcVersionHighest: highest
            )
        )
        return supportDescription
    }
    
    private static func describeGameVersions(gameVersions: [Int]?, mcVersionHighest: Int) -> String {
        guard let gameVersions = gameVersions, !gameVersions.isEmpty else {
            return "仅快照版本"
        }
        
        var spaVersions: [String] = []
        var isOld = false
        var i = 0
        let count = gameVersions.count
        
        while i < count {
            let startVersion = gameVersions[i]
            var endVersion = startVersion
            
            if startVersion < 10 {
                if !spaVersions.isEmpty && !isOld {
                    break
                } else {
                    isOld = true
                }
            }
            
            var ii = i + 1
            while ii < count && gameVersions[ii] == endVersion - 1 {
                endVersion = gameVersions[ii]
                i = ii
                ii += 1
            }
            
            if startVersion == endVersion {
                spaVersions.append("1.\(startVersion)")
            } else if mcVersionHighest > -1 && startVersion >= mcVersionHighest {
                if endVersion < 10 {
                    spaVersions.removeAll()
                    spaVersions.append("全版本")
                    break
                } else {
                    spaVersions.append("1.\(endVersion)+")
                }
            } else if endVersion < 10 {
                spaVersions.append("1.\(startVersion)-")
                break
            } else if startVersion - endVersion == 1 {
                spaVersions.append("1.\(startVersion), 1.\(endVersion)")
            } else {
                spaVersions.append("1.\(startVersion)~1.\(endVersion)")
            }
            
            i += 1
        }
        
        return spaVersions.joined(separator: ", ")
    }
    
    private static func formatNumber(_ num: Int) -> String {
        let absNum = abs(num)
        let sign = num < 0 ? "-" : ""
        let numDouble = Double(absNum)
        
        if absNum >= 100_000_000 {
            let value = numDouble / 100_000_000
            return String(format: "%@%.2f 亿", sign, value)
        } else if absNum >= 10_000 {
            let value = numDouble / 10_000
            return String(format: "%@%.0f 万", sign, value)
        } else {
            return "\(num)"
        }
    }
}

@MainActor
class ProjectSearchViewState: ObservableObject {
    @Published var query: String = ""
    @Published var summaries: [ProjectSummary]?
    @Published var error: Error?
    @Published var pendingDownloadProjects: [ProjectVersion] = []
    @Published var projectQueueOverlayId: UUID?
    @Published var lastProjectType: ProjectType = .mod
    
    public func addToQueue(_ version: ProjectVersion) {
        Task {
            var dependencies = Set<ProjectVersion>(pendingDownloadProjects)
            if !dependencies.insert(version).inserted {
                hint("\(version.name) 已存在！", .critical)
                return
            }
            dependencies.removeAll()

            if version.projectType == .modpack {
                pendingDownloadProjects.append(version)
                hint("已将 \(version.name) 添加至整合包下载队列！", .finish)
                return
            }
            
            guard let instance = DataManager.shared.defaultInstance else {
                hint("请先选择一个实例！", .critical)
                return
            }
            for dependency in version.dependencies {
                if dependency.versionId == nil {
                    if let versionMap = try? await ModrinthProjectSearcher.shared.getVersionMap(id: dependency.summary.modId),
                       let versions = versionMap[.init(loader: instance.clientBrand, minecraftVersion: instance.version)],
                       let firstVersion = versions.first {
                        pendingDownloadProjects.append(firstVersion)
                    } else {
                        err("依赖不存在: \(dependency.summary.modId)")
                        continue
                    }
                } else {
                    if let version = try? await ModrinthProjectSearcher.shared.getVersion(dependency.versionId!) {
                        pendingDownloadProjects.append(version)
                    } else {
                        err("依赖 \(dependency.summary.modId) 版本 \(dependency.versionId!) 不存在")
                        continue
                    }
                }
            }
            pendingDownloadProjects = pendingDownloadProjects.filter { dependencies.insert($0).inserted }
            pendingDownloadProjects.append(version)
            hint("已将 \(version.name) 添加至资源下载队列！", .finish)
        }
    }
}

struct ProjectSearchView: View {
    @ObservedObject var state: ProjectSearchViewState = StateManager.shared.projectSearch
    @State private var isSearching: Bool = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private let projectType: ProjectType

    init(type: ProjectType) {
        self.projectType = type
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MySearchBox(
                    query: $state.query,
                    placeholder: "搜索\(projectType.getName())，按 Enter 开始搜索（⌘F 聚焦）",
                    autoFocus: true
                ) { _ in
                    searchProjects()
                }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在搜索")
                        .accessibilityLabel("正在搜索")
                }
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            if isSearching && state.summaries != nil {
                ProgressView()
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                    .accessibilityLabel("正在更新搜索结果")
            }

            ScrollView {
                resultsContent
            }
            .scrollIndicators(.automatic)
        }
        .onAppear {
            if state.lastProjectType != projectType {
                state.summaries = nil
            }
            if state.summaries == nil {
                state.lastProjectType = projectType
                searchProjects()
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if isSearching && state.summaries == nil {
            VStack(spacing: 10) {
                ProgressView().scaleEffect(0.8)
                Text("正在搜索……")
                    .font(.custom("PCL English", size: 14))
                    .foregroundStyle(Color(hex: 0x8C8C8C))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if let message = errorMessage, state.summaries == nil {
            searchError(message, prominent: true)
        } else if let summaries = state.summaries {
            if let message = errorMessage {
                searchError(message, prominent: false)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if summaries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                    Text("没有找到匹配的\(projectType.getName())")
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(Color("TextColor"))
                    Text("试试更短的关键词，或换个说法。")
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                TitlelessMyCard {
                    LazyVStack(spacing: 0) {
                        ForEach(summaries) { summary in
                            ProjectListItem(summary: summary)
                        }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func searchError(_ message: String, prominent: Bool) -> some View {
        if prominent {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(Color(hex: 0xF50000))
                Text("搜索失败")
                    .font(.custom("PCL English", size: 16))
                    .foregroundStyle(Color("TextColor"))
                Text(message)
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x8C8C8C))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                MyButton(text: "重试") { searchProjects() }
                    .frame(width: 110, height: 30)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(Color(hex: 0xF50000))
                Text("更新失败，仍显示上次结果：\(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("重试") { searchProjects() }
                    .buttonStyle(.link)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func searchProjects() {
        // 取消上一次仍在飞的搜索：快速连按 Enter 时旧结果可能后到并覆盖新结果。
        searchTask?.cancel()
        errorMessage = nil
        state.error = nil
        isSearching = true
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            defer { isSearching = false }
            do {
                let result = try await ModrinthProjectSearcher.shared.search(
                    type: projectType,
                    query: query
                )
                guard !Task.isCancelled else { return }
                state.summaries = result
            } catch {
                guard !Task.isCancelled else { return }
                state.error = error
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ProjectQueueOverlay: View {
    @ObservedObject private var router = DataManager.shared.router
    @ObservedObject private var state: ProjectSearchViewState = StateManager.shared.projectSearch
    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        if !state.pendingDownloadProjects.isEmpty && router.path.contains(where: { route in
            if case .projectSearch(_) = route {
                return true
            }
            return false
        }) {
            VStack {
                Spacer()
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(state.pendingDownloadProjects, id: \.id) { version in
                                Button {
                                    state.pendingDownloadProjects.removeAll(where: { $0.id == version.id })
                                    hint("已移除 \(version.name)！", .finish)
                                } label: {
                                    ProjectIconView(
                                        projectId: version.projectId,
                                        iconURL: nil,
                                        size: 32,
                                        cornerRadius: 4
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("移除 \(version.name)")
                                .accessibilityLabel("从下载队列移除 \(version.name)")
                            }
                        }
                    }
                    .frame(maxWidth: 360)

                    Divider()
                        .frame(height: 24)

                    MyButton(text: "清空") {
                        state.pendingDownloadProjects.removeAll()
                        hint("已清空资源下载队列！", .finish)
                    }
                    .fixedSize()
                    MyButton(text: "开始", foregroundStyle: AppSettings.shared.theme.getTextStyle()) {
                        let modpacks = state.pendingDownloadProjects.filter { $0.projectType == .modpack }
                        if !modpacks.isEmpty {
                            Task {
                                await installModpacks(modpacks)
                            }
                            return
                        }
                        guard let instance = DataManager.shared.defaultInstance else {
                            hint("请先在版本列表中选择一个实例！", .critical)
                            return
                        }
                        let versions = state.pendingDownloadProjects
                        let task = ResourceInstallTask(instance: instance, versions: versions)
                        task.onComplete {
                            hint("下载完成！", .finish)
                            state.pendingDownloadProjects.removeAll()
                        }
                        DataManager.shared.inprogressInstallTasks = .single(task)
                        task.start()
                        if let id = state.projectQueueOverlayId {
                            OverlayManager.shared.removeOverlay(with: id)
                            state.projectQueueOverlayId = nil
                        }
                        hint("开始下载 \(state.pendingDownloadProjects.count) 个资源……")
                    }
                    .fixedSize()
                }
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color("MyCardBackgroundColor"))
                        .shadow(color: isHovered ? Color(hex: 0x0B5BCB) : .gray, radius: 2, x: 0.5, y: 0.5)
                }
                .onHover { isHover in
                    self.isHovered = isHover
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.pendingDownloadProjects)
        }
    }

    private func installModpacks(_ versions: [ProjectVersion]) async {
        guard let directory = AppSettings.shared.currentMinecraftDirectory else {
            hint("请先选择 Minecraft 文件夹！", .critical)
            return
        }

        hint("开始导入 \(versions.count) 个整合包……")
        for version in versions {
            do {
                let tempURL = SharedConstants.shared.temperatureURL.appending(path: "\(UUID().uuidString)-\(version.downloadURL.lastPathComponent)")
                try await SingleFileDownloader.download(url: version.downloadURL, destination: tempURL, replaceMethod: .replace, networkCategory: .gameDownload)
                _ = try await ModpackImporter.install(zipURL: tempURL, into: directory, instanceName: version.name)
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                err("整合包 \(version.name) 导入失败：\(error.localizedDescription)")
                hint("\(version.name) 导入失败（详见日志）", .critical)
                return
            }
        }

        await MainActor.run {
            let installedIds = Set(versions.map(\.id))
            state.pendingDownloadProjects.removeAll { installedIds.contains($0.id) }
        }
        directory.loadInnerInstances()
        hint("整合包导入完成！", .finish)
    }
}
