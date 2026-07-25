//
//  ModpackImportView.swift
//  PCL.Mac
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ModpackImportManager: ObservableObject {
    static let shared = ModpackImportManager()

    enum Phase {
        case ready
        case importing
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

    private var worker: Task<Void, Never>?

    var canEditSelection: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isRunning: Bool {
        switch phase {
        case .importing, .cancelling: true
        default: false
        }
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
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "mrpack")!]
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func start() {
        guard !urls.isEmpty, let directory, !isRunning else { return }
        phase = .importing
        importedURLs = []
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
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
                    importedURLs.append(importedURL)
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
                    statusText = "导入在 \(currentStage.title) 阶段停止"
                    phase = .failed(error.localizedDescription)
                    err("整合包导入失败：\(error.localizedDescription)")
                }
                if let last = importedURLs.last {
                    AppSettings.shared.defaultInstance = last.lastPathComponent
                    directory.loadInnerInstances()
                }
            }
            worker = nil
        }
    }

    func cancel() {
        guard isRunning else { return }
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
        resetProgress()
        start()
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

    private func resetProgress() {
        currentPackName = urls.first?.deletingPathExtension().lastPathComponent ?? ""
        statusText = "检查文件后开始导入"
        currentPackIndex = 0
        overallProgress = 0
        currentStage = .detecting
        stageProgress = [:]
        finishedFiles = 0
        totalFiles = 0
        importedURLs = []
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

                if case .failed(let message) = manager.phase {
                    failureMessage(message)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Text(message)
                .font(.custom("PCL English", size: 12))
                .foregroundStyle(Color("TextColor"))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(Color(hex: 0xE5484D).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
            case .cancelling:
                ProgressView()
                    .controlSize(.small)
                Text("正在安全清理…")
                    .font(.custom("PCL English", size: 12))
                Spacer()
            case .success:
                Label("已创建 \(manager.importedURLs.count) 个可启动实例", systemImage: "checkmark.circle.fill")
                    .font(.custom("PCL English", size: 12))
                    .foregroundStyle(settings.theme.getTextStyle())
                Spacer()
                Button("完成") { manager.close() }
                    .buttonStyle(.borderedProminent)
            case .failed:
                Spacer()
                Button("关闭") { manager.close() }
                    .buttonStyle(.bordered)
                Button("重试") { manager.retry() }
                    .buttonStyle(.borderedProminent)
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

    private var headerSubtitle: String {
        switch manager.phase {
        case .ready: "确认文件与实例位置"
        case .importing, .cancelling: "自动安装游戏、加载器与全部依赖"
        case .success: "实例已经通过启动环境校验"
        case .failed: "查看失败阶段并重试"
        case .cancelled: "未完成的实例已移除"
        }
    }

    private var statusColor: AnyShapeStyle {
        switch manager.phase {
        case .failed: AnyShapeStyle(Color(hex: 0xE5484D))
        case .success: settings.theme.getTextStyle()
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
