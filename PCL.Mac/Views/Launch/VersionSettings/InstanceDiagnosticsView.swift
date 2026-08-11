import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InstanceDiagnosticsView: View {
    @ObservedObject private var dataManager = DataManager.shared
    let instance: MinecraftInstance

    @State private var report: InstanceDiagnosticReport?
    @State private var isRunning = false
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusDeck
                if let report {
                    ForEach(report.items) { item in
                        diagnosticRow(item)
                    }
                } else if !isRunning {
                    ContentUnavailableView(
                        "尚未诊断",
                        systemImage: "stethoscope",
                        description: Text("检查 Java、实例文件、Mod、磁盘空间和最近一次崩溃。")
                    )
                }
            }
            .padding()
        }
        .scrollIndicators(.never)
        .task { await runDiagnostics() }
        .alert("无法导出报告", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "未知错误")
        }
    }

    private var statusDeck: some View {
        TitlelessMyCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 56, height: 56)
                    Image(systemName: statusIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(instance.name)
                        .font(.system(size: 20, weight: .semibold))
                    Text(statusSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在诊断实例")
                }
                Button("重新检查", systemImage: "arrow.clockwise") {
                    Task { await runDiagnostics() }
                }
                .disabled(isRunning)
                Button("导出报告", systemImage: "square.and.arrow.up") {
                    exportReport()
                }
                .disabled(report == nil)
            }
            .padding(4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("实例诊断状态：\(statusSummary)")
    }

    private func diagnosticRow(_ item: InstanceDiagnosticItem) -> some View {
        TitlelessMyCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(for: item.severity))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color(for: item.severity))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(item.severity.label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(color(for: item.severity).opacity(0.12), in: Capsule())
                            .foregroundStyle(color(for: item.severity))
                    }
                    Text(item.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color("TextColor"))
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let action = item.action {
                    Button(action.label) { perform(action) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)，\(item.severity.label)，\(item.summary)")
    }

    private var statusSummary: String {
        if isRunning { return "正在检查运行环境…" }
        guard let report else { return "运行一次检查，生成可分享的脱敏报告" }
        if report.problemCount == 0 { return "启动环境状态良好" }
        return "发现 \(report.problemCount) 项需要处理"
    }

    private var statusColor: Color {
        guard let report else { return .secondary }
        return color(for: report.highestSeverity)
    }

    private var statusIcon: String {
        guard let report else { return "stethoscope" }
        return icon(for: report.highestSeverity)
    }

    private func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        report = await InstanceDiagnosticsService.run(for: instance)
        isRunning = false
    }

    private func exportReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.title = "导出脱敏诊断报告"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "PCL-Mac-诊断-\(instance.name).md"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try report.write(to: destination)
                hint("诊断报告已导出", .finish)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func perform(_ action: InstanceDiagnosticAction) {
        switch action {
        case .installJava:
            dataManager.router.append(.javaDownload)
        case .manageMods:
            var path = dataManager.router.path
            if !path.isEmpty { path.removeLast() }
            path.append(.instanceMods)
            dataManager.router.path = path
        case .manageAccounts:
            dataManager.router.path = [.accountManagement, .accountList]
        case .openInstanceFolder:
            Util.openInFinder(instance.runningDirectory)
        }
    }

    private func color(for severity: InstanceDiagnosticSeverity) -> Color {
        switch severity {
        case .healthy: .green
        case .information: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    private func icon(for severity: InstanceDiagnosticSeverity) -> String {
        switch severity {
        case .healthy: "checkmark.circle.fill"
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}
