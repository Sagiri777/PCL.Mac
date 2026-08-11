import AppKit
import SwiftUI

struct InstanceSnapshotsView: View {
    let instance: MinecraftInstance

    @State private var snapshots: [InstanceSnapshotRecord] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                snapshotDeck
                if snapshots.isEmpty, !isWorking {
                    ContentUnavailableView(
                        "还没有快照",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("快照保存 Mod、配置、资源包和服务器列表；恢复前还会自动备份当前状态。")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(snapshots) { snapshot in
                        snapshotRow(snapshot)
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.never)
        .task { await reload() }
        .alert("快照操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var snapshotDeck: some View {
        TitlelessMyCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppSettings.shared.theme.getAccentColor().opacity(0.14))
                        .frame(width: 58, height: 58)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AppSettings.shared.theme.getAccentColor())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("实例时间线")
                        .font(.system(size: 20, weight: .semibold))
                    Text("保存关键配置，在批量更新或排错后随时回到稳定状态。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在处理实例快照")
                }
                Button("创建快照", systemImage: "plus") {
                    Task { await createSnapshot() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || instance.process?.isRunning == true)
            }
            .padding(4)
        }
    }

    private func snapshotRow(_ snapshot: InstanceSnapshotRecord) -> some View {
        TitlelessMyCard {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppSettings.shared.theme.getAccentColor())
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.metadata.reason)
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(snapshot.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(formatBytes(snapshot.byteSize))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(snapshot.metadata.includedPaths.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([snapshot.archiveURL])
                }
                .labelStyle(.iconOnly)
                .help("在 Finder 中显示")
                .accessibilityLabel("在 Finder 中显示快照")
                Button("恢复") {
                    confirmRestore(snapshot)
                }
                .disabled(isWorking || instance.process?.isRunning == true)
                Button(role: .destructive) {
                    confirmDelete(snapshot)
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除快照")
                .accessibilityLabel("删除快照")
                .disabled(isWorking)
            }
            .padding(4)
        }
        .accessibilityElement(children: .contain)
    }

    @MainActor
    private func reload() async {
        do {
            snapshots = try await InstanceSnapshotService.shared.snapshots(for: instance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func createSnapshot() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await InstanceSnapshotService.shared.createSnapshot(
                for: instance,
                reason: "手动快照"
            )
            snapshots = try await InstanceSnapshotService.shared.snapshots(for: instance)
            hint("实例快照创建完成", .finish)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmRestore(_ snapshot: InstanceSnapshotRecord) {
        Task {
            let selection = await PopupManager.shared.showAsync(.init(
                .normal,
                "恢复实例快照",
                "将用“\(snapshot.metadata.reason)”替换当前 Mod、配置、资源包和服务器列表。恢复前会自动创建一个当前状态快照。",
                [.init(label: "恢复", style: .accent), .close]
            ))
            guard selection == 0 else { return }
            await restore(snapshot)
        }
    }

    @MainActor
    private func restore(_ snapshot: InstanceSnapshotRecord) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await InstanceSnapshotService.shared.restore(snapshot, to: instance)
            snapshots = try await InstanceSnapshotService.shared.snapshots(for: instance)
            hint("实例已恢复到所选快照", .finish)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmDelete(_ snapshot: InstanceSnapshotRecord) {
        Task {
            let selection = await PopupManager.shared.showAsync(.init(
                .normal,
                "删除实例快照",
                "此操作无法撤销。要删除“\(snapshot.metadata.reason)”吗？",
                [.init(label: "删除", style: .accent), .close]
            ))
            guard selection == 0 else { return }
            await delete(snapshot)
        }
    }

    @MainActor
    private func delete(_ snapshot: InstanceSnapshotRecord) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await InstanceSnapshotService.shared.delete(snapshot)
            snapshots = try await InstanceSnapshotService.shared.snapshots(for: instance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
