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
    @State private var importRows: [ModpackImportListItem] = []
    @State private var compatibilityReport: NativeCompatibilityReport?
    @State private var compatibilityBusyIDs: Set<String> = []

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
                    MySearchBox(query: $searchQuery, placeholder: "搜索已安装 Mod 的名称或描述（⌘F）") { _ in }
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
                            MyButton(text: "检查更新") {
                                var path = dataManager.router.path
                                if !path.isEmpty { path.removeLast() }
                                path.append(.instanceModUpdates)
                                dataManager.router.path = path
                            }
                            .frame(width: 120, height: 35)
                            Spacer()
                        }
                        .padding(2)
                    }
                    .padding()

                    if let report = compatibilityReport, !report.issues.isEmpty {
                        compatibilityPanel(report)
                            .padding(.horizontal)
                            .padding(.bottom)
                    }

                    if let mods = mods {
                        let visible = filteredMods(mods)
                        TitlelessMyCard(index: 3) {
                            LazyVStack(spacing: 0) {
                                ForEach(importRows) { item in
                                    ModpackImportProgressView(item: item)
                                }
                                ForEach(visible) { modItem in
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
                                } else if visible.isEmpty && importRows.isEmpty {
                                    // 有 mod 但都被搜索条件筛掉了 —— 明确说明，而不是留一片空白。
                                    VStack(spacing: 6) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 28))
                                            .foregroundStyle(Color(hex: 0x8C8C8C))
                                        Text("没有匹配「\(searchQuery)」的 Mod")
                                            .font(.custom("PCL English", size: 14))
                                            .foregroundStyle(Color("TextColor"))
                                        Text("共 \(mods.count) 个已安装 Mod")
                                            .font(.custom("PCL English", size: 12))
                                            .foregroundStyle(Color(hex: 0x8C8C8C))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        VStack(spacing: 10) {
                            ProgressView().scaleEffect(0.8)
                            Text("正在读取 Mod 列表……")
                                .font(.custom("PCL English", size: 14))
                                .foregroundStyle(Color(hex: 0x8C8C8C))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
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

    private func compatibilityPanel(_ report: NativeCompatibilityReport) -> some View {
        TitlelessMyCard(index: 2) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AppSettings.shared.theme.getAccentColor().opacity(0.13))
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac 原生兼容性")
                            .font(.custom("PCL English", size: 15))
                            .foregroundStyle(Color("TextColor"))
                        Text("已隔离 \(report.disabledCount) 个 · 官方补全 \(report.installedOfficialArtifactCount) 个 · 待确认 \(report.unresolvedCount) 个")
                            .font(.custom("PCL English", size: 12))
                            .foregroundStyle(Color(hex: 0x8C8C8C))
                    }
                    Spacer()
                    Button {
                        taskID = UUID()
                    } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)

                Divider().opacity(0.3)

                ForEach(Array(report.issues.enumerated()), id: \.element.id) { index, issue in
                    compatibilityIssueRow(issue)
                    if index < report.issues.count - 1 {
                        Divider().padding(.leading, 52).opacity(0.25)
                    }
                }
            }
        }
    }

    private func compatibilityIssueRow(_ issue: NativeCompatibilityIssue) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.isApplied ? "checkmark.shield.fill" : issue.severity == .blocking ? "xmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(compatibilityColor(issue))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(issue.modName)
                            .font(.custom("PCL English", size: 14))
                            .foregroundStyle(Color("TextColor"))
                        Text(issue.isApplied ? (issue.action == .installOfficialArtifact ? "官方组件已补全" : "已隔离") : issue.isUserRestored ? "已由你恢复" : issue.severity == .blocking ? "不可直接运行" : "待确认")
                            .font(.custom("PCL English", size: 10))
                            .foregroundStyle(compatibilityColor(issue))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(compatibilityColor(issue).opacity(0.10), in: Capsule())
                    }
                    Text(issue.reason)
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x6F7780))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(issue.installedReplacementRelativePath ?? issue.disabledRelativePath ?? issue.relativePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                if issue.isApplied {
                    Button(issue.action == .installOfficialArtifact ? "移除" : "恢复") {
                        restoreCompatibilityIssue(issue)
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(compatibilityBusyIDs.contains(issue.id))
                } else if issue.isUserRestored {
                    Button("重新隔离") { reenableCompatibilityFix(issue) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(compatibilityBusyIDs.contains(issue.id))
                }
            }

            if let fixError = issue.fixError {
                Label(fixError, systemImage: "exclamationmark.triangle.fill")
                    .font(.custom("PCL English", size: 11))
                    .foregroundStyle(Color.red)
                    .padding(.leading, 38)
            }

            if !issue.replacementCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("可选替代 · 按可信度降序，未替你选择")
                        .font(.custom("PCL English", size: 11))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                    ForEach(issue.replacementCandidates) { candidate in
                        replacementCandidateRow(candidate, issue: issue)
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(12)
    }

    private func replacementCandidateRow(_ candidate: ReplacementCandidate, issue: NativeCompatibilityIssue) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(candidate.name) \(candidate.version)")
                            .font(.custom("PCL English", size: 12))
                            .foregroundStyle(Color("TextColor"))
                        Text("可信度 \(candidate.trustScore.total)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppSettings.shared.theme.getAccentColor().opacity(0.10), in: Capsule())
                    }
                    Text("\(candidate.upstreamRelationship) · \(candidate.licenseIdentifier) · \(candidate.architectures.joined(separator: ", "))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x8C8C8C))
                        .lineLimit(1)
                }
                Spacer()
                if issue.installedReplacementCandidateID == candidate.id {
                    Label("已安装", systemImage: "checkmark.circle.fill")
                        .font(.custom("PCL English", size: 11))
                        .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                } else {
                    Button("选择并安装") { installReplacement(candidate, for: issue) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!issue.isApplied || compatibilityBusyIDs.contains(issue.id))
                }
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    Text("commit \(candidate.commit) · 已验证 macOS \(candidate.architectures.joined(separator: ", "))")
                    Text("评分：上游 \(candidate.trustScore.sourceAndUpstream)×35% · 构建 \(candidate.trustScore.reproducibility)×25% · 采用 \(candidate.trustScore.ecosystemValidation)×20% · 维护 \(candidate.trustScore.maintenanceAndSecurity)×15% · 许可证 \(candidate.trustScore.licenseCompleteness)×5%")
                    Text("SHA-256  \(candidate.sha256)")
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Link("源码", destination: candidate.sourceURL)
                        if let upstreamURL = candidate.upstreamURL {
                            Link("上游", destination: upstreamURL)
                        }
                        Link("CI / 构建证明", destination: candidate.buildEvidenceURL)
                        if let patchURL = candidate.patchURL {
                            Link("补丁", destination: patchURL)
                        }
                        if let sbomURL = candidate.sbomURL {
                            Link("SBOM", destination: sbomURL)
                        }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(hex: 0x707780))
                .padding(.top, 3)
            } label: {
                Text("查看来源与验证详情")
                    .font(.custom("PCL English", size: 10))
                    .foregroundStyle(Color(hex: 0x707780))
            }
        }
        .padding(8)
        .background(Color("TextColor").opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
    }

    private func compatibilityColor(_ issue: NativeCompatibilityIssue) -> Color {
        if issue.isApplied || issue.isUserRestored { return AppSettings.shared.theme.getAccentColor() }
        return issue.severity == .blocking ? Color(hex: 0xE5484D) : Color(hex: 0xD18B16)
    }

    private func restoreCompatibilityIssue(_ issue: NativeCompatibilityIssue) {
        guard compatibilityBusyIDs.insert(issue.id).inserted else { return }
        Task {
            defer { compatibilityBusyIDs.remove(issue.id) }
            do {
                try await NativeCompatibilityService.shared.restore(issueID: issue.id, instance: instance)
                let message = issue.action == .installOfficialArtifact
                    ? "已移除 \(issue.modName) 的官方 Mac 组件"
                    : "已恢复 \(issue.modName)"
                hint(message, .finish)
                taskID = UUID()
            } catch {
                err("无法恢复 \(issue.modName)：\(error.localizedDescription)")
                hint("恢复失败：\(error.localizedDescription)", .critical)
            }
        }
    }

    private func installReplacement(_ candidate: ReplacementCandidate, for issue: NativeCompatibilityIssue) {
        guard compatibilityBusyIDs.insert(issue.id).inserted else { return }
        Task {
            defer { compatibilityBusyIDs.remove(issue.id) }
            do {
                try await NativeCompatibilityService.shared.installReplacement(candidate, for: issue.id, instance: instance)
                hint("已安装你选择的替代包 \(candidate.name)", .finish)
                taskID = UUID()
            } catch {
                err("无法安装替代包 \(candidate.name)：\(error.localizedDescription)")
                hint("替代包安装失败：\(error.localizedDescription)", .critical)
            }
        }
    }

    private func reenableCompatibilityFix(_ issue: NativeCompatibilityIssue) {
        guard compatibilityBusyIDs.insert(issue.id).inserted else { return }
        Task {
            defer { compatibilityBusyIDs.remove(issue.id) }
            do {
                try await NativeCompatibilityService.shared.reenableAutomaticFix(
                    issueID: issue.id,
                    instance: instance
                )
                hint("已重新启用 \(issue.modName) 的自动隔离", .finish)
                taskID = UUID()
            } catch {
                err("无法重新启用自动隔离：\(error.localizedDescription)")
                hint("操作失败：\(error.localizedDescription)", .critical)
            }
        }
    }
    /// 按搜索词过滤。原来存的是一个 `(Mod) -> Bool` 闭包 @State，只在 onSubmit 时更新，
    /// 于是边打字列表不会跟着变；现在直接由 searchQuery 派生，输入即筛选。
    private func filteredMods(_ mods: [ModItem]) -> [ModItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return mods }
        return mods.filter {
            $0.mod.name.localizedCaseInsensitiveContains(query)
            || $0.mod.description.localizedCaseInsensitiveContains(query)
            || ($0.mod.summary?.name.localizedCaseInsensitiveContains(query) ?? false)
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
    private func loadMods() async {
        if instance.clientBrand == .vanilla { return }
        // 与 .task(id: taskID) 配合：bumping taskID 会触发重新加载。
        do {
            do {
                let configuredJava: URL? = instance.config.javaURL
                let architecture = configuredJava.map { Architecture.getArchOfFile($0) } ?? .system
                let processArchitecture: Architecture = switch architecture {
                case .unknown, .fatFile: .system
                default: architecture
                }
                let scanned = try await NativeCompatibilityService.shared.analyze(
                    instance: instance,
                    targetArchitecture: processArchitecture
                )
                let report = try await NativeCompatibilityService.shared.applyTrustedFixes(report: scanned)
                await MainActor.run {
                    compatibilityReport = report
                }
            } catch {
                // Compatibility diagnostics are useful, but a damaged JAR or
                // state file must not make the ordinary Mod list unusable.
                warn("Mod 页面 Mac 兼容性检查失败：\(error.localizedDescription)")
                let previous = await NativeCompatibilityService.shared.lastReport(instance: instance)
                await MainActor.run {
                    compatibilityReport = previous
                }
            }

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
                    }
                }
                loaded.sort { ($0.mod.name.first ?? " ") < ($1.mod.name.first ?? " ") }
            }
            let result = loaded
            await MainActor.run {
                self.mods = result
            }
            // 列表已经能显示了，再去拉 Modrinth 元数据。
            await loadSummaries(for: result.map(\.mod))
        } catch {
            // ❗关键：catch 路径必须显式 resolve UI 状态。否则 mods 仍是 nil → "加载中……" 转圈死锁。
            await MainActor.run {
                self.mods = []
                self.error = error
            }
        }
    }

    /// 拉取 Modrinth 元数据，并发上限 6。
    ///
    /// 原来是每个 mod 一个不受限的 Task，200 个 mod 的实例会瞬间发出约 400 个请求，
    /// 必定触发 Modrinth 限流，并把主线程淹没在 summary 写入里。
    private func loadSummaries(for mods: [Mod]) async {
        guard !mods.isEmpty else { return }
        let concurrencyLimit = 6
        let version = instance.version
        let brand = instance.clientBrand

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < mods.count else { return }
                let mod = mods[nextIndex]
                nextIndex += 1
                group.addTask {
                    await InstanceModsView.fetchSummary(for: mod, version: version, brand: brand)
                }
            }

            for _ in 0..<min(concurrencyLimit, mods.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private static func fetchSummary(for mod: Mod, version: MinecraftVersion?, brand: ClientBrand?) async {
        // 若 slug 与 Mod ID 一致，直接用 Mod ID 拿 Project。
        if let summary = try? await ModrinthProjectSearcher.shared.get(mod.id) {
            await MainActor.run { mod.summary = summary }
            return
        }
        // 否则退回按名字搜索最匹配的一项。
        if let summary = try? await ModrinthProjectSearcher.shared.search(
            type: .mod,
            query: mod.name,
            version: version,
            loader: brand,
            limit: 1
        ).first {
            await MainActor.run { mod.summary = summary }
        } else {
            warn("未找到 \(mod.id) 对应的 Modrinth Project")
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
                    ProjectIconView(
                        projectId: mod.summary?.projectId,
                        iconURL: mod.summary?.iconURL,
                        size: 34,
                        cornerRadius: 6
                    )
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
                                Button {
                                    dataManager.router.append(.projectDownload(summary: summary))
                                } label: {
                                    Image("InfoIcon")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 16)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                                .help("查看项目信息")
                                .accessibilityLabel("查看 \(mod.summary?.name ?? mod.name) 项目信息")
                            }

                            Button(action: toggleDisable) {
                                Image(isDisabled ? "CheckIcon" : "StopIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                            .help(isDisabled ? "启用 Mod" : "禁用 Mod")
                            .accessibilityLabel("\(isDisabled ? "启用" : "禁用") \(mod.summary?.name ?? mod.name)")
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

            let newURL: URL = isDisabled
                ? url.deletingPathExtension()
                : url.appendingPathExtension("disabled")

            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                url = newURL
                hint(isDisabled ? "已停用 \(mod.name)" : "已启用 \(mod.name)", .finish)
            } catch {
                // 之前用 try? 静默失败：文件被占用时按钮看起来没反应。
                err("无法切换 Mod 启用状态: \(error.localizedDescription)")
                hint("无法切换 \(mod.name)：\(error.localizedDescription)", .critical)
            }
            isSwitching = false
        }
    }
}
