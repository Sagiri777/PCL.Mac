import AppKit
import SwiftUI

private enum ServerProbeState {
    case loading
    case online(MinecraftServerStatus)
    case offline(String)
}

private struct ServerEditorRequest: Identifiable {
    let id = UUID()
    let server: SavedMinecraftServer?
}

struct MultiplayerView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var store = MultiplayerServerStore.shared

    @State private var probes: [UUID: ServerProbeState] = [:]
    @State private var editorRequest: ServerEditorRequest?
    @State private var launchingIDs: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                connectionDeck
                if store.servers.isEmpty {
                    ContentUnavailableView(
                        "还没有服务器",
                        systemImage: "network",
                        description: Text("添加常用服务器，查看延迟、MOTD 和在线人数，并绑定实例直接启动。")
                    )
                    .padding(.top, 45)
                } else {
                    ForEach(store.servers) { server in
                        serverRow(server)
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.never)
        .onAppear {
            dataManager.leftTab(0) { EmptyView() }
            Task { await pingAll() }
        }
        .sheet(item: $editorRequest) { request in
            MultiplayerServerEditor(
                server: request.server,
                instanceNames: availableInstanceNames()
            ) { server in
                store.upsert(server)
                editorRequest = nil
                Task { await ping(server) }
            } onCancel: {
                editorRequest = nil
            }
        }
    }

    private var connectionDeck: some View {
        TitlelessMyCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppSettings.shared.theme.getAccentColor().opacity(0.14))
                        .frame(width: 58, height: 58)
                    Image(systemName: "network")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(AppSettings.shared.theme.getAccentColor())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("联机甲板")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(onlineServerCount) / \(store.servers.count) 台服务器在线")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新全部", systemImage: "arrow.clockwise") {
                    Task { await pingAll() }
                }
                .disabled(store.servers.isEmpty)
                Button("添加服务器", systemImage: "plus") {
                    editorRequest = .init(server: nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(4)
        }
    }

    private func serverRow(_ server: SavedMinecraftServer) -> some View {
        TitlelessMyCard {
            HStack(spacing: 12) {
                statusIndicator(for: server)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(server.name)
                            .font(.system(size: 15, weight: .semibold))
                        if let instanceName = server.instanceName {
                            Text(instanceName)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(server.address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    statusDescription(for: server)
                }
                Spacer()
                Button {
                    Task { await ping(server) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新服务器状态")
                .accessibilityLabel("刷新 \(server.name) 的状态")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.address, forType: .string)
                    hint("服务器地址已复制", .finish)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("复制地址")
                .accessibilityLabel("复制服务器地址")
                Button("启动") {
                    Task { await launch(server) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(launchingIDs.contains(server.id))
                Menu {
                    Button("编辑") { editorRequest = .init(server: server) }
                    Button("删除", role: .destructive) { confirmDelete(server) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("\(server.name) 的更多操作")
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func statusIndicator(for server: SavedMinecraftServer) -> some View {
        switch probes[server.id] {
        case .loading:
            ProgressView().controlSize(.small).frame(width: 32)
        case .online(let status):
            ZStack {
                Circle().fill(Color.green.opacity(0.14)).frame(width: 32, height: 32)
                Text("\(status.latencyMilliseconds)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            .accessibilityLabel("延迟 \(status.latencyMilliseconds) 毫秒")
        case .offline:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.red)
                .frame(width: 32)
                .accessibilityLabel("服务器离线")
        case nil:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityLabel("尚未检查")
        }
    }

    @ViewBuilder
    private func statusDescription(for server: SavedMinecraftServer) -> some View {
        switch probes[server.id] {
        case .online(let status):
            Text("\(status.motd) · \(status.onlinePlayers)/\(status.maximumPlayers) · \(status.versionName)")
                .font(.system(size: 12))
                .foregroundStyle(Color("TextColor"))
                .lineLimit(2)
        case .offline(let reason):
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(2)
        case .loading:
            Text("正在连接…").font(.system(size: 12)).foregroundStyle(.secondary)
        case nil:
            Text("等待检查").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var onlineServerCount: Int {
        probes.values.filter {
            if case .online = $0 { return true }
            return false
        }.count
    }

    @MainActor
    private func pingAll() async {
        let servers = store.servers
        servers.forEach { probes[$0.id] = .loading }
        await withTaskGroup(of: (SavedMinecraftServer, Result<MinecraftServerStatus, Error>).self) { group in
            for server in servers {
                group.addTask {
                    do { return (server, .success(try await MinecraftServerPinger.ping(server))) }
                    catch { return (server, .failure(error)) }
                }
            }
            for await (server, result) in group {
                switch result {
                case .success(let status): probes[server.id] = .online(status)
                case .failure(let error): probes[server.id] = .offline(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func ping(_ server: SavedMinecraftServer) async {
        probes[server.id] = .loading
        do {
            probes[server.id] = .online(try await MinecraftServerPinger.ping(server))
        } catch {
            probes[server.id] = .offline(error.localizedDescription)
        }
    }

    private func confirmDelete(_ server: SavedMinecraftServer) {
        Task {
            let selection = await PopupManager.shared.showAsync(.init(
                .normal,
                "删除服务器",
                "要从收藏中移除“\(server.name)”吗？",
                [.init(label: "删除", style: .danger), .close]
            ))
            guard selection == 0 else { return }
            await MainActor.run {
                store.remove(id: server.id)
                probes.removeValue(forKey: server.id)
            }
        }
    }

    @MainActor
    private func launch(_ server: SavedMinecraftServer) async {
        guard !launchingIDs.contains(server.id) else { return }
        launchingIDs.insert(server.id)
        defer { launchingIDs.remove(server.id) }

        guard let directory = AppSettings.shared.currentMinecraftDirectory,
              let name = server.instanceName ?? AppSettings.shared.defaultInstance,
              let instance = MinecraftInstance.create(directory, name) else {
            hint("找不到服务器绑定的实例，请编辑服务器并重新选择。", .critical)
            return
        }
        let options = LaunchOptions()
        options.serverAddress = server.host
        options.serverPort = server.port
        if case .failure(let error) = LaunchPrecheck.checkJava(instance, options) {
            switch error {
            case .rosetta:
                break
            default:
                hint("Java 检查未通过：\(error.localizedDescription)", .critical)
                return
            }
        }
        if case .failure(let error) = LaunchPrecheck.checkAccount(instance, options) {
            switch error {
            case .missingAccount:
                hint("请先添加并选择一个启动账号。", .critical)
                return
            case .noMicrosoftAccount:
                break
            }
        }

        do {
            let javaArchitecture = instance.config.javaURL.map(Architecture.getArchOfFile) ?? .system
            let targetArchitecture: Architecture = javaArchitecture == .unknown || javaArchitecture == .fatFile
                ? .system : javaArchitecture
            let scanned = try await NativeCompatibilityService.shared.analyze(
                instance: instance,
                targetArchitecture: targetArchitecture
            )
            let compatibility = try await NativeCompatibilityService.shared.applyTrustedFixes(report: scanned)
            if !compatibility.unacknowledgedIssues.isEmpty {
                let selection = await PopupManager.shared.showAsync(.init(
                    .normal,
                    "发现 macOS 兼容性提醒",
                    "有 \(compatibility.unacknowledgedIssues.count) 个 Mod 需要确认。仍要直接进入服务器吗？",
                    [.init(label: "继续启动", style: .accent), .close]
                ))
                guard selection == 0 else { return }
            }
        } catch {
            warn("联机启动前兼容性检查失败：\(error.localizedDescription)")
        }

        hint("正在启动 \(instance.name) 并连接 \(server.name)")
        await instance.launch(options)
    }

    private func availableInstanceNames() -> [String] {
        guard let directory = AppSettings.shared.currentMinecraftDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directory.versionsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return contents.filter {
            FileManager.default.fileExists(atPath: $0.appending(path: "\($0.lastPathComponent).json").path)
        }.map(\.lastPathComponent).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

private struct MultiplayerServerEditor: View {
    let original: SavedMinecraftServer?
    let instanceNames: [String]
    let onSave: (SavedMinecraftServer) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var instanceName: String
    @State private var validationMessage: String?
    @FocusState private var hostFocused: Bool

    init(
        server: SavedMinecraftServer?,
        instanceNames: [String],
        onSave: @escaping (SavedMinecraftServer) -> Void,
        onCancel: @escaping () -> Void
    ) {
        original = server
        self.instanceNames = instanceNames
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: String(server?.port ?? 25565))
        _instanceName = State(initialValue: server?.instanceName ?? AppSettings.shared.defaultInstance ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "添加服务器" : "编辑服务器")
                .font(.system(size: 22, weight: .semibold))
            Form {
                TextField("名称", text: $name, prompt: Text("我的服务器"))
                TextField("地址", text: $host, prompt: Text("play.example.net"))
                    .focused($hostFocused)
                TextField("端口", text: $port)
                Picker("启动实例", selection: $instanceName) {
                    if instanceNames.isEmpty {
                        Text("没有可用实例").tag("")
                    } else {
                        ForEach(instanceNames, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityLabel("输入错误：\(validationMessage)")
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear { hostFocused = true }
    }

    private func save() {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !normalizedHost.contains(where: \.isWhitespace) else {
            validationMessage = "请输入有效的服务器主机名或 IP 地址。"
            return
        }
        guard let parsedPort = UInt16(port), parsedPort > 0 else {
            validationMessage = "端口必须在 1 到 65535 之间。"
            return
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(.init(
            id: original?.id ?? UUID(),
            name: normalizedName.isEmpty ? normalizedHost : normalizedName,
            host: normalizedHost,
            port: parsedPort,
            instanceName: instanceName.isEmpty ? nil : instanceName
        ))
    }
}
