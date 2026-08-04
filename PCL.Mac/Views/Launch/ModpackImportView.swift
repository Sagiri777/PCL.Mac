//
//  ModpackImportView.swift
//  PCL.Mac
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor
final class ModpackImportManager: ObservableObject {
    static let shared = ModpackImportManager()

    enum Phase {
        case ready
        case importing
        case awaitingOfficialDownloads
        case cancelling
        case success
        case failed(String)
        case cancelled
    }

    @Published var isPresented = false
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var urls: [URL] = []
    @Published private(set) var directory: MinecraftDirectory?
    @Published private(set) var currentPackName = ""
    @Published private(set) var statusText = "准备导入"
    @Published private(set) var currentPackIndex = 0
    @Published private(set) var overallProgress = 0.0
    @Published private(set) var currentStage: ModpackImportStage = .detecting
    @Published private(set) var stageProgress: [ModpackImportStage: Double] = [:]
    @Published private(set) var finishedFiles = 0
    @Published private(set) var totalFiles = 0
    @Published private(set) var importedURLs: [URL] = []
    @Published private(set) var compatibilityDisabledCount = 0
    @Published private(set) var compatibilityOfficialArtifactCount = 0
    @Published private(set) var compatibilityWarningCount = 0
    @Published private(set) var recoveryInfo: ModpackImportRecoveryInfo?

    private var worker: Task<Void, Never>?
    private var completedImports: [URL: URL] = [:]
    private let officialWebDownloads = OfficialWebDownloadCoordinator.shared
    private var canResumeOfficialWebDownloads = false

    var canEditSelection: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isRunning: Bool {
        switch phase {
        case .importing, .awaitingOfficialDownloads, .cancelling: true
        default: false
        }
    }

    var hasOfficialWebDownloadQueue: Bool {
        canResumeOfficialWebDownloads && recoveryInfo?.officialWebDownloadManifestURL != nil
    }

    func present(urls: [URL], directory: MinecraftDirectory, autoStart: Bool) {
        guard !isRunning else {
            hint("已有整合包正在导入", .critical)
            return
        }
        self.urls = uniqueModpackURLs(urls)
        self.directory = directory
        resetProgress()
        phase = .ready
        isPresented = true
        if autoStart {
            start()
        }
    }

    func add(urls newURLs: [URL]) {
        guard canEditSelection else { return }
        urls = uniqueModpackURLs(urls + newURLs)
    }

    func remove(_ url: URL) {
        guard canEditSelection else { return }
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func chooseMoreFiles() {
        guard canEditSelection else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip] + (UTType(filenameExtension: "mrpack").map { [$0] } ?? [])
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func start() {
        guard !urls.isEmpty, let directory, !isRunning else { return }
        phase = .importing
        recoveryInfo = nil
        canResumeOfficialWebDownloads = false
        worker = Task { [weak self] in
            guard let self else { return }
            var activeURL: URL?
            var shouldRetryAfterOfficialDownloads = false
            do {
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    let sourceKey = url.standardizedFileURL
                    if completedImports[sourceKey] != nil {
                        currentPackIndex = index
                        overallProgress = Double(index + 1) / Double(max(urls.count, 1))
                        continue
                    }
                    activeURL = url
                    currentPackIndex = index
                    currentPackName = url.deletingPathExtension().lastPathComponent
                    statusText = "正在读取整合包"
                    currentStage = .detecting
                    stageProgress = [:]
                    finishedFiles = 0
                    totalFiles = 0

                    let importedURL = try await ModpackImporter.install(zipURL: url, into: directory) { update in
                        Task { @MainActor [weak self] in
                            self?.consume(update)
                        }
                    }
                    completedImports[sourceKey] = importedURL
                    importedURLs = urls.compactMap { self.completedImports[$0.standardizedFileURL] }
                    if let report = await NativeCompatibilityService.shared.lastReport(instanceURL: importedURL) {
                        compatibilityDisabledCount += report.disabledCount
                        compatibilityOfficialArtifactCount += report.installedOfficialArtifactCount
                        compatibilityWarningCount += report.unresolvedCount
                    }
                }

                stageProgress = Dictionary(uniqueKeysWithValues: ModpackImportStage.allCases.map { ($0, 1) })
                overallProgress = 1
                statusText = "所有文件与启动依赖均已就绪"
                phase = .success
                if let last = importedURLs.last {
                    AppSettings.shared.defaultInstance = last.lastPathComponent
                }
                directory.loadInnerInstances()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    statusText = "已取消导入，未完成的实例已清理"
                    phase = .cancelled
                } else {
                    shouldRetryAfterOfficialDownloads = handleImportFailure(
                        error,
                        activeURL: activeURL,
                        directory: directory
                    )
                    err("整合包导入失败：\(error.localizedDescription)")
                }
                if let last = importedURLs.last {
                    AppSettings.shared.defaultInstance = last.lastPathComponent
                    directory.loadInnerInstances()
                }
            }
            worker = nil
            if shouldRetryAfterOfficialDownloads {
                resumeImportAfterOfficialDownloads()
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        if case .awaitingOfficialDownloads = phase {
            phase = .cancelling
            statusText = "正在取消并清理未完成实例"
            officialWebDownloads.pause()
            worker?.cancel()
            if let recoveryInfo {
                ModpackImporter.discardIncompleteRecovery(at: recoveryInfo.instanceURL)
            }
            recoveryInfo = nil
            canResumeOfficialWebDownloads = false
            statusText = "已取消导入，未完成的实例已清理"
            phase = .cancelled
            return
        }
        phase = .cancelling
        statusText = "正在取消并清理未完成实例"
        worker?.cancel()
    }

    func close() {
        guard !isRunning else { return }
        isPresented = false
    }

    func retry() {
        guard !isRunning else { return }
        resetProgress(preservingCompletedImports: true)
        start()
    }

    func continueOfficialWebDownloads() {
        guard !officialWebDownloads.isPresented else { return }
        if openOfficialWebDownloadsIfPossible() {
            resumeImportAfterOfficialDownloads()
        }
    }

    func revealRecoveryLocation() {
        guard let recoveryInfo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryInfo.instanceURL])
    }

    private func handleImportFailure(
        _ error: Error,
        activeURL: URL?,
        directory: MinecraftDirectory
    ) -> Bool {
        let failure = error as? ModpackImportFailure
        if let failure {
            currentStage = failure.stage
            finishedFiles = failure.completedFiles
            totalFiles = failure.totalFiles
        }
        if let activeURL {
            recoveryInfo = ModpackImporter.recoveryInfo(for: activeURL, in: directory)
        }

        if failure?.canBeginOfficialWebDownloads == true, recoveryInfo != nil {
            return openOfficialWebDownloadsIfPossible()
        }

        if failure?.officialWebDownloadManifestURL != nil {
            statusText = "自动下载暂时失败；官方网页下载队列已保留，继续重试会从当前下载恢复"
        } else {
            statusText = recoveryInfo == nil
                ? "导入在 \(currentStage.title) 阶段停止"
                : "下载已暂停，现有文件和检查点均已保留"
        }
        phase = .failed(failure?.reason ?? error.localizedDescription)
        return false
    }

    /// Presents the nested official-page assistant if every queued file has a
    /// trusted page, SHA-1 and instance-relative target. Returns true only
    /// when all queue records are already validated and a normal retry should
    /// continue immediately.
    private func openOfficialWebDownloadsIfPossible() -> Bool {
        guard let recoveryInfo,
              let queueURL = recoveryInfo.officialWebDownloadManifestURL else {
            statusText = "找不到可恢复的官方网页下载队列"
            phase = .failed("受限 CurseForge 文件没有可恢复的官方网页下载队列。")
            canResumeOfficialWebDownloads = false
            return false
        }

        do {
            let plan = try ModpackImporter.officialWebDownloadPlan(
                queueURL: queueURL,
                instanceRoot: recoveryInfo.instanceURL
            )
            refreshRecoveryInfoAfterQueueMigration()
            guard plan.blocked.isEmpty else {
                statusText = "官方网页下载已安全暂停"
                phase = .failed(blockedQueueDescription(plan.blocked))
                canResumeOfficialWebDownloads = false
                return false
            }
            guard !plan.groups.isEmpty else {
                statusText = "官方网页文件已验证，正在继续导入"
                phase = .ready
                canResumeOfficialWebDownloads = false
                return true
            }

            let browserAutomationEnabled = AppSettings.shared.accessibilityBrowserAutomationDownloadEnabled
            canResumeOfficialWebDownloads = true
            currentStage = .files
            statusText = browserAutomationEnabled
                ? "正在使用无障碍浏览器自动化下载；完成后会自动继续"
                : "请在 CurseForge 官方页面确认下载；完成后会自动继续"
            phase = .awaitingOfficialDownloads
            officialWebDownloads.present(
                groups: plan.groups,
                instanceRoot: recoveryInfo.instanceURL,
                browserAutomationEnabled: browserAutomationEnabled
            ) { [weak self] result in
                self?.handleOfficialWebDownloadResult(result)
            }
        } catch {
            statusText = "无法读取官方网页下载队列"
            phase = .failed("无法恢复官方网页下载：\(error.localizedDescription)")
            canResumeOfficialWebDownloads = false
        }
        return false
    }

    private func handleOfficialWebDownloadResult(_ result: Result<Void, Error>) {
        guard case .awaitingOfficialDownloads = phase else { return }
        switch result {
        case .success:
            canResumeOfficialWebDownloads = false
            statusText = "官方网页文件已校验并归位，正在继续导入"
            resumeImportAfterOfficialDownloads()
        case let .failure(error):
            // Closing the child sheet is a pause, not a cancellation. The
            // manifest and checkpoint remain in the instance for a later run.
            canResumeOfficialWebDownloads = true
            statusText = error is OfficialWebDownloadError
                ? "官方网页下载已暂停，已完成文件会保留"
                : "官方网页下载暂时无法继续"
            phase = .awaitingOfficialDownloads
        }
    }

    private func resumeImportAfterOfficialDownloads() {
        guard !officialWebDownloads.isPresented else { return }
        canResumeOfficialWebDownloads = false
        phase = .ready
        resetProgress(preservingCompletedImports: true)
        start()
    }

    private func refreshRecoveryInfoAfterQueueMigration() {
        guard let directory,
              urls.indices.contains(currentPackIndex) else { return }
        recoveryInfo = ModpackImporter.recoveryInfo(for: urls[currentPackIndex], in: directory) ?? recoveryInfo
    }

    private func blockedQueueDescription(_ blocks: [OfficialWebDownloadBlock]) -> String {
        let examples = blocks.prefix(3).map { block in
            "\(block.record.fileName)（项目 \(block.record.projectID)，文件 \(block.record.fileID)）：\(block.reason.localizedDescription)"
        }
        let suffix = blocks.count > examples.count ? "\n另有 \(blocks.count - examples.count) 个文件。" : ""
        return "无法安全开始官方网页下载：\n\(examples.joined(separator: "\n"))\(suffix)"
    }

    private func consume(_ update: ModpackImportProgressUpdate) {
        guard isRunning else { return }
        currentPackName = update.packName
        statusText = update.status
        currentStage = update.stage
        finishedFiles = update.finishedFiles
        totalFiles = update.totalFiles

        for stage in ModpackImportStage.allCases where stage.rawValue < update.stage.rawValue {
            stageProgress[stage] = 1
        }
        stageProgress[update.stage] = update.stageProgress
        overallProgress = (Double(currentPackIndex) + update.progress) / Double(max(urls.count, 1))
    }

    private func resetProgress(preservingCompletedImports: Bool = false) {
        if !preservingCompletedImports {
            completedImports = [:]
            importedURLs = []
            compatibilityDisabledCount = 0
            compatibilityOfficialArtifactCount = 0
            compatibilityWarningCount = 0
        }
        let firstPending = urls.first { completedImports[$0.standardizedFileURL] == nil }
        currentPackName = (firstPending ?? urls.first)?.deletingPathExtension().lastPathComponent ?? ""
        statusText = "检查文件后开始导入"
        currentPackIndex = firstPending.flatMap { urls.firstIndex(of: $0) } ?? 0
        overallProgress = Double(completedImports.count) / Double(max(urls.count, 1))
        currentStage = .detecting
        stageProgress = [:]
        finishedFiles = 0
        totalFiles = 0
        recoveryInfo = nil
        canResumeOfficialWebDownloads = false
    }

    private func uniqueModpackURLs(_ input: [URL]) -> [URL] {
        var seen = Set<URL>()
        return input.filter { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "zip" || ext == "mrpack" else { return false }
            return seen.insert(url.standardizedFileURL).inserted
        }
    }
}

struct ModpackImportView: View {
    @ObservedObject var manager: ModpackImportManager
    @ObservedObject private var settings: AppSettings = .shared
    @ObservedObject private var officialWebDownloads = OfficialWebDownloadCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            content
            Divider().opacity(0.45)
            footer
        }
        .frame(width: 680, height: 580)
        .background(Color("MyCardBackgroundColor"))
        .interactiveDismissDisabled(manager.isRunning)
        .sheet(isPresented: $officialWebDownloads.isPresented) {
            OfficialWebDownloadView(coordinator: officialWebDownloads)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(settings.theme.getTextStyle())
                .frame(width: 44, height: 44)
                .background(settings.theme.getAccentColor().opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text("导入整合包")
                    .font(.custom("PCL English", size: 20))
                    .foregroundStyle(Color("TextColor"))
                Text(headerSubtitle)
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x7F8790))
                    .lineLimit(1)
            }
            Spacer()
            if !manager.isRunning {
                Button {
                    manager.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch manager.phase {
        case .ready:
            readyContent
        default:
            progressContent
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            destinationRow
            dropZone
            if !manager.urls.isEmpty {
                Text("待导入文件 · \(manager.urls.count)")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x7F8790))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.urls, id: \.self) { url in
                            fileRow(url)
                            Divider().opacity(0.25)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var destinationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(settings.theme.getTextStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text("实例位置")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x7F8790))
                Text(manager.directory?.rootURL.path ?? "未选择 Minecraft 文件夹")
                    .font(.custom("PCL English", size: 13))
                    .foregroundStyle(Color("TextColor"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(12)
        .background(settings.theme.getAccentColor().opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(settings.theme.getTextStyle())
            Text(manager.urls.isEmpty ? "拖入整合包" : "继续拖入更多整合包")
                .font(.custom("PCL English", size: 15))
                .foregroundStyle(Color("TextColor"))
            Text("支持 Modrinth、CurseForge、HMCL 与普通 ZIP")
                .font(.custom("PCL English", size: 12))
                .foregroundStyle(Color(hex: 0x7F8790))
            Button("选择文件") {
                manager.chooseMoreFiles()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 138)
        .background(settings.theme.getAccentColor().opacity(0.035))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(settings.theme.getAccentColor().opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: URL.self) { urls, _ in
            manager.add(urls: urls)
            return true
        }
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: url.pathExtension.lowercased() == "mrpack" ? "cube.fill" : "doc.zipper")
                .foregroundStyle(settings.theme.getTextStyle())
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.custom("PCL English", size: 13))
                    .foregroundStyle(Color("TextColor"))
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.custom("PCL English", size: 11))
                    .foregroundStyle(Color(hex: 0x7F8790))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                manager.remove(url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(hex: 0x7F8790))
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .frame(height: 48)
    }

    private var progressContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.currentPackName.isEmpty ? "准备整合包" : manager.currentPackName)
                            .font(.custom("PCL English", size: 17))
                            .foregroundStyle(Color("TextColor"))
                            .lineLimit(1)
                        Text(manager.statusText)
                            .font(.custom("PCL English", size: 12))
                            .foregroundStyle(statusColor)
                    }
                    Spacer()
                    Text(String(format: "%.0f%%", manager.overallProgress * 100))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(settings.theme.getTextStyle())
                }
                ProgressView(value: manager.overallProgress)
                    .progressViewStyle(.linear)
                    .tint(settings.theme.getAccentColor())
                HStack {
                    Text("第 \(min(manager.currentPackIndex + 1, max(manager.urls.count, 1))) / \(max(manager.urls.count, 1)) 个整合包")
                    Spacer()
                    if manager.totalFiles > 0 {
                        Text("文件 \(manager.finishedFiles) / \(manager.totalFiles)")
                    }
                }
                .font(.custom("PCL English", size: 11))
                .foregroundStyle(Color(hex: 0x7F8790))

                VStack(spacing: 0) {
                    ForEach(ModpackImportStage.allCases) { stage in
                        stageRow(stage)
                        if stage != ModpackImportStage.allCases.last {
                            Divider().padding(.leading, 44).opacity(0.28)
                        }
                    }
                }
                .background(Color("TextColor").opacity(0.025), in: RoundedRectangle(cornerRadius: 6))

                if manager.compatibilityDisabledCount > 0
                    || manager.compatibilityOfficialArtifactCount > 0
                    || manager.compatibilityWarningCount > 0 {
                    compatibilitySummary
                }

                if case .failed(let message) = manager.phase {
                    failureMessage(message)
                }
                if case .awaitingOfficialDownloads = manager.phase {
                    officialWebDownloadMessage
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compatibilitySummary: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(settings.theme.getTextStyle())
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac 兼容处理")
                    .font(.custom("PCL English", size: 13))
                    .foregroundStyle(Color("TextColor"))
                Text("已可逆隔离 \(manager.compatibilityDisabledCount) 个 Windows-only Mod；补全 \(manager.compatibilityOfficialArtifactCount) 个官方 Mac 组件；\(manager.compatibilityWarningCount) 个项目需要启动前确认。")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x7F8790))
            }
            Spacer()
        }
        .padding(12)
        .background(settings.theme.getAccentColor().opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func stageRow(_ stage: ModpackImportStage) -> some View {
        let progress = progressForStage(stage)
        let active = manager.isRunning && manager.currentStage == stage
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(progress >= 1 ? settings.theme.getAccentColor() : settings.theme.getAccentColor().opacity(active ? 0.16 : 0.06))
                Image(systemName: progress >= 1 ? "checkmark" : stage.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(progress >= 1 ? AnyShapeStyle(Color.white) : settings.theme.getTextStyle())
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(stage.title)
                        .font(.custom("PCL English", size: 13))
                        .foregroundStyle(Color("TextColor"))
                    Spacer()
                    Text(stageStateText(stage, progress: progress))
                        .font(.custom("PCL English", size: 11))
                        .foregroundStyle(active ? settings.theme.getTextStyle() : AnyShapeStyle(Color(hex: 0x7F8790)))
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(progress >= 1 || active ? settings.theme.getAccentColor() : Color(hex: 0xB9BDC2))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 66)
    }

    private func failureMessage(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hex: 0xE5484D))
            VStack(alignment: .leading, spacing: 8) {
                Text("失败原因")
                    .font(.custom("PCL English", size: 13))
                    .foregroundStyle(Color("TextColor"))
                Text(message)
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color("TextColor"))
                    .textSelection(.enabled)
                if let recoveryInfo = manager.recoveryInfo {
                    Text(recoveryInfo.summary)
                        .font(.custom("PCL English", size: 12))
                        .foregroundStyle(Color(hex: 0x7F8790))
                    if manager.hasOfficialWebDownloadQueue {
                        Text("受限文件会在 CurseForge 官方页面由你确认下载；PCL.Mac 会自动校验、归位并继续导入。")
                            .font(.custom("PCL English", size: 11))
                            .foregroundStyle(Color(hex: 0x7F8790))
                    }
                    Button("在 Finder 中显示续传目录") {
                        manager.revealRecoveryLocation()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(hex: 0xE5484D).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var officialWebDownloadMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(settings.theme.getTextStyle())
            VStack(alignment: .leading, spacing: 5) {
                Text("等待 CurseForge 官方页面下载")
                    .font(.custom("PCL English", size: 13))
                    .foregroundStyle(Color("TextColor"))
                Text("请在网页中自行点击下载。下载完成后会经过 SHA-1 校验、自动归位，并继续应用 overrides 和实例校验。")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x7F8790))
            }
            Spacer()
        }
        .padding(12)
        .background(settings.theme.getAccentColor().opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch manager.phase {
            case .ready:
                Text(manager.urls.isEmpty ? "请选择至少一个整合包" : "将自动创建独立实例，不会覆盖现有版本")
                    .font(.custom("PCL English", size: 11))
                    .foregroundStyle(Color(hex: 0x7F8790))
                Spacer()
                Button("取消") { manager.close() }
                    .buttonStyle(.bordered)
                Button("开始导入") { manager.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.urls.isEmpty)
            case .importing:
                Text("可以继续使用启动器，导入将在后台完成")
                    .font(.custom("PCL English", size: 11))
                    .foregroundStyle(Color(hex: 0x7F8790))
                Spacer()
                Button("取消导入", role: .destructive) { manager.cancel() }
                    .buttonStyle(.bordered)
            case .awaitingOfficialDownloads:
                Text("只接收你在官方页面手动触发的下载")
                    .font(.custom("PCL English", size: 11))
                    .foregroundStyle(Color(hex: 0x7F8790))
                Spacer()
                Button("取消导入", role: .destructive) { manager.cancel() }
                    .buttonStyle(.bordered)
                Button("打开官方页面") { manager.continueOfficialWebDownloads() }
                    .buttonStyle(.borderedProminent)
            case .cancelling:
                ProgressView()
                    .controlSize(.small)
                Text("正在安全清理…")
                    .font(.custom("PCL English", size: 12))
                Spacer()
            case .success:
                Label(successFooterText, systemImage: "checkmark.circle.fill")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(settings.theme.getTextStyle())
                Spacer()
                Button("完成") { manager.close() }
                    .buttonStyle(.borderedProminent)
            case .failed:
                Spacer()
                Button("关闭") { manager.close() }
                    .buttonStyle(.bordered)
                if manager.hasOfficialWebDownloadQueue {
                    Button("继续官方网页下载") { manager.continueOfficialWebDownloads() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(manager.recoveryInfo == nil ? "重试" : "继续重试") { manager.retry() }
                        .buttonStyle(.borderedProminent)
                }
            case .cancelled:
                Text("导入已取消")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(Color(hex: 0x7F8790))
                Spacer()
                Button("关闭") { manager.close() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
    }

    private var successFooterText: String {
        if manager.compatibilityDisabledCount > 0 || manager.compatibilityOfficialArtifactCount > 0 {
            return "已创建 \(manager.importedURLs.count) 个实例，隔离 \(manager.compatibilityDisabledCount) 个 Mod，补全 \(manager.compatibilityOfficialArtifactCount) 个官方组件"
        }
        return "已创建 \(manager.importedURLs.count) 个可启动实例"
    }

    private var headerSubtitle: String {
        switch manager.phase {
        case .ready: "确认文件与实例位置"
        case .importing, .cancelling: "自动安装游戏、加载器与全部依赖"
        case .awaitingOfficialDownloads: "等待你在官方页面确认下载"
        case .success: "实例已通过启动环境与 Mac 原生兼容检查"
        case .failed: "查看失败原因、续传状态并继续重试"
        case .cancelled: "未完成的实例已移除"
        }
    }

    private var statusColor: AnyShapeStyle {
        switch manager.phase {
        case .failed: AnyShapeStyle(Color(hex: 0xE5484D))
        case .success, .awaitingOfficialDownloads: settings.theme.getTextStyle()
        default: AnyShapeStyle(Color(hex: 0x7F8790))
        }
    }

    private func progressForStage(_ stage: ModpackImportStage) -> Double {
        if case .success = manager.phase { return 1 }
        return manager.stageProgress[stage] ?? 0
    }

    private func stageStateText(_ stage: ModpackImportStage, progress: Double) -> String {
        if progress >= 1 { return "完成" }
        if manager.isRunning && manager.currentStage == stage {
            return String(format: "%.0f%%", progress * 100)
        }
        if case .failed = manager.phase, manager.currentStage == stage { return "失败" }
        return "等待"
    }
}
