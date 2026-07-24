//
//  InstanceModsView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/7/31.
//

import SwiftUI
import ZIPFoundation
import SwiftyJSON

fileprivate struct ModItem: Identifiable {
    let id: UUID = .init()
    let mod: Mod
    let url: URL
}

private final class ModpackImportListItem: ObservableObject, Identifiable {
    let id: UUID = .init()
    let sourceName: String
    @Published var packName: String
    @Published var status: String = "正在导入 / 解决依赖"
    @Published var progress: Double = 0
    @Published var finishedFiles: Int = 0
    @Published var totalFiles: Int = 0
    @Published var isFailed: Bool = false

    init(sourceName: String) {
        self.sourceName = sourceName
        self.packName = sourceName
    }

    func apply(_ update: ModpackImportProgressUpdate) {
        packName = update.packName.isEmpty ? sourceName : update.packName
        status = update.status
        progress = min(max(update.progress, 0), 1)
        finishedFiles = update.finishedFiles
        totalFiles = update.totalFiles
        isFailed = false
    }

    func fail(_ message: String) {
        status = message
        isFailed = true
    }
}

struct InstanceModsView: View {
    @ObservedObject private var dataManager: DataManager = .shared
    @State private var searchQuery: String = ""
    @State private var mods: [ModItem]? = nil
    @State private var error: Error?
    @State private var filter: (Mod) -> Bool = { _ in true }
    @State private var importRows: [ModpackImportListItem] = []

    /// Drop 进入/离开时的视觉反馈。
    @State private var isDropHovering: Bool = false

    /// 任务标记；安装完 mod 后置新值触发 .task 重新加载列表。
    /// 用 @State 让 installDropped 之后能 invalidate。
    @State private var taskID: UUID = .init()

    let instance: MinecraftInstance
    
    var body: some View {
        if instance.clientBrand == .vanilla {
            VStack {
                TitlelessMyCard {
                    VStack {
                        Text("该实例不可使用 Mod")
                            .font(.custom("PCL English", size: 22))
                            .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                        Rectangle()
                            .fill(AppSettings.shared.theme.getTextStyle())
                            .frame(height: 2)
                        VStack(alignment: .leading) {
                            Text("你需要先安装 Forge、Fabric 等 Mod 加载器才能使用 Mod，请在下载页面安装这些实例。")
                            Text("如果你已经安装过了 Mod 加载器，那么你很可能选择了错误的实例，请点击实例选择按钮切换实例。")
                        }
                        .font(.custom("PCL English", size: 14))
                        .foregroundStyle(Color("TextColor"))
                        .padding(4)
                        
                        HStack(spacing: 24) {
                            MyButton(text: "转到下载页面", foregroundStyle: AppSettings.shared.theme.getTextStyle()) {
                                dataManager.router.setRoot(.download)
                                dataManager.router.append(.minecraftDownload)
                            }
                            .frame(width: 170, height: 40)
                            
                            MyButton(text: "实例选择") {
                                dataManager.router.setRoot(.versionSelect)
                            }
                            .frame(width: 170, height: 40)
                        }
                    }
                    .padding(4)
                }
                .padding(40)
            }
            .frame(maxWidth: .infinity)
        } else {
            ZStack {
                ScrollView {
                    MySearchBox(query: $searchQuery, placeholder: "搜索资源 名称 / 描述") { query in
                        filter = { query.isEmpty || $0.name.contains(query) || $0.description.contains(query) }
                    }
                    .padding()

                    TitlelessMyCard(index: 1) {
                        HStack(spacing: 16) {
                            MyButton(text: "打开文件夹", foregroundStyle: AppSettings.shared.theme.getTextStyle()) {
                                Util.openInFinder(instance.runningDirectory.appending(path: "mods"), createIfMissing: true)
                            }
                            .frame(width: 120, height: 35)
                            MyButton(text: "下载新资源") {
                                dataManager.router.setRoot(.download)
                                dataManager.router.append(.projectSearch(type: .mod))
                            }
                            .frame(width: 120, height: 35)
                            Spacer()
                        }
                        .padding(2)
                    }
                    .padding()

                    if let mods = mods {
                        TitlelessMyCard(index: 2) {
                            LazyVStack(spacing: 0) {
                                ForEach(importRows) { item in
                                    ModpackImportProgressView(item: item)
                                }
                                ForEach(mods.filter { filter($0.mod) }) { modItem in
                                    ModView(modItem: modItem)
                                }
                                if mods.isEmpty && importRows.isEmpty {
                                    VStack(spacing: 8) {
                                        Image(systemName: "tray")
                                            .font(.system(size: 36))
                                            .foregroundStyle(Color(hex: 0x8C8C8C))
                                        Text("你还没有安装任何模组！")
                                            .font(.custom("PCL English", size: 14))
                                            .foregroundStyle(Color("TextColor"))
                                        Text("将 .jar / .zip / .mrpack 拖入此页面即可安装")
                                            .font(.custom("PCL English", size: 12))
                                            .foregroundStyle(Color(hex: 0x8C8C8C))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 28)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        Text("加载中……")
                            .font(.custom("PCL English", size: 14))
                            .foregroundStyle(Color("TextColor"))
                    }

                    Spacer()
                        .padding(.bottom, 20)
                }
                .scrollIndicators(.never)

                if isDropHovering { dropOverlay }
            }
            // 拖入文件安装 mod。
            // dropDestination 的回调是同步签名的；实际安装是异步，放到 Task 里。
            // 这样 SwiftUI 不需要等异步完成，直接返回 true；Task 在后台跑安装流程。
            .dropDestination(for: URL.self) { urls, _ in
                let captured = urls
                Task {
                    await handleDroppedMods(urls: captured)
                }
                return true
            } isTargeted: { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isDropHovering = hovering
                }
            }
            .task(id: taskID) {
                await loadMods()
            }
        }

    }
    // MARK: - 拖入 / 列表加载

    /// Drop 时显示的半透明覆盖层。`allowsHitTesting(false)` 让它不吃事件，
    /// 放手后事件继续传给下层。
    private var dropOverlay: some View {
        ZStack {
            AppSettings.shared.theme.getAccentColor().opacity(0.18)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 56, weight: .medium))
                Text("松开以安装 Mod")
                    .font(.custom("PCL English", size: 20))
                    .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                Text("支持拖入 .jar / .zip（含 mods 列表） / .mrpack 整合包")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color("TextColor").opacity(0.7))
            }
            .foregroundStyle(AppSettings.shared.theme.getTextStyle())
            .padding(40)
        }
        .background(.ultraThinMaterial.opacity(0.5))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 处理一次拖入：先做预分类；若包含整合包，弹确认框；再调 ModInstaller.install；
    /// 最后强制刷新列表。
    private func handleDroppedMods(urls rawURLs: [URL]) async {
        guard !rawURLs.isEmpty else { return }

        // 1. 预分类（这一步是纯 IO + zip 探测，不实际复制/解压）
        let cls = ModInstaller.classify(rawURLs)

        // 没有任何可识别的内容
        if !cls.hasAny {
            hint("未识别任何可安装的内容", .critical)
            return
        }

        // 2. 整合包会创建新实例，与"拖到当前实例装 mod"的意图很不同；弹个确认框防止误操作。
        // - "继续导入"：照装
        // - "仅装当前"：跳过 modpack，只装 mods 部分
        // - "取消"：什么都不做
        var proceedWithModpacks = true
        var proceedWithMods = true
        if cls.modpackCount > 0 {
            let remainingNonPacks = cls.mods.count + cls.unknown.count
            let detail = cls.modpacks.map { "  - \($0.lastPathComponent)" }.joined(separator: "\n")
            let summaryLine: String = {
                var lines: [String] = []
                if cls.modpackCount > 0 { lines.append("检测到 \(cls.modpackCount) 个整合包（会创建新实例）") }
                if remainingNonPacks > 0 { lines.append("以及 \(remainingNonPacks) 个其它文件") }
                return lines.joined(separator: "，")
            }()
            let body = "\(summaryLine)\n\n\(detail)"
            let button = await PopupManager.shared.showAsync(
                .init(.normal, "导入整合包？", body, [
                    .init(label: "继续导入", style: .accent),
                    .init(label: "仅装 mods", style: .normal),
                    PopupButtonModel.close,
                ])
            )
            switch button {
            case 0: // 继续导入
                proceedWithModpacks = true; proceedWithMods = true
            case 1: // 仅装 mods
                proceedWithModpacks = false; proceedWithMods = true
            default: // 取消
                proceedWithModpacks = false; proceedWithMods = false
            }
        }

        // 3. 实际安装
        guard proceedWithMods || proceedWithModpacks else {
            hint("已取消", .info)
            return
        }
        hint("正在处理拖入内容……")

        // 如果用户点了"仅装 mods"，unknown 会被丢掉；我们用 hint 提示一下。
        if proceedWithMods && !proceedWithModpacks && !cls.unknown.isEmpty {
            let names = cls.unknown.prefix(5).map { $0.lastPathComponent }.joined(separator: "、")
            hint("未识别 \(cls.unknown.count) 个文件（\(names)）", .critical)
        }

        var summary = ModInstaller.Summary()
        if proceedWithMods && !cls.mods.isEmpty {
            let modSummary = await ModInstaller.install(dropped: cls.mods, into: instance)
            summary.installedJars += modSummary.installedJars
            summary.installedPacks += modSummary.installedPacks
            summary.skipped.append(contentsOf: modSummary.skipped)
            summary.failures.append(contentsOf: modSummary.failures)
        }

        if proceedWithModpacks {
            for packURL in cls.modpacks {
                let row = ModpackImportListItem(sourceName: packURL.deletingPathExtension().lastPathComponent)
                await MainActor.run {
                    importRows.append(row)
                }
                do {
                    _ = try await ModpackImporter.install(zipURL: packURL, into: instance.minecraftDirectory) { update in
                        Task { @MainActor in
                            row.apply(update)
                        }
                    }
                    summary.installedPacks += 1
                    Task { @MainActor in
                        row.apply(.init(
                            packName: row.packName,
                            status: "导入完成",
                            progress: 1,
                            finishedFiles: row.totalFiles,
                            totalFiles: row.totalFiles
                        ))
                        try? await Task.sleep(for: .seconds(1.2))
                        importRows.removeAll { $0.id == row.id }
                    }
                } catch {
                    let message = "\(packURL.lastPathComponent): \(error.localizedDescription)"
                    summary.failures.append(message)
                    await MainActor.run {
                        row.fail("导入失败：\(error.localizedDescription)")
                    }
                }
            }
        }

        summary.failures.forEach { err("ModInstaller: \($0)") }
        summary.skipped.forEach { warn("ModInstaller: \($0)") }

        var parts: [String] = []
        if summary.installedJars > 0 { parts.append("已安装 \(summary.installedJars) 个 mod") }
        if summary.installedPacks > 0 { parts.append("已导入 \(summary.installedPacks) 个整合包") }
        if !summary.skipped.isEmpty { parts.append("跳过 \(summary.skipped.count) 项") }
        if !parts.isEmpty {
            hint(parts.joined(separator: "，"), .finish)
        }
        if !summary.failures.isEmpty {
            hint("部分文件安装失败（详见日志）", .critical)
        }

        // 4. 重新加载 mods 列表（modpack 不影响本实例，但 list 顺序也可能变化）
        taskID = UUID()
    }

    /// 加载当前实例的 mods/ 下所有 .jar / .jar.disabled，更新 mods 数组。
    /// 同时清空搜索条件以避免残留状态。
    private func loadMods() async {
        if instance.clientBrand == .vanilla { return }
        // 与 .task(id: taskID) 配合：bumping taskID 会触发重新加载。
        do {
            let modsDir = instance.runningDirectory.appending(path: "mods")
            let fm = FileManager.default
            var loaded: [ModItem] = []

            // mods/ 子目录不存在 —— 视为空集（合法状态），而不是错误。
            // 例如用户第一次进入 mods 页面还没下过 mod，或者实例是从整合包新装的。
            if fm.fileExists(atPath: modsDir.path) {
                let files = try fm.contentsOfDirectory(at: modsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                let modFiles = files.filter { $0.pathExtension.lowercased() == "jar" || $0.pathExtension.lowercased() == "disabled" }
                for modFile in modFiles {
                    if let mod = Mod.loadMod(url: modFile) {
                        loaded.append(.init(mod: mod, url: modFile))
                        loadSummary(mod: mod)
                    }
                }
                loaded.sort { ($0.mod.name.first ?? " ") < ($1.mod.name.first ?? " ") }
            }
            await MainActor.run {
                self.mods = loaded
            }
        } catch {
            // ❗关键：catch 路径必须显式 resolve UI 状态。否则 mods 仍是 nil → "加载中……" 转圈死锁。
            // 之前这里只写 self.error = error，结果 mods 没设，UI 一直停在 nil / 加载中。
            await MainActor.run {
                self.mods = []
                self.error = error
            }
        }
    }


    
    private func loadSummary(mod: Mod) {
        Task {
            if let summary = try? await ModrinthProjectSearcher.shared.get(mod.id) { // 若 slug 与 Mod ID 一致，使用通过 Mod ID 获取到的 Project
                await MainActor.run {
                    mod.summary = summary
                }
            } else { // 否则搜索最匹配的 Mod
                if let summary = try? await ModrinthProjectSearcher.shared.search(
                    type: .mod,
                    query: mod.name,
                    version: instance.version,
                    loader: instance.clientBrand,
                    limit: 1
                ).first {
                    await MainActor.run {
                        mod.summary = summary
                    }
                } else {
                    warn("未找到 \(mod.id) 对应的 Modrinth Project")
                }
            }
        }
    }
    
    private struct ModpackImportProgressView: View {
        @ObservedObject private var item: ModpackImportListItem

        init(item: ModpackImportListItem) {
            self.item = item
        }

        private var detailText: String {
            if item.totalFiles > 0 {
                return "\(item.status)（\(item.finishedFiles)/\(item.totalFiles)）"
            }
            return item.status
        }

        var body: some View {
            MyListItem {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppSettings.shared.theme.getAccentColor().opacity(item.isFailed ? 0.10 : 0.18))
                        Image(systemName: item.isFailed ? "exclamationmark.triangle.fill" : "archivebox.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(item.isFailed ? AnyShapeStyle(Color.red) : AppSettings.shared.theme.getTextStyle())
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 0) {
                            Text(item.packName)
                                .font(.custom("PCL English", size: 14))
                                .foregroundStyle(item.isFailed ? Color.red : Color("TextColor"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !item.isFailed {
                                Text(" 正在导入 / 解决依赖")
                                    .font(.custom("PCL English", size: 14))
                                    .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                                    .lineLimit(1)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(detailText)
                                .font(.custom("PCL English", size: 12))
                                .foregroundStyle(item.isFailed ? Color.red.opacity(0.85) : Color(hex: 0x8C8C8C))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: item.progress)
                                .progressViewStyle(.linear)
                                .tint(item.isFailed ? .red : AppSettings.shared.theme.getAccentColor())
                                .frame(maxWidth: .infinity)
                                .opacity(item.isFailed ? 0.55 : 1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", item.progress * 100))
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(item.isFailed ? AnyShapeStyle(Color.red.opacity(0.85)) : AppSettings.shared.theme.getTextStyle())
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(4)
            }
            .animation(.easeInOut(duration: 0.2), value: item.progress)
            .animation(.easeInOut(duration: 0.2), value: item.isFailed)
        }
    }

    struct ModView: View {
        @ObservedObject private var dataManager: DataManager = .shared
        @ObservedObject private var mod: Mod
        @ObservedObject private var state: ProjectSearchViewState = StateManager.shared.projectSearch
        @State private var isHovered: Bool = false
        @State private var isSwitching = false
        @State private var url: URL
        
        private var isDisabled: Bool { url.pathExtension.lowercased() == "disabled" }
        
        fileprivate init(modItem: ModItem) {
            self.mod = modItem.mod
            self.url = modItem.url
        }
        
        var body: some View {
            MyListItem {
                HStack(alignment: .center) {
                    getIconImage()
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            Text(mod.summary?.name ?? mod.name)
                                .font(.custom("PCL English", size: 14))
                                .foregroundStyle(isDisabled ? Color(hex: 0x8C8C8C) : Color("TextColor"))
                                .strikethrough(isDisabled)
                            Text(" | \(mod.version)")
                                .foregroundStyle(Color(hex: 0x8C8C8C))
                        }
                        HStack {
                            ForEach((mod.summary?.tags ?? []).compactMap { ProjectListItem.tagMap[$0] }, id: \.self) { tag in
                                MyTag(label: tag, backgroundColor: Color("TagColor"), fontSize: 12)
                            }
                            
                            Text(mod.summary?.description ?? mod.description)
                                .font(.custom("PCL English", size: 14))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                    }
                    .font(.custom("PCL English", size: 12))
                    Spacer()
                    
                    if isHovered {
                        HStack {
                            if let summary = mod.summary {
                                Image("InfoIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16)
                                    .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        dataManager.router.append(.projectDownload(summary: summary))
                                    }
                            }
                            
                            Image(isDisabled ? "CheckIcon" : "StopIcon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16)
                                .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    toggleDisable()
                                }
                        }
                        .padding(.trailing, 4)
                    }
                }
                .padding(4)
            }
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { isHovered in
                self.isHovered = isHovered
            }
        }
        
        private func toggleDisable() {
            guard !isSwitching else { return }
            isSwitching = true
            
            let newURL: URL
            
            if isDisabled {
                newURL = url.deletingPathExtension()
            } else {
                newURL = url.appendingPathExtension("disabled")
            }
            try? FileManager.default.moveItem(at: url, to: newURL)
            url = newURL
            isSwitching = false
        }
        
        /// 获取未经任何处理的模组图标 Image
        private func getIconImage() -> Image {
            if let summary = mod.summary {
                if let icon = state.iconCache[summary.projectId] {
                    return icon
                } else {
                    Task {
                        if let url = summary.iconURL,
                           let data = await Requests.get(url).data,
                           let nsImage = NSImage(data: data) {
                            DispatchQueue.main.async {
                                self.state.iconCache[summary.projectId] = Image(nsImage: nsImage)
                            }
                        }
                    }
                    return Image("ModIconPlaceholder")
                }
            }
            
            // TODO: 读取 Mod 图标
            return Image("ModIconPlaceholder")
        }
    }
}
