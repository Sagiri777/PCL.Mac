import SwiftUI

struct ModUpdateCenterView: View {
    let instance: MinecraftInstance

    @State private var report: ModUpdateReport?
    @State private var isChecking = false
    @State private var installingIDs: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                updateDeck
                if let report {
                    if !report.warnings.isEmpty {
                        warningPanel(report.warnings)
                    }
                    if report.candidates.isEmpty, !isChecking {
                        ContentUnavailableView(
                            "没有可用更新",
                            systemImage: "checkmark.seal",
                            description: Text("识别了 \(report.recognizedFileCount) / \(report.installedFileCount) 个 Modrinth 文件。")
                        )
                        .padding(.top, 32)
                    } else {
                        ForEach(report.candidates) { candidate in
                            updateRow(candidate)
                        }
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.never)
        .task { await check() }
        .alert("模组更新失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var updateDeck: some View {
        TitlelessMyCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppSettings.shared.theme.getAccentColor().opacity(0.14))
                        .frame(width: 58, height: 58)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(AppSettings.shared.theme.getAccentColor())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("模组更新中心")
                        .font(.system(size: 20, weight: .semibold))
                    Text(deckSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isChecking || !installingIDs.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(isChecking ? "正在检查模组更新" : "正在安装模组更新")
                }
                Button("重新检查", systemImage: "arrow.clockwise") {
                    Task { await check() }
                }
                .disabled(isBusy)
                if let candidates = report?.candidates, candidates.count > 1 {
                    Button("全部更新") {
                        confirmInstall(candidates)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }
            }
            .padding(4)
        }
    }

    private func updateRow(_ candidate: ModUpdateCandidate) -> some View {
        TitlelessMyCard {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppSettings.shared.theme.getAccentColor())
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.modName)
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(candidate.currentVersionNumber)  →  \(candidate.targetVersion.versionNumber)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !candidate.requiredDependencies.isEmpty {
                        Text("同时安装依赖：\(candidate.requiredDependencies.map(\.name).joined(separator: "、"))")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if installingIDs.contains(candidate.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("更新") {
                        confirmInstall([candidate])
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .accessibilityLabel("将 \(candidate.modName) 更新到 \(candidate.targetVersion.versionNumber)")
                }
            }
            .padding(4)
        }
    }

    private func warningPanel(_ warnings: [String]) -> some View {
        TitlelessMyCard {
            VStack(alignment: .leading, spacing: 5) {
                Label("部分 Mod 无法检查", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                ForEach(warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var deckSubtitle: String {
        guard let report else { return "用文件哈希识别版本；更新前自动创建实例快照。" }
        return "识别 \(report.recognizedFileCount) / \(report.installedFileCount) 个文件，发现 \(report.candidates.count) 项更新。"
    }

    private var isBusy: Bool {
        isChecking || !installingIDs.isEmpty || instance.process?.isRunning == true
    }

    @MainActor
    private func check() async {
        guard !isBusy else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            report = try await ModUpdateService.check(for: instance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmInstall(_ candidates: [ModUpdateCandidate]) {
        Task {
            let names = candidates.prefix(4).map(\.modName).joined(separator: "、")
            let suffix = candidates.count > 4 ? "等 \(candidates.count) 个 Mod" : ""
            let selection = await PopupManager.shared.showAsync(.init(
                .normal,
                "安装模组更新",
                "将更新 \(names)\(suffix)。PCL.Mac 会先下载并校验全部文件，再创建快照和替换旧版本。",
                [.init(label: "开始更新", style: .accent), .close]
            ))
            guard selection == 0 else { return }
            await install(candidates)
        }
    }

    @MainActor
    private func install(_ candidates: [ModUpdateCandidate]) async {
        guard !isBusy else { return }
        installingIDs = Set(candidates.map(\.id))
        defer { installingIDs = [] }
        do {
            try await ModUpdateService.install(candidates, for: instance)
            hint("模组更新完成", .finish)
            report = try await ModUpdateService.check(for: instance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
